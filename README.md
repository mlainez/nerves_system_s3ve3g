# Nerves System: Samsung Galaxy S III Neo

Nerves system for the **Samsung Galaxy S III Neo (GT-I9301I, `s3ve3g`)**:
Qualcomm MSM8228 (msm8226 family), armv7.

| Feature | Description |
| --- | --- |
| CPU | 4x Cortex-A7 @ 1.2 GHz (MSM8228), armv7 |
| Memory | 1.5 GB |
| Storage | 16 GB eMMC; firmware lives inside the stock `userdata` partition |
| Display | 720x1280 AMOLED, via the bootloader's framebuffer and simpledrm |
| Linux | [`msm8226-mainline/linux`](https://github.com/msm8226-mainline/linux) `v6.16.12-msm8226-u2` + board device tree, charger and fuel gauge patches (`patches/linux`) |
| Bootloader | Samsung aboot -> lk2nd (on `boot`) -> `extlinux/extlinux.conf` on the boot subpartition |
| Console | On-device display (`tty1`); ssh over USB (`usb0`, g_ether) |
| Wi-Fi / BT | WCNSS Pronto + WCN3660 (`wcn36xx`, `btqcomsmd`); firmware read from the phone's own partitions |
| Charging | PM8226 SMBB charger, 500 mA input limit |
| Battery | PM8226 BMS1 fuel gauge (`qcom_bms`, power supply `qcom-bms`) |

## Status

Boots on a GT-I9301I: IEx on the screen and over ssh, USB networking, Wi-Fi,
charging and the fuel gauge, A/B upgrades over ssh and `revert`. The layout
and the fwup tasks are also checked on the host
(`scripts/host-check-fwup.sh`, see [Host checks](#host-checks)).

## Dependencies

`install.sh` runs on Linux and needs:

| Distribution | Packages |
| --- | --- |
| Debian, Ubuntu | `sudo apt install heimdall-flash adb curl coreutils gnupg xz-utils` |
| Fedora | `sudo dnf install heimdall android-tools curl coreutils gnupg2 xz` |
| Arch | `sudo pacman -S heimdall android-tools curl coreutils gnupg xz` |

`gzip`, `awk`, `sed` and `od` come with every distribution.

USB access without root, in `/etc/udev/rules.d/51-s3ve3g.rules`:

```
# Samsung phones: Android (adb) and download mode (heimdall, 04e8:685d)
SUBSYSTEM=="usb", ATTR{idVendor}=="04e8", MODE="0660", TAG+="uaccess"
# The phone's USB network under Nerves (0525:a4a2) and the Buildroot port (1d6b:0104)
SUBSYSTEM=="usb", ATTR{idVendor}=="0525", ATTR{idProduct}=="a4a2", TAG+="uaccess"
SUBSYSTEM=="usb", ATTR{idVendor}=="1d6b", ATTR{idProduct}=="0104", TAG+="uaccess"
```

then `sudo udevadm control --reload && sudo udevadm trigger` and replug the
phone. Inside a distrobox or toolbox, put the rule on the host: the
container sees the host's device nodes.

On the phone, once:

- Settings > About device: tap *Build number* seven times, then Settings >
  Developer options > **USB debugging** on.
- Plug the phone in and accept the **Allow USB debugging** prompt for this
  computer (tick *Always allow*).
- Settings > Security > **Reactivation lock** off, and sign out of the
  Samsung account: download mode can refuse custom images otherwise.
- Battery above **50 %**. A good data cable, straight into the computer (no
  hub, no front-panel port).

## Install

From a stock GT-I9301I (Android 4.4) to Nerves, with one command:

```bash
./install.sh            # dry run: checks everything, prints the exact commands
./install.sh --yes      # does it; asks you to type GT-I9301I first
```

What it does:

1. Checks the host tools, that exactly one phone is on adb, that it is a
   `GT-I9301I` (`s3ve3g`) with at least 50 % battery.
2. Downloads the latest release of the firmware repository
   (`--repo OWNER/NAME`, default `mlainez/hello_s3ve3g`; `--tag` for another
   one): the Nerves image, `lk2nd-s3ve3g.img` and `SHA256SUMS`, and checks
   every file against `SHA256SUMS`. Downloads TWRP 3.3.1-1 for `s3ve3g` from
   dl.twrp.me and checks it against a pinned sha256, the published one and
   TeamWin's PGP signature (key `95707D42307C9D41D09BF7091D8597D7891A43DF`).
3. Android -> download mode -> `heimdall flash --RECOVERY` TWRP -> Android ->
   `adb reboot recovery`.
4. From TWRP (root), copies `efs`, `modemst1`, `modemst2`, `fsg`, `fsc`,
   `persist`, `persdata`, `param`, `ssd` and the stock `boot` to
   `./backups-<serial>-<date>/`, each one hashed on the phone and on the
   computer, and checks the partition table.
5. TWRP -> download mode -> `heimdall flash --BOOT lk2nd-s3ve3g.img
   --USERDATA <image>.img` -> the phone reboots into Nerves; the script waits
   for its USB network and prints how to connect (`ssh nerves.local`).

Read this before `--yes`:

- **KNOX:** the first unofficial RECOVERY or BOOT image (TWRP here) sets the
  warranty bit, an e-fuse. It cannot be undone; reflashing Samsung firmware
  does not reset it.
- **Everything on the phone is erased** (`userdata`).
- There is **no bootloader unlock** on this phone, and none is needed:
  Samsung's bootloader warns about unsigned BOOT/RECOVERY images and starts
  them anyway.
- The script writes RECOVERY, BOOT and USERDATA only. Never the
  bootloaders, never a PIT (`--repartition`/`--pit`), never a whole Odin
  tar: the stock AP tar would overwrite this phone's `persist` calibration.
- The stock recovery is not backed up: it can only be read with root, which
  needs TWRP in its place first. Samsung's firmware has it (`recovery.img`
  in the AP tar).

If a step fails, the script stops and says what state the phone is in and
how to go on. It can be run again from TWRP: it then skips step 3.

TWRP is downloaded from twrp.me, never redistributed. lk2nd is
[msm8916-mainline/lk2nd](https://github.com/msm8916-mainline/lk2nd) 23.1
with an `s3ve3g` device entry (MIT and BSD-3-Clause, see its `LICENSE` and
`lk2nd/LICENSE`); each release carries those notices and names the lk2nd
commit it was built from.

## Back to Android

Download mode (Volume Down + Home + Power, Volume Up at the warning), then:

```bash
heimdall flash --BOOT backups-<serial>-<date>/boot.img
```

and from TWRP (Volume Up + Home + Power), *Wipe > Format Data*, then reboot:
Android starts as after a factory reset. For the stock recovery as well,
`heimdall flash --RECOVERY recovery.img` with the `recovery.img` of
Samsung's firmware for the GT-I9301I. The backed-up partitions are never
written by this system, so they only matter if something else damages them;
they go back from TWRP with `dd`.

## Using

In your Nerves application's `mix.exs`, add the system under a target name
of your choice (here `:s3ve3g`):

```elixir
@all_targets [:s3ve3g]

defp deps do
  [
    {:nerves_system_s3ve3g,
     path: "../nerves_system_s3ve3g", runtime: false, targets: :s3ve3g,
     nerves: [compile: true]},
    {:nerves_pack, "~> 0.7.1", targets: @all_targets},
    # Images flashed raw keep their build-time application partition size.
    {:nerves_data_resize, github: "mlainez/nerves_data_resize", targets: @all_targets}
  ]
end
```

Then set `MIX_TARGET=s3ve3g`. USB networking is `usb0` with
`VintageNetDirect`; Wi-Fi is `wlan0` with `VintageNetWiFi`. The MAC
addresses from the phone's `efs` partition are copied to
`/run/s3ve3g/wlan0.mac` and `/run/s3ve3g/bt.mac` at boot, for a
`mac_address` callback.

## Building

You need the Nerves toolchain prerequisites (Erlang/OTP 29, Elixir 1.20,
`fwup`, `squashfs-tools`, `cmake`, `autoconf`, `bc`, `libssl-dev`), and about
15 GB of free disk for the Buildroot build.

```bash
mix archive.install hex nerves_bootstrap
cd your_app
export MIX_TARGET=s3ve3g
mix deps.get          # toolchain (~250 MB), Buildroot, kernel tarball
mix firmware          # first build 30-60 min
mix firmware.image    # raw image of the whole userdata layout
```

Useful side channels:

- `mix nerves.system.shell`: a shell in the Buildroot build directory, for
  `make menuconfig` / `make linux-menuconfig`
- `MIX_DEBUG=1 mix compile`: every Buildroot command
- `rm -rf _build/s3ve3g_* && mix deps.compile nerves_system_s3ve3g --force`:
  rebuild the system after a defconfig change

`nerves_defconfig` pins the kernel to a commit tarball. To build from a local
checkout instead, copy `local.mk.example` to `local.mk`.

## Partition layout

The Samsung bootloader chain cannot be repartitioned, so the whole Nerves
layout is nested *inside* the stock `userdata` partition (`mmcblk0p26`,
24536415 blocks, 11.70 GiB).

```
userdata (mmcblk0p26)  ── heimdall flash --USERDATA <app>.img ──
├─ MBR             block 0
├─ uboot env       block 2048     (8 KiB, firmware metadata)
├─ Boot A          block 2064     (ext2, 64 MiB: zImage, DTB, initramfs, extlinux)
├─ Boot B          block 133136   (ext2, 64 MiB)
├─ Rootfs A        block 264208   (squashfs, 384 MiB)
├─ Rootfs B        block 1050640  (squashfs, 384 MiB)
└─ Application     block 1837072  (f2fs, 256 MiB as flashed; grow-app extends it
                                   to block 24536415, mounted at /root)
```

The nested MBR always lists the slot that boots next as partitions 1 and 2;
the other slot is not in the table. Switching slots is one MBR write.

| Alias (made by the initramfs) | What |
| --- | --- |
| `/dev/rootdisk0`, `/dev/nerves-userdata` | the stock `userdata` partition, found by GPT name |
| `/dev/nerves-boot` | partition 1: the active boot slot, mounted read-only at `/boot` |
| `/dev/nerves-rootfs` | partition 2: the active squashfs rootfs |
| `/dev/nerves-app` | partition 3: application data, f2fs, `/root` |
| `/dev/nerves-apnhlos`, `-system`, `-modem`, `-efs`, `-persist` | stock partitions; `apnhlos` and `system` are mounted read-only for firmware |

## Boot chain

```
Samsung aboot ── keys, restart reason ──▶ lk2nd (first 512 KiB of `boot`)
lk2nd ── every GPT partition, then the MBR inside each one; ext2 leaves >= 16 MiB
      ──▶ /extlinux/extlinux.conf on userdata's nested partition 1 (the active boot slot)
kernel + initramfs ── nerves_base=userdata: GPT name lookup, kpartx, mount p2, switch_root
      ──▶ erlinit ──▶ s3ve3g-bringup ──▶ your OTP release
```

lk2nd publishes each GPT partition as a block device and runs its MBR
parser over each one (`lk2nd/hw/bdev/wrapper.c`), so the nested layout
appears as another level of block devices. It mounts each leaf of 16 MiB or
more as ext2 and boots the first `/extlinux/extlinux.conf` it finds. Its
ext2 driver reads plain ext2 only, which is what `genext2fs` writes. Kernel,
initramfs and DTB share 50 MiB of boot memory; `scripts/create-boot-img.sh`
refuses a payload over 47 MiB.

lk2nd has no boot menu, no boot counter and no way to receive a slot choice
from Linux (Samsung aboot consumes the restart reason). So:

- an upgrade marks the new slot valid as soon as fwup finishes, as in the
  official Nerves systems without automatic fallback;
- going back is an explicit `Nerves.Runtime.revert()`, or one of the escape
  routes below.

## Updating

Over the network (USB or Wi-Fi), as on any Nerves device:

```bash
mix firmware && mix upload nerves-XXXX.local   # or the usb0 address
```

`fwup` writes the inactive slot, then flips `nerves_fw_active` and the
nested MBR; the next reboot runs the new slot. `Nerves.Runtime.revert()`
flips them back and reboots.

Do not upload twice without rebooting in between: the second upload would
write over the slot that is running (`require-path-at-offset` cannot see
through the kpartx mapping, so fwup cannot tell which slot is running).

### Rebooting into Odin (download mode) from Nerves

```elixir
File.write!("/run/reboot-param", "download")
Nerves.Runtime.reboot()
```

erlinit passes the contents of `/run/reboot-param` to `reboot(2)`; the
kernel's syscon-reboot-mode writes the Samsung magic to IMEM, and
`reboot=warm` keeps IMEM across the reset, so aboot enters download mode.

### Re-imaging everything

In download mode (`Vol Down + Home + Power`, then `Vol Up`, or the reboot
above):

```bash
heimdall flash --USERDATA your_app.img
```

heimdall writes the raw file from the start of `userdata` (it does not
unpack Android sparse images). Application data is lost.

## Escape routes

1. **The new firmware boots but misbehaves:** `Nerves.Runtime.revert()`.
2. **The initramfs cannot mount the rootfs:** it brings up `usb0` at
   `10.0.42.1` and a telnet shell (`telnet 10.0.42.1`) to look at `dmesg`
   and the partitions. To get a working system back, see 3.
3. **Anything else:** download mode and `heimdall flash --USERDATA` with a
   known-good Nerves `.img`. `boot` (lk2nd) is never written by this
   system.

## Driver bring-up

erlinit is PID 1 and there is no init system. `/usr/sbin/s3ve3g-bringup`
runs through erlinit's `--pre-run-exec`, after the mounts and before Erlang:

1. link `wcnss.mdt` and its segments from `/mnt/apnhlos/image` (vfat,
   read-only) and `WCNSS_qcom_wlan_nv.bin` from `/mnt/system`
   (stock ext4, read-only, `noload`) into `/run/firmware`;
2. point `firmware_class.path` at it;
3. copy the Wi-Fi and Bluetooth MAC addresses from `efs` (mounted read-only
   with `noload` for the copy, then unmounted) to `/run/s3ve3g`;
4. `modprobe qcom_spmi_vadc qcom_bms` (battery ADC, then the fuel gauge);
5. `modprobe qcom_wcnss_pil wcn36xx btqcomsmd`.

It always exits 0; `dmesg | grep s3ve3g-bringup` shows what it found.
nerves_uevent loads other modules by alias as devices appear;
`/etc/modprobe.d/s3ve3g-display.conf` keeps `msm` and the panel drivers
from taking the display over from simpledrm.

## Host checks

```bash
scripts/host-check-fwup.sh [work-dir]
```

Builds `.fw` files from stand-in images (or from `BINARIES_DIR` after a
real build), runs `complete` into a file, copies it into a sparse file the
size of `userdata` the way heimdall would, and checks the nested MBR, the
U-Boot environment, lk2nd's partition rules, upgrade, status, revert,
validate, prevent-revert, grow-app and factory-reset.

## Known gaps

- No automatic fallback to the previous slot (lk2nd has no boot counter).
- Charging stays at a 500 mA input limit for every cable; the temperature
  policy Samsung enforced in software is not implemented.
- No modem, audio, sensors, touchscreen or GPU.
- `status` reports the slot that boots next, not the running one, between
  an upgrade and the reboot after it.

## License

Apache-2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE).
