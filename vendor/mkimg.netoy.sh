profile_netoy() {
	profile_base
	profile_abbrev="netoy"
	title="netoy"
	desc="Minimal Alpine-based bootable ISO for the netoy-tui Ventoy manager.
		Runs from RAM so the Ventoy USB can be unmounted after boot."
	arch="x86_64"
	image_ext="iso"
	output_format="iso"
	apkovl="genapkovl-netoy.sh"
	hostname="netoy"

	kernel_addons=
	boot_addons=
	initfs_cmdline="modules=loop,squashfs,sd-mod,usb-storage,iso9660,sr_mod console=ttyS0,115200 console=tty1 debug_init"
	initfs_features="ata base cdrom ext4 mmc nvme nfit scsi squashfs usb virtio netoy"

	# Packages fetched into the ISO's boot repository. These must be a
	# superset of the packages listed in the apkovl's /etc/apk/world.
	image_name="netoy"
	apks="
		alpine-base
		libgcc
		openssl
		psmisc
		iproute2
		networkmanager
		networkmanager-wifi
		networkmanager-tui
		networkmanager-openrc
		networkmanager-cli
		wpa_supplicant
		iwd
		iwd-openrc
		dbus
		eudev
		ca-certificates
		dnscrypt-proxy
		dnscrypt-proxy-openrc
		agetty
		util-linux-login
		lynx
		curl
		wget
		bash
	"
}

# Use a clean, space-free ISO volume label.  The default Alpine label contains
# spaces, which breaks GRUB/Ventoy searches and cannot be passed safely on the
# kernel command line.  The same label is used for alpine_dev=LABEL=... so the
# initramfs can find the boot media when automatic detection fails.
gen_volid() {
	printf "NETOY-%s-%s" "${RELEASE%_rc*}" "$ARCH"
}
