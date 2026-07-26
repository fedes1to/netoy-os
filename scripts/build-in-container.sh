#!/bin/sh
set -e

ALPINE_VERSION=3.24
REPO_MAIN="https://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION/main"
REPO_COMM="https://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION/community"

# -----------------------------------------------------------------------------
# Install host tools needed by mkimage.sh and for compiling netoy-tui/impala
# -----------------------------------------------------------------------------
apk add --no-cache \
    abuild apk-tools alpine-conf busybox fakeroot syslinux xorriso \
    squashfs-tools mtools grub-efi git curl \
    rust cargo musl-dev \
    device-mapper-static

# An abuild key is required because mkimage.sh signs the modloop and the
# boot repository's APKINDEX. We are root, so install the public key manually
# after generation instead of relying on doas.
abuild-keygen -a -n
cp /root/.abuild/*.pub /etc/apk/keys/

# -----------------------------------------------------------------------------
# Build netoy-tui in integrated mode
# -----------------------------------------------------------------------------
rm -rf /tmp/netoy-tui-build
cp -a /netoy-tui /tmp/netoy-tui-build
cd /tmp/netoy-tui-build
cargo build --release --features for-bootable
strip target/release/netoy-tui
cp target/release/netoy-tui /work/overlay/usr/local/bin/

# -----------------------------------------------------------------------------
# Build impala (iwd TUI)
# -----------------------------------------------------------------------------
rm -rf /tmp/impala-build
git clone --depth 1 https://github.com/pythops/impala.git /tmp/impala-build
cd /tmp/impala-build
cargo build --release
strip target/release/impala
cp target/release/impala /work/overlay/usr/local/bin/

# -----------------------------------------------------------------------------
# Pre-fetch dnscrypt-proxy resolver list so DoH works without an initial
# download. The list is refreshed at runtime when dnscrypt-proxy starts.
# -----------------------------------------------------------------------------
DNSCACHE=/work/overlay/var/cache/dnscrypt-proxy
mkdir -p "$DNSCACHE"
curl -fsSL -o "$DNSCACHE/public-resolvers.md.tmp" \
    https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md && \
    curl -fsSL -o "$DNSCACHE/public-resolvers.md.minisig.tmp" \
    https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md.minisig && \
    mv "$DNSCACHE/public-resolvers.md.tmp" "$DNSCACHE/public-resolvers.md" && \
    mv "$DNSCACHE/public-resolvers.md.minisig.tmp" "$DNSCACHE/public-resolvers.md.minisig" && \
    echo "dnscrypt-proxy resolver list cached" || {
        echo "warning: could not cache dnscrypt-proxy resolver list" >&2
        rm -f "$DNSCACHE"/*.tmp
    }

# -----------------------------------------------------------------------------
# Build the Alpine ISO with the netoy profile.
# ------------------------------------------------------------------------------
cd /work

# Point the apkovl generator at our overlay tree
export NETOY_OVERLAY=/work/overlay

# Add kernel modules needed by the initramfs wrapper to mount the Ventoy data
# partition (exfat/ntfs3) and loop-mount the ISO. Device-mapper modules are
# needed to create the Ventoy remount mapper.
mkdir -p /etc/mkinitfs/features.d
cat > /etc/mkinitfs/features.d/netoy.modules <<'EOF'
kernel/fs/exfat/exfat.ko*
kernel/fs/ntfs3/ntfs3.ko*
kernel/drivers/md/dm-mod.ko*
kernel/drivers/md/dm-linear.ko*
EOF

# Add losetup and a static dmsetup to the initramfs so the wrapper can attach
# the copied ISO to a loop device and create the Ventoy remount mapper.
cat > /etc/mkinitfs/features.d/netoy.files <<'EOF'
sbin/losetup
sbin/dmsetup
EOF

# update-kernel calls mkinitfs with -b $ROOTFS, so mkinitfs looks for features
# in $ROOTFS/etc/mkinitfs/features.d. Our custom features are on the host, so
# prepend the host features directory to mkinitfs's search path.
export MKINITFS_ARGS="-P /etc/mkinitfs/features.d"

# Pre-clean the output directory: a stale netoy-*.iso left behind by a
# previous run (or a foreign-owned file from an external tool/QEMU) would
# make xorrisofs fail to open its output "pseudo-drive" with
# "Permission denied" and abort the build with "Burn run failed". We own
# the output directory, so unlinking is always allowed regardless of who
# owned the old file.
rm -f /work/out/netoy-*.iso /work/out/*.tmp 2>/dev/null || true

./vendor/mkimage.sh \
    --profile netoy \
    --repository "$REPO_MAIN" \
    --repository "$REPO_COMM" \
    --outdir /work/out

# Post-process the ISO: add an initramfs wrapper that copies the netoy ISO from
# the Ventoy data partition into RAM and attaches it to a loop device.  Alpine's
# nlplug-findfs then discovers that loop device as the boot media.  After the
# copy the wrapper neutralizes Ventoy (drops /ventoy/ventoy_os_param and its
# udev rules) so Ventoy's device-mapper node is never created over the data
# partition (which would pin it read-only and break the Alpine boot for this
# ISO) and the user can unplug the USB once the ISO is in RAM.  A progress bar
# is shown during copy.
ISO_IN=$(ls /work/out/netoy-*.iso | head -n1)
ISO_OUT="$ISO_IN"
WORKDIR=/tmp/netoy-iso-pp
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

xorriso -indev "$ISO_IN" -osirrox on \
    -extract /boot/initramfs-lts "$WORKDIR/initramfs-lts.gz" 2>/dev/null

mkdir -p "$WORKDIR/initramfs"
cd "$WORKDIR/initramfs"
zcat "$WORKDIR/initramfs-lts.gz" | cpio -idm 2>/dev/null

mv init init.orig
cp /work/overlay/initramfs-files/init init
chmod +x init
cp /work/overlay/initramfs-files/netoy-copy-iso.sh netoy-copy-iso.sh
chmod +x netoy-copy-iso.sh

# The initramfs busybox has the losetup applet, but the symlink may not be
# created by mkinitfs. Make sure it exists so the Ventoy wrapper can attach
# the copied ISO to a loop device.
ln -sf /bin/busybox sbin/losetup

# Include a static dmsetup for creating the Ventoy remount mapper in the
# initramfs (the dynamic dmsetup from the root filesystem needs libraries).
for src in /sbin/dmsetup.static /usr/sbin/dmsetup.static /sbin/dmsetup; do
    if [ -x "$src" ]; then
        cp -f "$src" sbin/dmsetup
        break
    fi
done
if [ ! -x sbin/dmsetup ]; then
    echo "warning: dmsetup not found; Ventoy-only boot may not work" >&2
fi

# ---- Trim GPU firmware from the modloop to shrink the ISO -----------
# The modloop (squashfs of /lib/modules + firmware) is by far the largest
# file in the ISO (~290 MB compressed). The nvidia and cirrus GPU firmware
# alone is ~1.3 GB uncompressed and is never used by netoy-tui: the TUI is
# text-only and renders on the framebuffer console (simpledrm/efifb), which
# does not need discrete-GPU acceleration firmware. Intel (i915/xe) and AMD
# (amdgpu/radeon) display firmware is KEPT so real Intel/AMD displays still
# light up on arbitrary hardware.
#
# Rebuilding the squashfs invalidates Alpine's detached modloop signature, so
# we re-sign it with the build's abuild key and replace the signature blob
# embedded in the initramfs (var/cache/misc/modloop-lts.SIGN.RSA.*). This
# keeps modloop signature verification intact at boot.
MODLOOP_TRIMMED="$WORKDIR/modloop-lts-new"
PRIVKEY="$(ls /root/.abuild/*.rsa 2>/dev/null | head -n1)"
if [ -n "$PRIVKEY" ]; then
    echo "Trimming GPU firmware from modloop..."
    xorriso -indev "$ISO_IN" -osirrox on \
        -extract /boot/modloop-lts "$WORKDIR/modloop-lts.orig" 2>/dev/null
    mkdir -p "$WORKDIR/modloop-root"
    if unsquashfs -f -d "$WORKDIR/modloop-root" "$WORKDIR/modloop-lts.orig" >/dev/null 2>&1; then
        rm -rf "$WORKDIR/modloop-root/modules/firmware/nvidia" \
               "$WORKDIR/modloop-root/modules/firmware/cirrus"
        if mksquashfs "$WORKDIR/modloop-root" "$MODLOOP_TRIMMED" \
                -no-progress -comp xz -exit-on-error -Xbcj x86 -all-root >/dev/null 2>&1; then
            echo "  trimmed: $(wc -c < "$WORKDIR/modloop-lts.orig") -> $(wc -c < "$MODLOOP_TRIMMED") bytes"

            # Re-sign the trimmed modloop with the build's abuild key.
            if openssl dgst -sha1 -sign "$PRIVKEY" \
                    -out "$WORKDIR/modloop-lts.sig" "$MODLOOP_TRIMMED" 2>/dev/null; then
                # Replace the embedded signature blob in the initramfs
                # (keeps the original filename so /init.orig's copy loop
                # and the modloop service still find it).
                EXISTINGSIG="$(ls var/cache/misc/modloop-lts.SIGN.RSA.* 2>/dev/null | head -n1)"
                if [ -n "$EXISTINGSIG" ]; then
                    cp "$WORKDIR/modloop-lts.sig" "$EXISTINGSIG"
                    echo "  re-signed modloop; updated $EXISTINGSIG"
                else
                    echo "  warning: no embedded modloop signature found; verification may fail" >&2
                fi
            else
                echo "  warning: modloop re-sign failed; keeping original modloop" >&2
                MODLOOP_TRIMMED=""
            fi
        else
            echo "  warning: modloop re-squash failed; keeping original" >&2
            MODLOOP_TRIMMED=""
        fi
    else
        echo "  warning: unsquashfs failed; keeping original modloop" >&2
        MODLOOP_TRIMMED=""
    fi
    rm -rf "$WORKDIR/modloop-root" "$WORKDIR/modloop-lts.orig"
else
    echo "warning: no abuild private key found; skipping modloop trim" >&2
    MODLOOP_TRIMMED=""
fi

find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$WORKDIR/initramfs-lts-new.gz"

if [ -n "$MODLOOP_TRIMMED" ]; then
    xorriso -indev "$ISO_IN" -outdev "${ISO_OUT}.tmp" \
        -boot_image any replay \
        -update "$WORKDIR/initramfs-lts-new.gz" /boot/initramfs-lts \
        -update "$MODLOOP_TRIMMED" /boot/modloop-lts \
        -commit 2>/dev/null
else
    xorriso -indev "$ISO_IN" -outdev "${ISO_OUT}.tmp" \
        -boot_image any replay \
        -update "$WORKDIR/initramfs-lts-new.gz" /boot/initramfs-lts \
        -commit 2>/dev/null
fi

mv "${ISO_OUT}.tmp" "$ISO_OUT"

ls -lh /work/out
