#!/bin/sh
# Copy the netoy ISO from a local partition into RAM and attach it to a loop
# device so the original Alpine initramfs can discover it via nlplug-findfs.
#
# When booted through Ventoy, the ISO file lives on a normal data partition
# (exfat/vfat/ntfs). Alpine's initramfs only understands real CD/ISO block
# devices, so we present the file as a loop device that nlplug-findfs will
# mount and scan for .boot_repository + apkovl.

# Wait for the Ventoy USB stick to be enumerated. The initramfs may run before
# hotplug has finished, especially with slow USB controllers.
netoy_wait_for_ventoy_usb() {
	local i=0
	while [ "$i" -lt 30 ]; do
		if [ -e /dev/disk/by-label/VTOYEFI ] || [ -e /dev/disk/by-label/Ventoy ]; then
			return 0
		fi
		# also accept any non-loop block device that has shown up
		if blkid -o device 2>/dev/null | grep -v '^/dev/loop' | grep -v '^/dev/sr' | head -n1 | grep -q '^/dev/'; then
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	return 1
}

# Given a real block device (e.g. /dev/sdb1), return the device node that
# can actually be mounted under Ventoy. Ventoy keeps the data partition
# busy with a device-mapper mapping, so the real /dev/sdb1 cannot be mounted
# directly. Two cases:
#   1) /dev/mapper/sdb1 already exists (Ventoy's linux_remount feature) -> use it.
#   2) /dev/mapper/ventoy exists -> find the backing partition from its table
#      and create a linear mapper for the whole partition ourselves.
# If neither applies, return the original device.
netoy_ventoy_data_dev() {
	local dev="$1" name mpdev
	name=${dev#/dev/}
	mpdev="/dev/mapper/$name"

	# Already a Ventoy remapper?
	if [ -b "$mpdev" ]; then
		echo "$mpdev"
		return 0
	fi

	# If /dev/mapper/ventoy is present, use its table to locate the real data
	# partition and create a linear mapper for it.
	if [ -b /dev/mapper/ventoy ] && [ -x /sbin/dmsetup ]; then
		local vmm blkdev
		vmm=$(/sbin/dmsetup table ventoy 2>/dev/null | head -n1 | awk '{print $4}')
		if [ -n "$vmm" ] && [ -r "/sys/class/block/$name/dev" ] && \
		   grep -q "^${vmm}$" "/sys/class/block/$name/dev" 2>/dev/null; then
			echo 0 "$(cat "/sys/class/block/$name/size")" linear "$dev" 0 | \
				/sbin/dmsetup create "$name" 2>/dev/null || true
			/sbin/dmsetup mknodes "$name" 2>/dev/null || true
			if [ -b "$mpdev" ]; then
				echo "$mpdev"
				return 0
			fi
		fi
	fi

	# Not a Ventoy-only scenario, or remapper already exists elsewhere.
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

# Attach FILE to the first free loop device and print the device node.
netoy_setup_loop() {
	local file="$1" loopdev
	# util-linux losetup
	if loopdev=$(losetup --find --show --read-only "$file" 2>/dev/null); then
		echo "$loopdev"
		return 0
	fi
	# busybox losetup
	loopdev=$(losetup -f 2>/dev/null)
	if [ -n "$loopdev" ] && losetup -r "$loopdev" "$file" 2>/dev/null; then
		echo "$loopdev"
		return 0
	fi
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

	for part in $(blkid -o device 2>/dev/null | sort); do
		case "$part" in /dev/loop*) continue ;; esac
		netoy_mount_part "$part" "$mp" || continue

		iso=$(find "$mp" -maxdepth 5 -type f -name 'netoy-*.iso' 2>/dev/null | head -n1)
		[ -z "$iso" ] && iso=$(find "$mp" -maxdepth 3 -type f -name '*.iso' 2>/dev/null | head -n1)

		if [ -n "$iso" ] && [ -f "$iso" ]; then
			size=$(stat -c %s "$iso")
			# Put the ISO copy in its own tmpfs so it does not bloat the
			# initramfs rootfs. Use a directory separate from $mp so the
			# tmpfs mount does not hide the still-mounted partition.
			mkdir -p "$(dirname "$dest")"
			if ! mount -t tmpfs -o "size=$((size + 64 * 1024 * 1024))",mode=0755 netoy_iso_tmp "$(dirname "$dest")" 2>/dev/null; then
				umount "$mp" 2>/dev/null || true
				continue
			fi
			if netoy_copy_with_progress "$iso" "$dest"; then
				umount "$mp" 2>/dev/null || true
				rmdir "$mp" 2>/dev/null || true
				loopdev=$(netoy_setup_loop "$dest")
				if [ -n "$loopdev" ]; then
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
	return 1
}
