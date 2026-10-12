#!/bin/sh
#
# Install Nerves on a stock Samsung Galaxy S III Neo (GT-I9301I, s3ve3g).
#
# Takes a phone running Samsung's Android 4.4 with USB debugging enabled to
# the latest firmware release of a Nerves application built on
# nerves_system_s3ve3g:
#
#   1. checks the host tools, the phone (model, codename, battery) and the
#      release assets (SHA256SUMS, TWRP's published hash and PGP signature);
#   2. puts TWRP on RECOVERY with heimdall and boots it;
#   3. copies the phone's irreplaceable partitions (efs, modem NV, persist,
#      param, ...) and the stock boot image to the host, checking every copy
#      against a hash computed on the phone;
#   4. writes lk2nd to BOOT and the Nerves image to USERDATA in one heimdall
#      session, and waits for the phone's USB network.
#
# Without --yes nothing is written: the script checks what it can and prints
# the exact commands it would run. With --yes it prints the same plan, then
# asks for the phone's model to be typed before the first write.
#
# Only RECOVERY, BOOT and USERDATA are ever written. No PIT, no
# repartitioning, no Odin tar.

set -eu

REPO=${S3VE3G_REPO:-mlainez/hello_s3ve3g}
TAG=""
ASSETS_DIR=""
WORK=${S3VE3G_WORK:-./s3ve3g-install}
BACKUP_ROOT=.
YES=0

GITHUB_API=${S3VE3G_GITHUB_API:-https://api.github.com}
TWRP_BASE=${S3VE3G_TWRP_BASE:-https://dl.twrp.me}
TWRP_NAME=twrp-3.3.1-1-s3ve3g.img
# Pinned: the hash dl.twrp.me publishes for this file, and TeamWin's key.
TWRP_SHA256=b7d61b1d95c07b638049bd1855ab8963bfe8a77a961f39f262ee74a02ce3ac8f
TWRP_KEY_FPR=95707D42307C9D41D09BF7091D8597D7891A43DF
LK2ND_NAME=lk2nd-s3ve3g.img

MODEL=GT-I9301I
CODENAME=s3ve3g
MIN_BATTERY=50

# Partition geometry of the GT-I9301I (512-byte sectors), as Linux and the
# stock PIT both report it. A phone that differs is not one this was tested on.
BOOT_START=209536
BOOT_SECTORS=20480
RECOVERY_START=230016
RECOVERY_SECTORS=20480
USERDATA_START=6240896
# First sectors of the nested Nerves partitions in the image (boot A, app).
IMG_P1_START=2064
IMG_P3_START=1837072

# Copied before anything is written beyond RECOVERY. `boot` is the stock
# kernel; `recovery` already holds TWRP by then (see the README).
BACKUP_PARTS="efs modemst1 modemst2 fsg fsc persist persdata param ssd boot"

USB_SYSFS=${S3VE3G_USB_SYSFS:-/sys/bus/usb/devices}
POLL=${S3VE3G_POLL:-2}

usage() {
  cat <<EOF
Usage: $0 [--yes] [--repo OWNER/NAME] [--tag TAG] [--assets DIR] [--work DIR]
          [--backup-root DIR]

  --yes            run the plan (default: dry run, nothing is written)
  --repo REPO      GitHub repository with the firmware releases
                   (default: $REPO)
  --tag TAG        use this release instead of the latest one
  --assets DIR     use release assets already in DIR (SHA256SUMS, $LK2ND_NAME,
                   the image) instead of downloading them; still verified
  --work DIR       download directory (default: $WORK)
  --backup-root D  where backups-<serial>-<date>/ is created (default: .)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1; shift ;;
    --repo) REPO=$2; shift 2 ;;
    --tag) TAG=$2; shift 2 ;;
    --assets) ASSETS_DIR=$2; shift 2 ;;
    --work) WORK=$2; shift 2 ;;
    --backup-root) BACKUP_ROOT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

# Recovery hint for the current stage, printed by die().
HINT="Nothing has been written to the phone."
die() {
  printf '\nERROR: %s\n' "$*" >&2
  printf '\n%s\n' "$HINT" >&2
  exit 1
}

run() {
  printf '+ %s\n' "$*"
  "$@"
}

need() {
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "'$t' is not installed (see the README, Dependencies)"
  done
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# adb prints CRLF on Android 4.4.
ash() { adb -s "$SERIAL" shell "$@" | tr -d '\r'; }

usb_count() {
  n=0
  for d in "$USB_SYSFS"/*; do
    [ -r "$d/idVendor" ] || continue
    if [ "$(cat "$d/idVendor")" = "$1" ] && [ "$(cat "$d/idProduct")" = "$2" ]; then
      n=$((n + 1))
    fi
  done
  echo "$n"
}

# wait_for <seconds> <description> <command...>: poll until the command succeeds.
wait_for() {
  limit=$1; what=$2; shift 2
  waited=0
  step=$POLL
  [ "$step" -ge 1 ] || step=1
  info "waiting for $what (up to ${limit}s)"
  until "$@" >/dev/null 2>&1; do
    [ "$waited" -ge "$limit" ] && die "timed out waiting for $what"
    sleep "$POLL"
    waited=$((waited + step))
  done
}

adb_state_is() { [ "$(adb -s "$SERIAL" get-state 2>/dev/null | tr -d '\r')" = "$1" ]; }
one_download_device() { [ "$(usb_count 04e8 685d)" = 1 ]; }
nerves_gadget_up() { [ "$(usb_count 0525 a4a2)" -ge 1 ]; }

# --- 1. Host tools -----------------------------------------------------------

say "Checking host tools"
need adb heimdall curl sha256sum gpg awk sed od tr mktemp
info "adb: $(adb version 2>/dev/null | head -n1)"
info "heimdall: $(heimdall version 2>/dev/null | head -n1)"

# --- 2. The phone ------------------------------------------------------------

say "Checking the phone"
[ "$(usb_count 04e8 685d)" = 0 ] ||
  die "a phone in download mode is already connected; restart it into Android first (hold Power + Volume Down ~10 s)"

devices=$(adb devices | tr -d '\r' | awk 'NR > 1 && NF >= 2 {print $1, $2}')
ndev=$(printf '%s\n' "$devices" | awk 'NF == 2' | wc -l | tr -d ' ')
[ "$ndev" = 1 ] || {
  printf '%s\n' "$devices" >&2
  die "expected exactly one phone on adb, found $ndev; unplug the others, and enable USB debugging"
}
SERIAL=${devices%% *}
STATE=${devices#* }
case "$STATE" in
  device|recovery) ;;
  unauthorized) die "the phone has not authorized this computer: unlock it and accept the 'Allow USB debugging' prompt" ;;
  *) die "phone $SERIAL is in state '$STATE'" ;;
esac

if [ "$STATE" = recovery ]; then
  [ -n "$(ash 'test -d /twres && echo twrp')" ] ||
    die "phone $SERIAL is in a recovery that is not TWRP; reboot it into Android"
  IN_TWRP=1
else
  IN_TWRP=0
fi

model=$(ash getprop ro.product.model)
codename=$(ash getprop ro.product.device)
[ "$model" = "$MODEL" ] || die "ro.product.model is '$model', expected $MODEL: this installer is only for the $MODEL"
[ "$codename" = "$CODENAME" ] || die "ro.product.device is '$codename', expected $CODENAME"

if [ "$IN_TWRP" = 1 ]; then
  battery=$(ash cat /sys/class/power_supply/battery/capacity)
else
  battery=$(ash dumpsys battery | sed -n 's/^ *level: *//p' | head -n1)
fi
case "$battery" in ''|*[!0-9]*) die "cannot read the battery level (got '$battery')" ;; esac
[ "$battery" -ge "$MIN_BATTERY" ] || die "battery at $battery %; charge it above $MIN_BATTERY % first"

warranty=$(ash getprop ro.boot.warranty_bit)
info "serial $SERIAL, $model ($codename), $([ "$IN_TWRP" = 1 ] && echo "TWRP" || echo "Android $(ash getprop ro.build.version.release)"), battery $battery %"
info "bootloader $(ash getprop ro.bootloader), warranty bit ${warranty:-unknown}"

# --- 3. Release assets -------------------------------------------------------

mkdir -p "$WORK"
if [ -n "$ASSETS_DIR" ]; then
  say "Using release assets from $ASSETS_DIR"
  REL=$ASSETS_DIR
  RELEASE_NAME="local assets ($ASSETS_DIR)"
else
  if [ -n "$TAG" ]; then url="$GITHUB_API/repos/$REPO/releases/tags/$TAG"
  else url="$GITHUB_API/repos/$REPO/releases/latest"; fi
  say "Fetching the release list: $url"
  json="$WORK/release.json"
  curl -fsSL -H "Accept: application/vnd.github+json" -o "$json" "$url" ||
    die "cannot read $url (does $REPO have a published release?)"
  # One JSON member per line; URLs and tags contain none of these characters.
  # shellcheck disable=SC2020
  tag=$(tr ',{}' '\n\n\n' < "$json" | sed -n 's/^ *"tag_name": *"\([^"]*\)" *$/\1/p' | head -n1)
  [ -n "$tag" ] || die "no tag_name in $url"
  RELEASE_NAME="$REPO $tag"
  REL="$WORK/$tag"
  mkdir -p "$REL"
  # shellcheck disable=SC2020
  tr ',{}[]' '\n\n\n\n\n' < "$json" |
    sed -n 's/^ *"browser_download_url": *"\([^"]*\)" *$/\1/p' > "$WORK/assets.txt"
  while read -r asset_url; do
    name=${asset_url##*/}
    case "$name" in
      SHA256SUMS|"$LK2ND_NAME"|*.img|*.img.gz|*.img.xz) ;;
      *) continue ;;
    esac
    if [ -f "$REL/$name" ]; then
      info "$name (already downloaded)"
    else
      info "downloading $name"
      curl -fL --progress-bar --retry 3 -o "$REL/$name.part" "$asset_url" || die "download of $asset_url failed"
      mv "$REL/$name.part" "$REL/$name"
    fi
  done < "$WORK/assets.txt"
fi

say "Verifying $RELEASE_NAME"
[ -f "$REL/SHA256SUMS" ] || die "the release has no SHA256SUMS"
[ -f "$REL/$LK2ND_NAME" ] || die "the release has no $LK2ND_NAME"

images=$(cd "$REL" && for f in *.img *.img.gz *.img.xz; do
  [ -f "$f" ] && [ "$f" != "$LK2ND_NAME" ] && echo "$f"; done; true)
nimg=$(printf '%s' "$images" | grep -c . || true)
[ "$nimg" = 1 ] || die "expected exactly one Nerves image (.img, .img.gz or .img.xz) in the release, found $nimg: $images"
IMG_ASSET=$images

# check_sum <name> <path>: <name> must be listed in SHA256SUMS and <path> match it.
check_sum() {
  want=$(awk -v f="$1" '{n = $2; sub(/^\*/, "", n)} n == f {print $1}' "$REL/SHA256SUMS" | head -n1)
  [ -n "$want" ] || die "$1 is not listed in SHA256SUMS"
  got=$(sha256_of "$2")
  [ "$got" = "$want" ] || die "checksum mismatch for $1: got $got, SHA256SUMS says $want"
  info "sha256 OK  $1"
}

check_sum "$LK2ND_NAME" "$REL/$LK2ND_NAME"
check_sum "$IMG_ASSET" "$REL/$IMG_ASSET"
IMG_ASSET_SHA=$got

case "$IMG_ASSET" in
  *.img.xz) need xz; IMG_NAME=${IMG_ASSET%.xz}; decomp="xz -dc" ;;
  *.img.gz) need gzip; IMG_NAME=${IMG_ASSET%.gz}; decomp="gzip -dc" ;;
  *) IMG_NAME=$IMG_ASSET; decomp="" ;;
esac
IMG="$REL/$IMG_NAME"
if [ -n "$decomp" ]; then
  # Outside the asset directory, which must hold exactly one image, and
  # keyed by the compressed file so a stale image is never reused.
  mkdir -p "$WORK/raw-$IMG_ASSET_SHA"
  IMG="$WORK/raw-$IMG_ASSET_SHA/$IMG_NAME"
  if [ ! -f "$IMG" ]; then
    # heimdall writes bytes as they are, so the image must be raw.
    info "decompressing $IMG_ASSET"
    $decomp "$REL/$IMG_ASSET" > "$IMG.part" || die "cannot decompress $IMG_ASSET"
    mv "$IMG.part" "$IMG"
  fi
  if awk -v f="$IMG_NAME" '{n = $2; sub(/^\*/, "", n)} n == f {found = 1} END {exit !found}' "$REL/SHA256SUMS"; then
    check_sum "$IMG_NAME" "$IMG"
  fi
fi

[ "$(head -c 8 "$REL/$LK2ND_NAME")" = "ANDROID!" ] || die "$LK2ND_NAME is not an Android boot image"
lk_size=$(wc -c < "$REL/$LK2ND_NAME" | tr -d ' ')
[ "$lk_size" -le $((BOOT_SECTORS * 512)) ] || die "$LK2ND_NAME ($lk_size bytes) does not fit in BOOT"

IMG_SIZE=$(wc -c < "$IMG" | tr -d ' ')
[ $((IMG_SIZE % 512)) = 0 ] || die "$IMG_NAME is not a whole number of sectors"
[ "$(od -An -tx1 -j510 -N2 "$IMG" | tr -d ' \n')" = 55aa ] || die "$IMG_NAME has no partition table"
p1=$(od -An -tu4 -j454 -N4 "$IMG" | tr -d ' ')
p3=$(od -An -tu4 -j486 -N4 "$IMG" | tr -d ' ')
if [ "$p1" != "$IMG_P1_START" ] || [ "$p3" != "$IMG_P3_START" ]; then
  die "$IMG_NAME does not have the nerves_system_s3ve3g layout (partition 1 at $p1, partition 3 at $p3)"
fi
info "image OK  $IMG_NAME ($IMG_SIZE bytes, nested MBR, boot A at $p1, app at $p3)"

say "Fetching TWRP 3.3.1-1 for s3ve3g from dl.twrp.me"
TW="$WORK/twrp"
mkdir -p "$TW"
# dl.twrp.me serves an HTML page unless the request comes from its own page.
for f in "$TWRP_NAME" "$TWRP_NAME.sha256" "$TWRP_NAME.asc"; do
  [ -f "$TW/$f" ] && continue
  curl -fsSL --retry 3 -e "$TWRP_BASE/s3ve3g/$TWRP_NAME.html" -o "$TW/$f.part" "$TWRP_BASE/s3ve3g/$f" ||
    die "download of $TWRP_BASE/s3ve3g/$f failed"
  mv "$TW/$f.part" "$TW/$f"
done
[ -f "$TW/public.asc" ] || {
  curl -fsSL --retry 3 -o "$TW/public.asc.part" "$TWRP_BASE/public.asc" || die "download of TeamWin's key failed"
  mv "$TW/public.asc.part" "$TW/public.asc"
}
TWRP="$TW/$TWRP_NAME"
got=$(sha256_of "$TWRP")
[ "$got" = "$TWRP_SHA256" ] || { rm -f "$TWRP"; die "TWRP checksum $got is not the pinned $TWRP_SHA256 (file removed)"; }
[ "$(awk '{print $1}' "$TW/$TWRP_NAME.sha256")" = "$TWRP_SHA256" ] || die "dl.twrp.me publishes a different sha256 for $TWRP_NAME"
info "sha256 OK  $TWRP_NAME (pinned and published)"
GNUPGHOME=$(mktemp -d)
export GNUPGHOME
gpg --batch --quiet --import "$TW/public.asc" 2>/dev/null || { rm -rf "$GNUPGHOME"; die "cannot import TeamWin's key"; }
sig=$(gpg --batch --status-fd 1 --verify "$TW/$TWRP_NAME.asc" "$TWRP" 2>/dev/null | awk '$2 == "VALIDSIG" {print $NF}')
rm -rf "$GNUPGHOME"
unset GNUPGHOME
[ "$sig" = "$TWRP_KEY_FPR" ] || die "TWRP's PGP signature does not verify against TeamWin's key $TWRP_KEY_FPR"
info "PGP OK     signed by TeamWin $TWRP_KEY_FPR"
[ "$(head -c 8 "$TWRP")" = "ANDROID!" ] || die "$TWRP_NAME is not an Android boot image"
[ "$(wc -c < "$TWRP" | tr -d ' ')" -le $((RECOVERY_SECTORS * 512)) ] || die "$TWRP_NAME does not fit in RECOVERY"

# --- 4. The plan -------------------------------------------------------------

BACKUP="$BACKUP_ROOT/backups-$SERIAL-$(date +%Y%m%d-%H%M%S)"
BYNAME=/dev/block/platform/msm_sdcc.1/by-name

say "Plan"
cat <<EOF

  Phone   $model ($codename), serial $SERIAL, battery $battery %
  Release $RELEASE_NAME
          $IMG  ($IMG_SIZE bytes)
          $REL/$LK2ND_NAME
  TWRP    $TWRP
  Backups $BACKUP/

  This replaces Android with Nerves. Read before going on:

  * KNOX: the first unofficial image on RECOVERY or BOOT (TWRP, lk2nd) sets
    the phone's warranty bit, an e-fuse. It cannot be undone, and reflashing
    Samsung firmware does not reset it. Knox features and the Samsung
    warranty are gone for good.
  * USERDATA is overwritten: every app, photo and account on the phone is
    erased. Copy what you want to keep off the phone first.
  * There is no bootloader unlock on this phone and none is needed: Samsung's
    bootloader warns about unsigned BOOT/RECOVERY images and starts them.
  * Only RECOVERY, BOOT and USERDATA are written. The bootloaders, the PIT and
    the phone's calibration partitions are never touched.

EOF
if [ "$IN_TWRP" = 0 ]; then
  cat <<EOF
  A. TWRP on RECOVERY (Android -> download mode -> TWRP)
     adb -s $SERIAL reboot download
     (wait for exactly one 04e8:685d)
     heimdall flash --RECOVERY $TWRP
     (heimdall reboots the phone into Android; this ROM does not restore the
     stock recovery)
     (wait for adb in Android)
     adb -s $SERIAL reboot recovery
     (wait for adb in recovery, check /twres exists)

EOF
else
  printf '  A. TWRP is already running: skipped.\n\n'
fi
cat <<EOF
  B. Backups, read-only, from TWRP (root)
     for each of: $BACKUP_PARTS
       adb -s $SERIAL shell sha256sum $BYNAME/<part>
       adb -s $SERIAL exec-out cat $BYNAME/<part> > $BACKUP/<part>.img
       (the two hashes must match; recorded in $BACKUP/SHA256SUMS)
     check the partition table: boot at $BOOT_START, recovery at $RECOVERY_START,
     userdata at $USERDATA_START and at least $IMG_SIZE bytes long
     adb -s $SERIAL reboot download
     (wait for exactly one 04e8:685d)

  C. Install
     heimdall flash --BOOT $REL/$LK2ND_NAME --USERDATA $IMG
     (heimdall reboots the phone: Samsung logo -> lk2nd -> Nerves)
     (wait for the Nerves USB network, 0525:a4a2)

EOF

if [ "$YES" != 1 ]; then
  say "Dry run: nothing was written. Run again with --yes to install."
  exit 0
fi

printf 'Type the phone model (%s) to erase it and install Nerves: ' "$MODEL"
answer=""
{ read -r answer < /dev/tty; } 2>/dev/null || read -r answer || true
[ "$answer" = "$MODEL" ] || die "cancelled (typed '$answer')"

mkdir "$BACKUP" || die "cannot create $BACKUP"
ash getprop > "$BACKUP/getprop.txt" || true

# --- A. TWRP ---------------------------------------------------------------

if [ "$IN_TWRP" = 0 ]; then
  say "A. TWRP on RECOVERY"
  HINT="Nothing has been written. If the phone stays in download mode, hold Power + Volume Down for ~10 s to restart into Android."
  run adb -s "$SERIAL" reboot download
  wait_for 90 "the phone in download mode" one_download_device
  HINT="RECOVERY may hold a partial TWRP; Android (BOOT) is untouched and still starts. Re-run this script, or put the stock recovery back from Samsung's firmware: heimdall flash --RECOVERY recovery.img"
  run heimdall flash --RECOVERY "$TWRP" || die "heimdall could not write RECOVERY"
  HINT="TWRP is on RECOVERY and Android is untouched. Start TWRP by hand: power off, hold Volume Up + Home + Power, release Power at the logo. Then re-run this script: it continues from TWRP."
  wait_for 180 "Android to come back on adb" adb_state_is device
  run adb -s "$SERIAL" reboot recovery
  wait_for 120 "TWRP on adb" adb_state_is recovery
  [ -n "$(ash 'test -d /twres && echo twrp')" ] ||
    die "the recovery that started is not TWRP (Android may have restored the stock recovery)"
fi

# --- B. Backups -------------------------------------------------------------

say "B. Backups to $BACKUP"
HINT="Only RECOVERY (TWRP) has been written; Android still starts. Partial backups are in $BACKUP. Re-run this script from TWRP once the problem is fixed."
[ "$(ash id | grep -o 'uid=0')" = uid=0 ] || die "TWRP's adb shell is not root"
[ -n "$(ash "test -d $BYNAME && echo ok")" ] || die "$BYNAME does not exist in TWRP"

for part in $BACKUP_PARTS; do
  dev="$BYNAME/$part"
  remote=$(ash sha256sum "$dev" | awk '{print $1}')
  [ -n "$remote" ] || die "cannot hash $part on the phone"
  adb -s "$SERIAL" exec-out cat "$dev" > "$BACKUP/$part.img.part"
  local_sum=$(sha256_of "$BACKUP/$part.img.part")
  [ "$local_sum" = "$remote" ] || die "backup of $part does not match the phone (phone $remote, copy $local_sum)"
  mv "$BACKUP/$part.img.part" "$BACKUP/$part.img"
  echo "$local_sum  $part.img" >> "$BACKUP/SHA256SUMS"
  info "ok  $part ($(wc -c < "$BACKUP/$part.img" | tr -d ' ') bytes)"
done
(cd "$BACKUP" && sha256sum -c --quiet SHA256SUMS) || die "SHA256SUMS in $BACKUP does not verify"

# geometry <name>: "<start> <sectors>" of a partition, from sysfs in TWRP.
geometry() {
  ash "b=\$(basename \$(readlink -f $BYNAME/$1)); echo \$(cat /sys/class/block/\$b/start) \$(cat /sys/class/block/\$b/size)"
}
# shellcheck disable=SC2046 # word splitting into start and size is intended
set -- $(geometry boot)
if [ "${1:-}" != "$BOOT_START" ] || [ "${2:-}" != "$BOOT_SECTORS" ]; then
  die "BOOT is at '$*', expected $BOOT_START $BOOT_SECTORS"
fi
# shellcheck disable=SC2046
set -- $(geometry recovery)
if [ "${1:-}" != "$RECOVERY_START" ] || [ "${2:-}" != "$RECOVERY_SECTORS" ]; then
  die "RECOVERY is at '$*', expected $RECOVERY_START $RECOVERY_SECTORS"
fi
# shellcheck disable=SC2046
set -- $(geometry userdata)
[ "${1:-}" = "$USERDATA_START" ] || die "USERDATA starts at '${1:-}', expected $USERDATA_START"
case "${2:-}" in ''|*[!0-9]*) die "cannot read the size of USERDATA" ;; esac
[ "$IMG_SIZE" -le $(( $2 * 512 )) ] || die "$IMG_NAME ($IMG_SIZE bytes) is larger than USERDATA ($(( $2 * 512 )) bytes)"
info "partition table OK (userdata $(( $2 * 512 )) bytes)"
geometry userdata > "$BACKUP/userdata-geometry.txt"

HINT="Only RECOVERY (TWRP) has been written; backups are complete in $BACKUP. If the phone stays in download mode, hold Power + Volume Down for ~10 s, then re-run this script."
run adb -s "$SERIAL" reboot download
wait_for 90 "the phone in download mode" one_download_device

# --- C. Install --------------------------------------------------------------

say "C. Installing lk2nd and Nerves"
HINT="BOOT and USERDATA may be partly written. Download mode still works: power off (hold Power + Volume Down ~10 s, or pull the battery), then hold Volume Down + Home + Power and press Volume Up at the warning. Then either write them again:
  heimdall flash --BOOT $REL/$LK2ND_NAME --USERDATA $IMG
or put Android's kernel back: heimdall flash --BOOT $BACKUP/boot.img (then wipe data from TWRP)."
run heimdall flash --BOOT "$REL/$LK2ND_NAME" --USERDATA "$IMG" || die "heimdall could not write BOOT and USERDATA"

HINT="Everything is written. If no USB network shows up: unplug and replug the cable; the phone's screen shows the boot log. Download mode always works (Volume Down + Home + Power, then Volume Up) for a new attempt."
wait_for 300 "the Nerves USB network (0525:a4a2)" nerves_gadget_up

say "Done"
cat <<EOF

  The phone runs $RELEASE_NAME.

  Connect:   ssh nerves.local        (USB network; the first boot also grows
                                      the data partition, give it a minute)
  Backups:   $BACKUP/
             keep a copy somewhere else: efs, modemst1/2, fsg, persist and
             param are unique to this phone.
  Updates:   mix upload nerves.local, from the application's directory.
  Stock:     in download mode, heimdall flash --BOOT $BACKUP/boot.img
             --RECOVERY <recovery.img from Samsung's firmware>, then a
             factory reset (see the README, Back to Android).

  If ssh does not answer but 'telnet 10.0.42.1' does, the initramfs could not
  start Nerves and opened its recovery shell instead.
EOF
