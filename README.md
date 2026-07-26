# netoy-os

An Alpine Linux-based bootable ISO image for [netoy-tui](https://forgejo.fedesito.me/fedesito/netoy-tui) (tracked as a **git submodule**) in **integrated** / `for-bootable` mode.

## What this does

- Boots a minimal Alpine environment straight into the netoy-tui Ventoy manager on **both** the serial console and the VGA console.
- Brings the required networking tools: `iwd` (D-Bus) + `impala` for Wi-Fi, `dhcpcd` for Ethernet, `iproute2` for manual/static IP configuration, and `dhcpcd` for DHCP.
- Copies the whole netoy ISO into RAM and neutralizes Ventoy's boot hook, so the Ventoy USB stick (or CD) is no longer needed after init.
- Mounts the real Ventoy data partition read-write at `/mnt/netoy` at boot, so netoy-tui can manage ISOs on it with no runtime trickery.

## Why this is needed

When booted through Ventoy, the ISO lives as a file on the USB data
partition rather than as a real CD-ROM, and Ventoy normally injects a
userspace hook that creates a `device-mapper` node over that partition.
That node pins the data partition read-only, breaks the Alpine boot for
this image, and prevents netoy-tui from mounting it later.

This image sidesteps the whole problem in two small, explicit steps:

1. An **initramfs wrapper** copies the netoy ISO from the Ventoy data
   partition into RAM, attaches it to a loop device, and then
   **neutralizes Ventoy** (drops `/ventoy/ventoy_os_param` and Ventoy's
   udev rules) so no competing `device-mapper` node is ever created
   and the Alpine modloop-extraction hook never runs. Alpine's
   `nlplug-findfs` then discovers the RAM-backed loop as the only boot
   media. Because the boot media is now a file in RAM, the physical USB
   stick can be unplugged.

2. The OpenRC `netoy-ram` service copies the compressed `modloop`
   squashfs into RAM, switches `/.modloop` to the RAM copy, unmounts the
   boot media, removes any leftover Ventoy `device-mapper` nodes, and
   finally mounts the real Ventoy data partition at `/mnt/netoy`.

The result is a system whose `/lib/modules`, firmware, and boot media
all live in RAM, with the Ventoy data partition already mounted for
netoy-tui — no runtime "undo trick" is needed in the TUI.

> **Comparison with Arch:** Arch's `archiso` has a single `copytoram=y`
> kernel parameter that copies the whole live rootfs to RAM. Alpine
> doesn't have an equivalent single flag, so this image uses a small
> custom initramfs wrapper + OpenRC service to achieve the same goal
> while staying within Alpine's official `mkimage.sh` tooling.

## Build

From this directory run:

```sh
./build.sh
```

Requirements on the host:

- `podman`
- The `netoy-tui` git submodule must be initialized: `git submodule update --init`

The script runs the whole build inside an `alpine:3.24` container, compiles `netoy-tui` with `--features for-bootable`, clones and compiles `impala`, and then runs Alpine's official `mkimage.sh` to produce the ISO.

The output ISO is written to `out/`. Newer builds are named with the current date in `YYMMDD` format, e.g. `netoy-260724-x86_64.iso`.

## Test with QEMU over serial

The ISO is configured with both a serial console (`console=ttyS0,115200`) and a VGA console (`console=tty1`) so it can be used headlessly in QEMU or on a monitor. `tty1` (VGA) and `ttyS0` (serial) are auto-login root consoles that launch `netoy-tui`. **Note:** two independent TUI processes will run at the same time; use only one console at a time for USB operations.

```sh
./scripts/qemu-serial.sh
```

This boots the latest ISO with `-nographic` and attaches the serial port to your terminal. Press **Ctrl+A then C** to switch to the QEMU monitor, then type `q` to quit.

What to expect:
- The bootloader (ISOLINUX) and kernel messages appear on the serial line.
- The initramfs wrapper copies the netoy ISO out of the Ventoy data partition into RAM (a progress bar is shown), neutralizes Ventoy's boot hook, and attaches the RAM copy as a loop device; Alpine's `nlplug-findfs` then discovers it as the boot media.
- OpenRC starts the `netoy-ram` service, which copies the modloop into RAM, switches the loop to the RAM copy, unmounts the boot media, removes any Ventoy `device-mapper` nodes, and mounts the real Ventoy data partition at `/mnt/netoy`.
- `ttyS0` and `tty1` auto-log in as root via a tiny `getty -n -l` wrapper; `/root/.profile` then starts `netoy-tui`.
- The TUI draws the welcome screen and the keyboard hints at the bottom. Press **Q** to exit to a shell, and `inittab` will respawn the login shell.
- Root login is allowed without a password on the local console by default.

## Files

| File | Purpose |
|------|---------|
| `build.sh` | Host entry point that launches the container build. |
| `scripts/build-in-container.sh` | Runs inside the Alpine container; installs tools, builds Rust binaries, and invokes `mkimage.sh`. |
| `scripts/qemu-serial.sh` | Boots the latest ISO under QEMU with a serial console for headless testing. |
| `vendor/mkimg.netoy.sh` | Alpine image profile for `mkimage.sh`. |
| `genapkovl-netoy.sh` | Generates the `netoy.apkovl.tar.gz` overlay that sets up services, inittab, and package world. |
| `overlay/usr/local/bin/netoy-autologin` | Tiny wrapper used by `agetty --autologin` to log in root without a password. |
| `overlay/root/.profile` | Auto-starts `netoy-tui` when root logs in on `tty1` or `ttyS0`. |
| `overlay/initramfs-files/netoy-copy-iso.sh` | Copies the netoy ISO from the Ventoy data partition into RAM, neutralizes Ventoy's boot hook, and attaches the RAM copy as a loop device for Alpine's initramfs to discover. |
| `overlay/` | Static files that go into the apkovl. |
| `vendor/` | Vendored Alpine `mkimage.sh` + `mkimg.base.sh` from aports 3.24-stable. |

## After boot

The system auto-logs in as root on every configured console via `agetty --autologin root --login-program /usr/local/bin/netoy-autologin`, which invokes `/bin/login -f root`. `netoy-tui` is started from `/root/.profile` when the login shell runs on `tty1` (VGA) or `ttyS0` (serial). Both consoles run an independent TUI process, so use only one console at a time for USB operations.

`tty2` through `tty6` are also auto-login root and drop straight to a shell.

- `<W>` on the Network screen starts `impala` to configure Wi-Fi.
- `<E>` auto-configures the first Ethernet interface with `dhcpcd` and reports a short status message. Re-check with `<R>` to see the negotiated address.
- `<A>` opens the **manual Ethernet** form on the Network screen. You can choose DHCP or static mode and set interface, IP, CIDR prefix, gateway, two DNS servers, and MTU. Press **Enter** to apply.
- `<M>` on the Manage ISOs screen remounts the Ventoy data partition at `/mnt/netoy` if it isn't already (normally `netoy-ram` mounts it at boot, so this is a no-op).

## Notes / limitations

- The image is intentionally minimal. `iwd` is used for Wi-Fi link layer; `dhcpcd` is used for DHCP; `iproute2` is included for manual/static network configuration.
- If you want an even simpler (but more RAM-hungry) approach, replace the compressed modloop copy in `netoy-ram` with Alpine's official `copy-modloop` tool, which copies the uncompressed `/lib/modules` tree to RAM.
