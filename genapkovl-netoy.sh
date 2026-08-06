#!/bin/sh -e

HOSTNAME="$1"
if [ -z "$HOSTNAME" ]; then
	echo "usage: $0 hostname"
	exit 1
fi

OVERLAY="${NETOY_OVERLAY:-$(readlink -f "$(dirname "$0")/overlay")}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Copy the static overlay tree (init scripts, inittab, repositories, etc.)
# Includes dnscrypt-proxy config and resolver cache for DoH support.
if [ -d "$OVERLAY" ]; then
	cp -a "$OVERLAY/." "$tmp/"
	# The initramfs wrapper files are consumed during ISO post-processing,
	# they do not belong in the runtime apkovl.
	rm -rf "$tmp/initramfs-files"
	# Root's home files are copied from the host overlay; make sure they are
	# owned by root in the generated apkovl.
	if [ -d "$tmp/root" ]; then
		chown -R root:root "$tmp/root"
	fi
fi

makefile() {
	owner="$1"; perms="$2"; file="$3"
	mkdir -p "$(dirname "$file")"
	cat > "$file"
	chown "$owner" "$file"
	chmod "$perms" "$file"
}

rc_add() {
	mkdir -p "$tmp/etc/runlevels/$2"
	ln -sf "/etc/init.d/$1" "$tmp/etc/runlevels/$2/$1"
}

mkdir -p "$tmp/etc"
makefile root:root 0644 "$tmp/etc/hostname" <<EOF
$HOSTNAME
EOF

# -----------------------------------------------------------------------------
# OpenRC runlevels
# -----------------------------------------------------------------------------
rc_add devfs sysinit
rc_add dmesg sysinit
rc_add udev sysinit
rc_add udev-trigger sysinit
rc_add hwdrivers sysinit
rc_add modloop sysinit

rc_add netoy-ram boot

rc_add hwclock boot
rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add syslog boot

rc_add dbus default
rc_add networkmanager default

rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

# -----------------------------------------------------------------------------
# Bundle the overlay into the apkovl tarball that the initramfs will unpack.
# Include root/ only when the overlay provides it (custom overlays may omit it).
tar_args="etc usr var"
[ -d "$tmp/root" ] && tar_args="$tar_args root"
tar -c -C "$tmp" $tar_args | gzip -9n > "$HOSTNAME.apkovl.tar.gz"
