#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

STOCK="in/stock.img"
OUT=""
OUT_TMP=""
OUT_DIR="out"
OUT_NAME="main-rgds-plus"
ZIP_OUT=""
ZIP_TMP=""
SRC_DIR="src"

ROOTFS_MB=384
PORTS_MB=32
VENDOR_MB=32
OEM_MB=32
USERDATA_MB=128
ROMS_MB=64

SECTOR_SIZE=512
WORK="$(mktemp -d /tmp/rgds-custom.XXXXXX)"
SRC_LOOP=""
DST_LOOP=""
MOUNTS=()
LOOP_NODES=()

cleanup() {
	set +e
	unmount_all
	remove_loop_nodes
	[ -n "$SRC_LOOP" ] && losetup -d "$SRC_LOOP" 2>/dev/null
	[ -n "$DST_LOOP" ] && losetup -d "$DST_LOOP" 2>/dev/null
	[ -n "$OUT_TMP" ] && rm -f "$OUT_TMP"
	[ -n "$ZIP_TMP" ] && rm -f "$ZIP_TMP"
	rm -rf "$WORK"
}
trap cleanup EXIT

unmount_all() {
	for ((i=${#MOUNTS[@]}-1; i>=0; i--)); do
		umount "${MOUNTS[$i]}" 2>/dev/null
	done
	MOUNTS=()
}

remove_loop_nodes() {
	for node in "${LOOP_NODES[@]}"; do
		rm -f "$node"
	done
	LOOP_NODES=()
}

sectors_from_mb() {
	echo $(($1 * 1024 * 1024 / SECTOR_SIZE))
}

part_guid() {
	sgdisk -i "$1" "$STOCK" 2>&1 | awk -F': ' '/Partition unique GUID/ { print $2 }'
}

part_start() {
	sgdisk -i "$1" "$STOCK" 2>&1 | awk '/^First sector:/ { print $3 }'
}

part_size() {
	sgdisk -i "$1" "$STOCK" 2>&1 | awk '/^Partition size:/ { print $3 }'
}

part_uuid() {
	blkid -s UUID -o value "$1"
}

fat_uuid_arg() {
	echo "${1//-/}"
}

make_loop_nodes() {
	local loop="$1"
	local base
	base="$(basename "$loop")"

	while read -r name majmin; do
		[ "${name#${base}p}" != "$name" ] || continue
		rm -f "/dev/$name"
		mknod -m 660 "/dev/$name" b "${majmin%:*}" "${majmin#*:}"
		LOOP_NODES+=("/dev/$name")
	done < <(lsblk -r -n -o NAME,MAJ:MIN "$loop")
}

mount_part() {
	local dev="$1"
	local dir="$2"
	local opts="$3"

	mkdir -p "$dir"
	mount -o "$opts" "$dev" "$dir"
	MOUNTS+=("$dir")
}

require_file() {
	[ -e "$1" ] || {
		echo "missing $1" >&2
		exit 1
	}
}

require_readable() {
	dd if="$1" of=/dev/null bs=1 count=1 status=none 2>/dev/null || {
		echo "cannot read $1" >&2
		exit 1
	}
}

next_zip_out() {
	local today count candidate
	today="$(date +%Y%m%d)"
	count="$(find "$OUT_DIR" -maxdepth 1 -type f -name "$OUT_NAME-$today-*.img.zip" | wc -l)"
	count="${count##* }"
	candidate="$OUT_DIR/$OUT_NAME-$today-$count.img.zip"

	while [ -e "$candidate" ]; do
		count=$((count + 1))
		candidate="$OUT_DIR/$OUT_NAME-$today-$count.img.zip"
	done

	printf '%s\n' "$candidate"
}

require_file "$STOCK"
require_file "$SRC_DIR/S01expand"
require_file "$SRC_DIR/S02main"
require_file "$SRC_DIR/S03wifi"
require_file "$SRC_DIR/main.sh"
mkdir -p "$OUT_DIR"
ZIP_OUT="$(next_zip_out)"
OUT="$(basename "$ZIP_OUT" .zip)"
OUT_TMP="/tmp/$OUT"
ZIP_TMP="/tmp/$OUT.zip"

echo "preparing $OUT.img.zip"
rm -f "$OUT" "$OUT_TMP" "$ZIP_TMP"

p1_size="$(part_size 1)"
p2_size="$(part_size 2)"
p3_size="$(part_size 3)"
p4_size="$(part_size 4)"
p5_size="$(part_size 5)"
p6_size="$(sectors_from_mb "$ROOTFS_MB")"
p7_size="$(sectors_from_mb "$PORTS_MB")"
p8_size="$(sectors_from_mb "$VENDOR_MB")"
p9_size="$(sectors_from_mb "$OEM_MB")"
p10_size="$(sectors_from_mb "$USERDATA_MB")"
p11_size="$(sectors_from_mb "$ROMS_MB")"

first_part_start="$(part_start 1)"
start="$first_part_start"
sgdisk_args=(--clear)
disk_guid="$(sgdisk -p "$STOCK" 2>/dev/null | awk -F': ' '/Disk identifier/ { print $2 }')"
[ -n "$disk_guid" ] && sgdisk_args+=(--disk-guid="$disk_guid")

add_part() {
	local number="$1"
	local size="$2"
	local name="$3"
	local guid="$4"
	local end=$((start + size - 1))

	sgdisk_args+=(
		--new="${number}:${start}:${end}"
		--typecode="${number}:0700"
		--change-name="${number}:${name}"
	)
	[ -n "$guid" ] && sgdisk_args+=(--partition-guid="${number}:${guid}")
	start=$((end + 1))
}

add_part 1 "$p1_size" uboot "$(part_guid 1)"
add_part 2 "$p2_size" misc "$(part_guid 2)"
add_part 3 "$p3_size" boot "$(part_guid 3)"
add_part 4 "$p4_size" recovery "$(part_guid 4)"
add_part 5 "$p5_size" backup "$(part_guid 5)"
add_part 6 "$p6_size" rootfs "$(part_guid 6)"
add_part 7 "$p7_size" ports "$(part_guid 7)"
add_part 8 "$p8_size" vendor "$(part_guid 8)"
add_part 9 "$p9_size" oem "$(part_guid 9)"
add_part 10 "$p10_size" userdata "$(part_guid 10)"
add_part 11 "$p11_size" ROMS "$(part_guid 11)"

truncate -s $(((start + 2048 + 34) * SECTOR_SIZE)) "$OUT_TMP"
sgdisk "${sgdisk_args[@]}" "$OUT_TMP" >/dev/null
sgdisk -e "$OUT_TMP" >/dev/null

echo "copying pre-partition bootloader area"
dd if="$STOCK" of="$OUT_TMP" bs="$SECTOR_SIZE" skip=64 seek=64 count=$((first_part_start - 64)) conv=notrunc status=none

SRC_LOOP="$(losetup -Pf --show -r "$STOCK")"
DST_LOOP="$(losetup -Pf --show "$OUT_TMP")"
make_loop_nodes "$SRC_LOOP"
make_loop_nodes "$DST_LOOP"

echo "copying boot partitions"
for n in 1 2 3 4 5; do
	dd if="${SRC_LOOP}p${n}" of="${DST_LOOP}p${n}" bs=4M status=none conv=fsync
done

echo "creating rootfs"
mkfs.ext4 -q -F -L rootfs -U "$(part_uuid "${SRC_LOOP}p6")" "${DST_LOOP}p6"
mount_part "${SRC_LOOP}p6" "$WORK/src-rootfs" ro
mount_part "${DST_LOOP}p6" "$WORK/dst-rootfs" rw
rsync -aHAX --numeric-ids \
	--exclude=/mnt/mod/*** \
	--exclude=/usr/lib/chromium/*** \
	--exclude=/usr/bin/chromium \
	--exclude=/usr/lib/python3.11/*** \
	--exclude=/usr/bin/python \
	--exclude=/usr/bin/python3 \
	--exclude=/usr/bin/python3.11 \
	--exclude=/usr/lib/gstreamer-1.0/*** \
	--exclude=/usr/lib/pulseaudio/*** \
	--exclude=/usr/share/glmark2/*** \
	--exclude=/rockchip-test/*** \
	--exclude=/info/*** \
	--exclude=/usr/share/X11/*** \
	--exclude=/usr/bin/weston* \
	--exclude=/usr/lib/weston/*** \
	--exclude=/usr/lib/libweston* \
	--exclude=/usr/share/fonts/*** \
	--exclude=/usr/share/font-awesome/*** \
	--exclude=/usr/share/weston/*** \
	--exclude=/usr/share/pulseaudio/*** \
	--exclude=/etc/fonts/*** \
	--exclude=/etc/pulse/*** \
	--exclude=/etc/xdg/weston/*** \
	--exclude=/opt/unixbench/*** \
	--exclude=/usr/aarch64-buildroot-linux-gnu/*** \
	--exclude=/usr/bin/as \
	--exclude=/usr/bin/ld \
	--exclude=/usr/bin/ld.bfd \
	--exclude=/usr/bin/make \
	--exclude=/usr/bin/objcopy \
	--exclude=/usr/bin/objdump \
	--exclude=/usr/bin/readelf \
	--exclude=/usr/bin/strip \
	--exclude=/usr/bin/ffmpeg \
	--exclude=/usr/bin/ffprobe \
	--exclude=/usr/bin/flac \
	--exclude=/usr/bin/glmark2* \
	--exclude=/usr/bin/kmsgrab \
	--exclude=/usr/bin/mpv \
	--exclude=/usr/bin/par_ops \
	--exclude=/usr/bin/stress-ng \
	--exclude=/usr/bin/stressapptest \
	--exclude=/usr/bin/strace \
	--exclude=/usr/bin/x264 \
	--exclude=/usr/lib/alsa-lib/*pulse* \
	--exclude=/usr/lib/libavcodec.so* \
	--exclude=/usr/lib/libavfilter.so* \
	--exclude=/usr/lib/libavformat.so* \
	--exclude=/usr/lib/libavutil.so* \
	--exclude=/usr/lib/libbfd* \
	--exclude=/usr/lib/libboost_* \
	--exclude=/usr/lib/libfdk-aac.so* \
	--exclude=/usr/lib/libgst* \
	--exclude=/usr/lib/libmpv.so* \
	--exclude=/usr/lib/libopcodes* \
	--exclude=/usr/lib/libpoppler* \
	--exclude=/usr/lib/libpulse* \
	--exclude=/usr/lib/libpython3.11.so* \
	--exclude=/usr/lib/libswscale.so* \
	--exclude=/usr/lib/libvpx.so* \
	--exclude=/usr/lib/libx264.so* \
	--exclude=/usr/lib/libx265.so* \
	"$WORK/src-rootfs"/ "$WORK/dst-rootfs"/

echo "installing custom init"
for script in \
	S01log-guardian.sh \
	S01seedrng \
	S01syslogd \
	S02klogd \
	S02sysctl \
	S05async-commit.sh \
	S05avahi-setup.sh \
	S10udev \
	S13irqbalance \
	S40bluetoothd \
	S49chronyd \
	S49weston \
	S50avahi-daemon \
	S50crond \
	S50launch \
	S80dnsmasq \
	S90devnet \
	S99-auto-reboot \
	S99btagent \
	S99fstrim \
	S50pulseaudio \
	S60launch
do
	rm -f "$WORK/dst-rootfs/etc/init.d/$script"
done

install -m 755 "$SRC_DIR/S01expand" "$WORK/dst-rootfs/etc/init.d/S01expand"
install -m 755 "$SRC_DIR/S02main" "$WORK/dst-rootfs/etc/init.d/S02main"
install -m 755 "$SRC_DIR/S03wifi" "$WORK/dst-rootfs/etc/init.d/S03wifi"
install -d -m 755 "$WORK/dst-rootfs/etc/custom"
install -m 755 "$SRC_DIR/main.sh" "$WORK/dst-rootfs/etc/custom/main.sh"

if [ -f "$WORK/dst-rootfs/etc/profile.d/resolv.sh" ]; then
	sed -i '/KEYWORD="nameserver"/a [ -e "$ETC_CONFIG" ] || : > "$ETC_CONFIG"' "$WORK/dst-rootfs/etc/profile.d/resolv.sh"
fi

echo "creating small filesystems"
mkfs.ext4 -q -F -m 0 -L ports -U "$(part_uuid "${SRC_LOOP}p7")" "${DST_LOOP}p7"
mkfs.ext4 -q -F -m 0 -L vendor -U "$(part_uuid "${SRC_LOOP}p8")" "${DST_LOOP}p8"
mkfs.ext4 -q -F -m 0 -L oem -U "$(part_uuid "${SRC_LOOP}p9")" "${DST_LOOP}p9"
mkfs.ext4 -q -F -m 0 -L userdata -U "$(part_uuid "${SRC_LOOP}p10")" "${DST_LOOP}p10"

echo "creating seed ROMS"
roms_uuid="$(blkid -s UUID -o value "${SRC_LOOP}p11" 2>/dev/null || true)"
if [ -n "$roms_uuid" ]; then
	mkfs.vfat -F 32 -n ROMS -i "$(fat_uuid_arg "$roms_uuid")" "${DST_LOOP}p11" >/dev/null
else
	mkfs.vfat -F 32 -n ROMS "${DST_LOOP}p11" >/dev/null
fi
mount_part "${DST_LOOP}p11" "$WORK/dst-roms" rw
sync
[ -f "$OUT_TMP" ] || {
	echo "missing $OUT_TMP before final detach" >&2
	exit 1
}

unmount_all
remove_loop_nodes
losetup -d "$SRC_LOOP"
SRC_LOOP=""
losetup -d "$DST_LOOP"
DST_LOOP=""

[ -f "$OUT_TMP" ] || {
	echo "missing $OUT_TMP after final detach" >&2
	exit 1
}
sgdisk -v "$OUT_TMP"
echo "zipping image"
rm -f "$ZIP_TMP"
(
	cd /tmp
	zip -q "$ZIP_TMP" "$OUT"
)
echo "copying image"
cp "$ZIP_TMP" "$ZIP_OUT"
echo "created $ZIP_OUT"
