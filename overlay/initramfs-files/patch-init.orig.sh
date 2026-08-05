#!/bin/sh
# Patch init.orig to handle the Ventoy loop device.
#
# Background
# ----------
# When booted through Ventoy, the netoy ISO is a *file* on a normal USB data
# partition (exfat/vfat/ntfs).  The initramfs wrapper (our /init) copies that
# file into RAM and attaches it to a loop device (/dev/loop0), then hands over
# to the stock Alpine initramfs (/init.orig) with NETOY_LOOP_DEV=/dev/loop0.
#
# The stock Alpine boot-media step runs nlplug-findfs, which scans block
# devices, mounts any that carry .boot_repository / *.apkovl.tar.gz at
# /media/<devname> and writes the paths to $ROOT/tmp/{apkovls,repositories}.
# With a loop device attached by our wrapper, nlplug-findfs can either
#
#   a) see /dev/loop0 and *mount it* at /media/loop0 (the normal path), or
#   b) short-circuit on the device argument (FOUND_DEVICE) without mounting.
#
# The previous patch tried to re-mount the loop with `mount -o loop,ro`:
#   - in case (a) the device was ALREADY mounted, so `mount -o loop` failed
#     with "Resource busy" / "already mounted" -> eend 1 -> recovery shell
#     (the emergency shell the user hit), instead of "Mounting boot media".
#   - in case (b) `mount -o loop` on an attached loop *sometimes* worked but
#     depended on busybox behaviour and left nothing recorded in the
#     apkovls/repositories files unless the ISO layout check below ran.
#
# The fix
# -------
# - When NETOY_LOOP_DEV is set, mount the loop with a *plain* `mount -o ro`
#   (the device is already a block device; -o loop is wrong and fails on an
#   attached/mounted loop).  Check mountpoint first so an already-mounted boot
#   media (case a) is treated as success and never triggers the recovery shell.
#   Record the apkovl / boot-repository paths if nlplug-findfs did not.
# - When NETOY_LOOP_DEV is unset (plain CD/USB boot), keep the original
#   nlplug-findfs call untouched so normal boots still find their boot media.
#
# Structure produced (replaces the stock boot-media block):
#
#   # locate boot media and mount it
#   # Ventoy loop device: ...
#   if [ -n "$NETOY_LOOP_DEV" ]; then
#       NETOY_LOOP_MNT=/media/${NETOY_LOOP_DEV##*/}
#       mkdir -p "$NETOY_LOOP_MNT"
#       if mountpoint -q "$NETOY_LOOP_MNT" 2>/dev/null; then
#           ebegin "Mounting boot media"
#           eend 0
#           NETOY_BOOT_DONE=yes
#       elif mount -o ro "$NETOY_LOOP_DEV" "$NETOY_LOOP_MNT" 2>/dev/null; then
#           ebegin "Mounting boot media"
#           eend 0
#           NETOY_BOOT_DONE=yes
#       else
#           ebegin "Mounting boot media"
#           eend 1
#           NETOY_BOOT_DONE=no
#       fi
#       # Write apkovl path if present
#       if [ -f "$NETOY_LOOP_MNT/netoy.apkovl.tar.gz" ]; then
#           if ! grep -q ... ; then
#               echo ... >> "$ROOT/tmp/apkovls"
#           fi
#       fi
#       # Write boot repository path
#       if [ -f "$NETOY_LOOP_MNT/apks/.boot_repository" ]; then
#           if ! grep -q ... ; then
#               echo ... >> "$ROOT/tmp/repositories"
#           fi
#       fi
#   else
#       ebegin "Mounting boot media"
#       $MOCK nlplug-findfs ...    <- original call preserved
#       eend $?
#   fi

awk '
/# locate boot media and mount it/ {
    print "# locate boot media and mount it"
    print "# Ventoy loop device: use the loop already mounted by nlplug-findfs"
    print "# as the boot media. When NETOY_LOOP_DEV is set we skip nlplug-findfs"
    print "# and mount the loop ourselves; otherwise nlplug-findfs has already"
    print "# mounted it at /media/<dev> and the mount below must not fail with"
    print "# \"already mounted\"."
    print "if [ -n \"$NETOY_LOOP_DEV\" ]; then"
    print "    NETOY_LOOP_MNT=/media/${NETOY_LOOP_DEV##*/}"
    print "    mkdir -p \"$NETOY_LOOP_MNT\""
    print "    if mountpoint -q \"$NETOY_LOOP_MNT\" 2>/dev/null; then"
    print "        # nlplug-findfs already mounted and scanned the boot media."
    print "        ebegin \"Mounting boot media\""
    print "        eend 0"
    print "        NETOY_BOOT_DONE=yes"
    print "    elif mount -o ro \"$NETOY_LOOP_DEV\" \"$NETOY_LOOP_MNT\" 2>/dev/null; then"
    print "        ebegin \"Mounting boot media\""
    print "        eend 0"
    print "        NETOY_BOOT_DONE=yes"
    print "    else"
    print "        ebegin \"Mounting boot media\""
    print "        eend 1"
    print "        NETOY_BOOT_DONE=no"
    print "    fi"
    print "    # Write apkovl path if present"
    print "    if [ -f \"$NETOY_LOOP_MNT/netoy.apkovl.tar.gz\" ]; then"
    print "        if ! grep -q \"$NETOY_LOOP_MNT/netoy.apkovl.tar.gz\" \"$ROOT/tmp/apkovls\" 2>/dev/null; then"
    print "            echo \"$NETOY_LOOP_MNT/netoy.apkovl.tar.gz\" >> \"$ROOT/tmp/apkovls\""
    print "        fi"
    print "    fi"
    print "    # Write boot repository path"
    print "    if [ -f \"$NETOY_LOOP_MNT/apks/.boot_repository\" ]; then"
    print "        if ! grep -q \"^$NETOY_LOOP_MNT/apks$\" \"$ROOT/tmp/repositories\" 2>/dev/null; then"
    print "            echo \"$NETOY_LOOP_MNT/apks\" >> \"$ROOT/tmp/repositories\""
    print "        fi"
    print "    fi"
    print "else"
    print "    ebegin \"Mounting boot media\""
    state=1
    next
}
state == 1 && /^ebegin[[:space:]]*"Mounting boot media"/ {
    # skip the original ebegin (we already emitted it in the else branch)
    next
}
state == 1 && /^eend \$\?/ {
    print "    eend $?"
    print "fi"
    state=0
    next
}
state == 1 { print; next }
{ print }
' init.orig > init.orig.new
mv init.orig.new init.orig
chmod +x init.orig
