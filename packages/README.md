# Buildroot packages

Every package's `Config.in` title carries a scope tag indicating how
hardware-specific it is.

| Tag | Meaning |
|---|---|
| `[Galaxy S III Neo]` | Bound to this phone: its partition names, its firmware locations. |
| `[Qualcomm generic]` | Works on any Qualcomm SoC with the relevant kernel subsystem. |
| `[Generic]` | No hardware dependency. Could move upstream to `nerves_system_br`. |

## Current packages

| Package | Tag | Notes |
|---|---|---|
| `citronics-initramfs` | `[Galaxy S III Neo]` | Early-boot initramfs: finds `userdata` by GPT name, maps the nested Nerves partitions with kpartx, pivots into the squashfs; USB telnet recovery on failure. |
| `s3ve3g-firmware` | `[Galaxy S III Neo]` | `s3ve3g-bringup`: links the WCNSS firmware from the stock `apnhlos`/`system` partitions into `/run/firmware`, copies the MAC addresses off `efs`, loads the Wi-Fi/Bluetooth drivers. Ships no firmware. |
| `reboot-mode` | `[Qualcomm generic]` | Reboots with a `LINUX_REBOOT_CMD_RESTART2` argument (`download` on this phone). Skips erlinit's graceful shutdown; from Elixir, prefer `/run/reboot-param` + `Nerves.Runtime.reboot/0`. |
| `unudhcpd` | `[Generic]` | Single-address DHCP server for the initramfs USB recovery shell. |

`citronics-initramfs`, `reboot-mode` and `unudhcpd` follow
[`nerves_system_tickwatch_pro3`](https://github.com/mlainez/nerves_system_tickwatch_pro3);
the initramfs patches are rebased for this phone (partition aliases, a
30 s wait for the USB gadget, which needs the SM5502 MUIC to probe first).

## What the Buildroot port ran, and what replaces it

The port's Buildroot system (`buildroot-android`, `s3ve3g_defconfig`) ran
BusyBox init scripts. Each one maps to:

| Buildroot | Here |
|---|---|
| BusyBox init, `rootfs-check` (e2fsck of the ext2 root) | erlinit; read-only squashfs root, f2fs `/root` formatted by nerves_runtime when corrupt |
| `S05watchdog` (busybox watchdog on the KPSS watchdog) | `nerves_heart`, through erlinit |
| `S10mdev`, `modules-coldplug` | `nerves_uevent` (module autoload by alias), with the display blacklist in `/etc/modprobe.d` |
| `S45usb-gadget` (configfs ACM + NCM, unudhcpd, telnetd) | built-in g_ether, `VintageNetDirect` on `usb0` |
| `S50dropbear` | `nerves_ssh` |
| `S99status`, `ttygs0-console` | IEx on `tty1`, `RingLogger` |
| (Wi-Fi bring-up, in progress there) | `s3ve3g-bringup` + `VintageNetWiFi` |
