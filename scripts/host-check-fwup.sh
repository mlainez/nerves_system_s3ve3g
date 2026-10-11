#!/usr/bin/env bash
#
# host-check-fwup.sh [work-dir]
#
# Exercises fwup.conf and fwup-ops.conf on files, without a phone and without
# a Buildroot build:
#
#   1. builds two .fw archives (versions 0.0.1 and 0.0.2) from a stand-in
#      boot.img (made by scripts/create-boot-img.sh) and a stand-in squashfs;
#   2. runs `complete` into an image file, the way `mix firmware.image` does,
#      then copies it to the start of a sparse file the size of the phone's
#      userdata partition, the way `heimdall flash --USERDATA` does;
#   3. checks the nested MBR, the U-Boot environment, and that lk2nd's
#      partition rules (lib/partition/partition.c, lk2nd/boot/boot.c) would
#      find /extlinux/extlinux.conf on the boot slot and nowhere else;
#   4. runs upgrade, status, revert, validate, prevent-revert and grow-app
#      on that file and checks each result.
#
# Real kernel, DTB and initramfs are used when BINARIES_DIR points at a
# Buildroot images directory; otherwise small stand-ins are generated.
#
# Needs: fwup, genext2fs, mksquashfs, unsquashfs, debugfs, sfdisk, python3.

set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=${1:-$(mktemp -d /tmp/s3ve3g-fwup-check.XXXXXX)}
mkdir -p "$WORK"
cd "$WORK"

# userdata (mmcblk0p26) on the GT-I9301I, from the GPT.
USERDATA_BLOCKS=24536415

pass=0
check() {
    local what=$1; shift
    if "$@"; then
        echo "PASS  $what"
        pass=$((pass + 1))
    else
        echo "FAIL  $what" >&2
        exit 1
    fi
}

# --enable-trim matches how nerves_runtime calls ops.fw; fwup ignores it on
# regular files.
fwup_ops() {
    fwup -q -U --enable-trim -a -i ops.fw -t "$1" -d userdata.img 2>&1
}

# The last info() line a task printed, e.g. "a" for status.
ops_info() {
    fwup_ops "$1" | sed -n 's/^fwup: //p' | grep -v '^ignoring --enable-trim' | tail -1
}

# --- stand-in system images ----------------------------------------------------
mkdir -p system/images
export NERVES_SYSTEM=$WORK/system
export NERVES_SDK_IMAGES=$HERE

if [ -n "${BINARIES_DIR:-}" ]; then
    cp "$BINARIES_DIR/boot.img" "$BINARIES_DIR/rootfs.squashfs" system/images/
else
    mkdir -p bin
    head -c $((6 * 1024 * 1024)) /dev/urandom > bin/zImage
    head -c 32768 /dev/urandom > bin/qcom-msm8226-samsung-s3ve3g.dtb
    head -c $((3 * 1024 * 1024)) /dev/urandom > bin/initramfs.gz
    BINARIES_DIR=$WORK/bin NERVES_DEFCONFIG_DIR=$HERE "$HERE/scripts/create-boot-img.sh"
    cp bin/boot.img system/images/boot.img
    mkdir -p rootfs/srv/erlang rootfs/usr/share/fwup
    echo "stand-in" > rootfs/srv/erlang/README
    mksquashfs rootfs system/images/rootfs.squashfs -comp lz4 -noappend -quiet
    unset BINARIES_DIR
fi

NERVES_SDK_VERSION=0.0.1 fwup -c -f "$HERE/fwup.conf" -o v1.fw
NERVES_SDK_VERSION=0.0.2 fwup -c -f "$HERE/fwup.conf" -o v2.fw
fwup -c -f "$HERE/fwup-ops.conf" -o ops.fw
check "fwup.conf and fwup-ops.conf compile" true

# --- complete, as mix firmware.image + heimdall --------------------------------
rm -f nerves.img
fwup -q -a -i v1.fw -t complete -d nerves.img
truncate -s $((USERDATA_BLOCKS * 512)) userdata.img
dd if=nerves.img of=userdata.img conv=notrunc,sparse bs=1M status=none
echo "image: $(stat -c %s nerves.img) bytes ($(( $(stat -c %s nerves.img) / 1024 / 1024 )) MiB)"

# Prints "start size type bootflag" for each MBR entry, then the env as k=v.
inspect() {
    python3 -I - "$1" <<'PY'
import struct, sys, zlib
path = sys.argv[1]
with open(path, "rb") as f:
    mbr = f.read(512)
    f.seek(2048 * 512)
    env = f.read(8192)
assert mbr[510:512] == b"\x55\xaa", "no MBR signature"
for i in range(4):
    e = mbr[446 + 16 * i: 446 + 16 * (i + 1)]
    status, ptype = e[0], e[4]
    start, size = struct.unpack("<II", e[8:16])
    print(f"part{i} {start} {size} {ptype:#x} {status:#x}")
crc = struct.unpack("<I", env[:4])[0]
data = env[4:]
assert zlib.crc32(data) & 0xffffffff == crc, "env CRC mismatch"
for kv in data.split(b"\0"):
    if not kv:
        break
    print("env " + kv.decode())
PY
}

part() { inspect userdata.img | awk -v p="part$1" '$1 == p {print $2, $3}'; }
env_get() { inspect userdata.img | sed -n "s/^env $1=//p"; }

check "MBR slot A: boot 2064+131072, rootfs 264208+786432" \
    test "$(part 0)/$(part 1)" = "2064 131072/264208 786432"
check "MBR app partition 1837072+524288" test "$(part 2)" = "1837072 524288"
check "env nerves_fw_active=a" test "$(env_get nerves_fw_active)" = a
check "env a.nerves_fw_version=0.0.1" test "$(env_get a.nerves_fw_version)" = 0.0.1
check "env a.nerves_fw_validated=1" test "$(env_get a.nerves_fw_validated)" = 1
check "env nerves_fw_devpath=/dev/nerves-userdata" \
    test "$(env_get nerves_fw_devpath)" = /dev/nerves-userdata

# What lk2nd does with userdata: validate each MBR entry
# (validate_mbr_partition), skip leaves under 16 MiB (LK2ND_BOOT_MIN_SIZE),
# mount the rest as ext2, look for /extlinux/extlinux.conf.
lk2nd_scan() {
    local found=""
    while read -r name start size ptype status; do
        [ "$ptype" != 0x0 ] || continue
        case $status in 0x80|0x0) ;; *) continue ;; esac
        [ $((start + size)) -le $USERDATA_BLOCKS ] || continue
        [ $((size * 512)) -ge $((16 * 1024 * 1024)) ] || continue
        dd if=userdata.img of=leaf.img bs=512 skip="$start" count="$size" status=none
        if debugfs -R "stat /extlinux/extlinux.conf" leaf.img 2>/dev/null | grep -q '^Inode:'; then
            found="$found $name@$start"
        fi
    done < <(inspect userdata.img | grep '^part')
    rm -f leaf.img
    echo "${found# }"
}
check "lk2nd finds extlinux.conf only on slot A boot" test "$(lk2nd_scan)" = "part0@2064"

dd if=userdata.img of=rootfs.img bs=512 skip=264208 count=786432 status=none
check "rootfs A is a squashfs" sh -c 'unsquashfs -s rootfs.img >/dev/null 2>&1'
rm -f rootfs.img
check "sfdisk reads the nested MBR" sh -c 'sfdisk -d userdata.img | grep -Eq "start= +2064,"'

check "status says a" test "$(ops_info status)" = a
check "revert refused with nothing to revert to" sh -c '! fwup -q -U -a -i ops.fw -t revert -d userdata.img 2>/dev/null'

# --- upgrade to B ----------------------------------------------------------------
fwup -q -U -a -i v2.fw -t upgrade -d userdata.img
check "upgrade wrote slot B into the MBR" \
    test "$(part 0)/$(part 1)" = "133136 131072/1050640 786432"
check "env active=b, b version 0.0.2, b validated" \
    test "$(env_get nerves_fw_active)/$(env_get b.nerves_fw_version)/$(env_get b.nerves_fw_validated)" = "b/0.0.2/1"
check "slot A metadata kept for revert" test "$(env_get a.nerves_fw_version)" = 0.0.1
check "lk2nd now finds slot B boot" test "$(lk2nd_scan)" = "part0@133136"
check "status says b" test "$(ops_info status)" = b

# --- revert to A and back --------------------------------------------------------
fwup_ops revert >/dev/null
check "revert switched MBR and env to A" \
    test "$(part 1)/$(env_get nerves_fw_active)" = "264208 786432/a"
check "lk2nd finds slot A boot after revert" test "$(lk2nd_scan)" = "part0@2064"
fwup_ops revert >/dev/null
check "revert again goes back to B" test "$(part 1)/$(env_get nerves_fw_active)" = "1050640 786432/b"

# --- upgrade from B back to A ----------------------------------------------------
NERVES_SDK_VERSION=0.0.3 fwup -c -f "$HERE/fwup.conf" -o v3.fw
fwup -q -U -a -i v3.fw -t upgrade -d userdata.img
check "second upgrade lands in A" \
    test "$(part 1)/$(env_get nerves_fw_active)/$(env_get a.nerves_fw_version)" = "264208 786432/a/0.0.3"

# --- validate, prevent-revert, grow-app, factory-reset ---------------------------
fwup_ops validate >/dev/null
check "validate sets a.nerves_fw_validated" test "$(env_get a.nerves_fw_validated)" = 1
fwup_ops prevent-revert >/dev/null
check "prevent-revert removes b platform" test -z "$(env_get b.nerves_fw_platform)"
check "revert refused after prevent-revert" sh -c '! fwup -q -U -a -i ops.fw -t revert -d userdata.img 2>/dev/null'
fwup_ops grow-app >/dev/null
check "grow-app expands the app partition to the end of userdata" \
    test "$(part 2)" = "1837072 $((USERDATA_BLOCKS - 1837072))"
check "grow-app keeps slot A" test "$(part 1)" = "264208 786432"
check "lk2nd still accepts every entry after grow-app" test "$(lk2nd_scan)" = "part0@2064"
fwup_ops factory-reset >/dev/null
check "factory-reset erases the start of the app partition" \
    sh -c "dd if=userdata.img bs=512 skip=1837072 count=1 status=none | od -An -tx1 | head -1 | grep -q '^ ff ff'"

echo "$pass checks passed in $WORK"
