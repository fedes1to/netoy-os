#!/bin/sh
# Copy the netoy ISO from a local partition into RAM and attach it to a loop
# device so the original Alpine initramfs can discover it via nlplug-findfs.
#
# When booted through Ventoy, the ISO file lives on a normal data partition
# (exfat/vfat/ntfs). Alpine's initramfs only understands real CD/ISO block
# devices, so we present the file as a loop device that nlplug-findfs will
# mount and scan for .boot_repository + apkovl.

# Send a message to the kernel console. The kernel log console always captures
# /dev/console, whereas userspace stdout may not be visible depending on which
# console the bootloader/kernel assigned to init.
netoy_log() {
	printf 'netoy: %s\n' "$*" > /dev/kmsg 2>/dev/null || true
}

# The initramfs /dev may be a static cpio directory or devtmpfs that does not
# create partition nodes for newly discovered disks. Parse /proc/partitions and
# create any missing partition device nodes with mknod so the rest of the
# script can treat them like normal block devices.
netoy_ensure_partition_nodes() {
	local major minor blocks name
	while read -r major minor blocks name; do
		case "$name" in
		''|name|loop*|ram*|dm-*|sr*) continue ;;
		esac
		case "$name" in
		sd*[0-9]|nvme*n*p*|vd*[0-9]|hd*[0-9]|xvd*[0-9])
			[ -b "/dev/$name" ] && continue
			mknod "/dev/$name" b "$major" "$minor" 2>/dev/null || continue
			netoy_log "created /dev/$name ($major:$minor)"
			;;
		esac
	done < /proc/partitions
}

# Wait for the Ventoy USB stick to be enumerated. The initramfs may run before
# hotplug has finished, especially with slow USB controllers.
netoy_wait_for_ventoy_usb() {
	local i=0 d

	netoy_log 'waiting for a Ventoy USB data partition to appear'

	# Load filesystem modules first so mount can make sense of the partition
	# as soon as the block device appears.
	modprobe -q exfat 2>/dev/null || true
	modprobe -q ntfs3 2>/dev/null || true
	modprobe -q vfat 2>/dev/null || true
	modprobe -q ext4 2>/dev/null || true

	while [ "$i" -lt 120 ]; do
		# Fast path: labelled Ventoy partitions (created when mdev/udev runs).
		if [ -e /dev/disk/by-label/VTOYEFI ] || [ -e /dev/disk/by-label/Ventoy ]; then
			netoy_log 'found Ventoy labelled partition'
			return 0
		fi

		netoy_ensure_partition_nodes

		# Check for any partition device node. We avoid relying on blkid here
		# because some configurations fail to identify a filesystem until the
		# correct NLS module is loaded, and the mount attempts below will try
		# filesystems directly anyway.
		for d in /dev/sd*[0-9] /dev/nvme*n*p* /dev/vd*[0-9] /dev/hd*[0-9] /dev/xvd*[0-9]; do
			case "$d" in
			/dev/sr*|/dev/loop*) continue ;;
			esac
			if [ -b "$d" ]; then
				netoy_log "found candidate partition $d"
				return 0
			fi
		done

		if [ $((i % 5)) -eq 0 ]; then
			netoy_log "still waiting for USB storage... (${i}s)"
			netoy_log "proc partitions: $(awk 'NR>1 {print $4}' /proc/partitions | tr '\n' ' ')"
			netoy_log "dev nodes: $(ls -1 /dev/sd* /dev/vd* /dev/nvme* /dev/hd* /dev/xvd* 2>/dev/null | tr '\n' ' ')"
		fi

		sleep 1
		i=$((i + 1))
	done
	netoy_log 'timeout waiting for USB storage'
	return 1
}

# Given a real block device (e.g. /dev/sdb1), return any Ventoy-provided
# device-mapper node that shadows it. If none exists, return the original
# device so the caller can mount it directly.
netoy_ventoy_data_dev() {
	local dev="$1" name mpdev
	name=${dev#/dev/}
	mpdev="/dev/mapper/$name"

	# Ventoy's linux_remount may create a per-partition mapper.
	if [ -b "$mpdev" ]; then
		echo "$mpdev"
		return 0
	fi

	echo "$dev"
	return 0
}
netoy_mount_part() {
	local part="$1" mp="$2" dev
	dev=$(netoy_ventoy_data_dev "$part")
	mount -o ro -t exfat "$dev" "$mp" 2>/dev/null && return 0
	mount -o ro -t vfat "$dev" "$mp" 2>/dev/null && return 0
	mount -o ro -t ntfs3 "$dev" "$mp" 2>/dev/null && return 0
	mount -o ro -t ext4 "$dev" "$mp" 2>/dev/null && return 0
	mount -o ro "$dev" "$mp" 2>/dev/null && return 0

	# If the real partition is busy, Ventoy may have created a device-mapper
	# node over the data partition. Try that as a last resort.
	for m in /dev/mapper/ventoy /dev/mapper/vtoy; do
		[ -b "$m" ] || continue
		mount -o ro -t exfat "$m" "$mp" 2>/dev/null && return 0
		mount -o ro -t vfat "$m" "$mp" 2>/dev/null && return 0
		mount -o ro -t ntfs3 "$m" "$mp" 2>/dev/null && return 0
		mount -o ro -t ext4 "$m" "$mp" 2>/dev/null && return 0
		mount -o ro "$m" "$mp" 2>/dev/null && return 0
	done
	return 1
}

# Neutralize Ventoy's userspace hook so it cannot create a competing
# /dev/mapper/ventoy device-mapper node (which would pin the USB data
# partition) and cannot run the Alpine-specific modloop extraction that
# hangs for this ISO. Ventoy's job of loading the kernel + initramfs is
# already done by the time /init runs; the /ventoy/* files are only data
# for the userspace hook. We only call this AFTER the ISO copy is in RAM,
# so if the copy failed we leave Ventoy intact as a fallback boot source.
netoy_neutralize_ventoy() {
	rm -f /ventoy/ventoy_os_param 2>/dev/null || true
	rm -f /ventoy/inotifyd-hook-script.txt 2>/dev/null || true
	rm -f /ventoy/hook_finish 2>/dev/null || true
	# Drop any udev rule Ventoy's default hook may have registered that
	# would run udev_disk_hook.sh on block-device add events.
	for d in /etc/udev/rules.d /lib/udev/rules.d /usr/lib/udev/rules.d; do
		[ -d "$d" ] || continue
		rm -f "$d"/*ventoy* "$d"/99-ventoy.rules 2>/dev/null || true
	done
	return 0
}

# Copy a file in 4 MB chunks and print a simple progress bar.
netoy_copy_with_progress() {
	local src="$1" dst="$2"
	local size total_mb bs chunk_mb count rem i pct
	size=$(stat -c %s "$src")
	total_mb=$((size / 1024 / 1024))
	bs=$((4 * 1024 * 1024))
	chunk_mb=4
	count=$((size / bs))
	rem=$((size % bs))
	i=0

	printf "Copying ISO to RAM (%s MB)...\n" "$total_mb"
	while [ "$i" -lt "$count" ]; do
		if ! dd if="$src" of="$dst" bs="$bs" seek="$i" skip="$i" count=1 conv=notrunc 2>/dev/null; then
			printf "\nERROR: failed copying chunk %d/%d\n" "$i" "$count" >&2
			return 1
		fi
		i=$((i + 1))
		pct=$((i * 100 / count))
		printf "\r[%3d%%] %d MB / %d MB" "$pct" "$((i * chunk_mb))" "$((count * chunk_mb))"
	done
	if [ "$rem" -gt 0 ]; then
		if ! dd if="$src" of="$dst" bs=1 seek=$((count * bs)) skip=$((count * bs)) count="$rem" conv=notrunc 2>/dev/null; then
			printf "\nERROR: failed copying remainder\n" >&2
			return 1
		fi
	fi
	printf "\r[100%%] %d MB / %d MB done\n" "$total_mb" "$total_mb"
	return 0
}

# Attach FILE to /dev/loop0 so the original Alpine initramfs can discover it
# as boot media. We use a fixed device node because the init script is patched
# to tell nlplug-findfs to search only this device.
netoy_setup_loop() {
	local file="$1" loopdev="/dev/loop0"

	# Make sure the loop module is loaded. nlplug-findfs needs the loop
	# device to exist as a real block device; if the module is not loaded
	# when losetup runs the attach silently fails and the boot media is never
	# discovered.
	modprobe -q loop 2>/dev/null || true

	# Ensure the loop0 device node exists and is a block device.
	# Remove any existing node (might be a character device) and recreate it.
	rm -f "$loopdev" 2>/dev/null || true
	mknod "$loopdev" b 7 0 2>/dev/null || true
	netoy_log "losetup: creating node $loopdev"

	# Detach any stale association, then attach our RAM copy read-only.
	losetup -d "$loopdev" 2>/dev/null || true
	if losetup -r "$loopdev" "$file" 2>/dev/null; then
		netoy_log "losetup succeeded"
		# Trigger a uevent so devtmpfs updates the node type if needed.
		printf 'add\n' > "/sys/block/${loopdev##*/}/uevent" 2>/dev/null || true
		# Recreate node as block device to ensure mount works
		rm -f "$loopdev" 2>/dev/null || true
		mknod "$loopdev" b 7 0 2>/dev/null || true
		echo "$loopdev"
		return 0
	fi
	netoy_log "losetup failed, trying to recreate node"
	# Recreate node in case it disappeared
	rm -f "$loopdev" 2>/dev/null || true
	mknod "$loopdev" b 7 0 2>/dev/null || true
	if losetup -r "$loopdev" "$file" 2>/dev/null; then
		netoy_log "losetup succeeded after recreate"
		printf 'add\n' > "/sys/block/${loopdev##*/}/uevent" 2>/dev/null || true
		echo "$loopdev"
		return 0
	fi
	netoy_log "losetup still failed"
	return 1
}

netoy_find_and_copy_iso() {
	local part iso mp="/run/netoy-iso/mp" dest="/run/netoy-iso-ram/iso" size loopdev

	# Wait for the Ventoy USB stick to appear before scanning.
	netoy_wait_for_ventoy_usb || true

	modprobe -q exfat 2>/dev/null || true
	modprobe -q ntfs3 2>/dev/null || true
	modprobe -q vfat 2>/dev/null || true
	modprobe -q ext4 2>/dev/null || true

	mkdir -p "$mp" "$(dirname "$dest")"
	netoy_log 'scanning partitions for ISO file'

	# Make sure all partition device nodes exist before scanning.
	netoy_ensure_partition_nodes

	# Scan all partition-like block devices from /proc/partitions. blkid
	# sometimes misses filesystems in this minimal environment, so we mount
	# each candidate directly.
	for part in $(blkid -o device 2>/dev/null | sort) /dev/sd*[0-9] /dev/nvme*n*p* /dev/vd*[0-9] /dev/hd*[0-9] /dev/xvd*[0-9]; do
		case "$part" in /dev/loop*|/dev/sr*|[!/]*) continue ;; esac
		[ -b "$part" ] || continue
		netoy_log "trying partition $part"
		netoy_mount_part "$part" "$mp" || {
			netoy_log "could not mount $part"
			continue
		}

		iso=$(find "$mp" -maxdepth 5 -type f -name 'netoy-*.iso' 2>/dev/null | head -n1)
		[ -z "$iso" ] && iso=$(find "$mp" -maxdepth 3 -type f -name '*.iso' 2>/dev/null | head -n1)

		if [ -n "$iso" ] && [ -f "$iso" ]; then
			netoy_log "found ISO at $iso"
			size=$(stat -c %s "$iso")
			# Put the ISO copy in its own tmpfs so it does not bloat the
			# initramfs rootfs. Use a directory separate from $mp so the
			# tmpfs mount does not hide the still-mounted partition.
			mkdir -p "$(dirname "$dest")"
			if ! mount -t tmpfs -o "size=$((size + 64 * 1024 * 1024))",mode=0755 netoy_iso_tmp "$(dirname "$dest")" 2>/dev/null; then
				netoy_log 'failed to allocate tmpfs for ISO copy'
				umount "$mp" 2>/dev/null || true
				continue
			fi
			if netoy_copy_with_progress "$iso" "$dest"; then
				umount "$mp" 2>/dev/null || true
				rmdir "$mp" 2>/dev/null || true
				loopdev=$(netoy_setup_loop "$dest")
				if [ -n "$loopdev" ]; then
					netoy_log "ISO attached on $loopdev"
					# The RAM loop is now the ISO's only boot media. Prevent
					# Ventoy's userspace hook from creating a competing dm
					# node that would re-pin the USB data partition.
					netoy_neutralize_ventoy
					# Make sure nlplug-findfs gets an add event for the new
					# loop device, even if the coldplug scan already ran.
					printf 'add\n' > "/sys/block/${loopdev##*/}/uevent" 2>/dev/null || true
					# nlplug-findfs will discover /dev/loopX, mount it at
					# /media/<loopdev>, and find .boot_repository + apkovl.
					return 0
				fi
			fi
			umount "$(dirname "$dest")" 2>/dev/null || true
		fi
		umount "$mp" 2>/dev/null || true
		rmdir "$mp" 2>/dev/null || true
	done
	netoy_log 'no ISO found on any USB partition'
	return 1
}
