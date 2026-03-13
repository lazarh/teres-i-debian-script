#!/bin/bash
# install-to-nand.sh — Write the running SD card OS to the internal eMMC.
#
# Run this from the booted SD card image as root on the Teres-I.
#
# The Teres-I's internal storage is eMMC at /dev/mmcblk2 (mmc2).
# This script partitions the eMMC identically to the SD card:
#   8 KiB offset : U-Boot SPL + proper (raw, dd)
#   Partition 1  : /boot (FAT32, 80 MiB)
#   Partition 2  : /     (ext4, remaining space)
#
# After install: remove the SD card and reboot to start from eMMC.

set -euo pipefail

UBOOT_BIN=/boot/u-boot-sunxi-with-spl.bin
EMMC_DEV=/dev/mmcblk2
BOOT_SIZE_MIB=80
WORK_DIR=$(mktemp -d)

# ── Helpers ────────────────────────────────────────────────────────────────

cleanup() {
    umount "${WORK_DIR}/boot" 2>/dev/null || true
    umount "${WORK_DIR}/root" 2>/dev/null || true
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

# ── Preflight checks ────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "Must be run as root"

for cmd in parted mkfs.vfat mkfs.ext4 rsync; do
    command -v "${cmd}" >/dev/null || die "${cmd} not found"
done

[[ -f "${UBOOT_BIN}" ]] || die "${UBOOT_BIN} not found — was the SD image built correctly?"
[[ -b "${EMMC_DEV}" ]]  || die "${EMMC_DEV} not found — are you running on Teres-I hardware?"

# Safety: refuse if eMMC is the current root device
ROOT_DEV=$(findmnt -n -o SOURCE /)
case "${ROOT_DEV}" in
    ${EMMC_DEV}*) die "Root filesystem is on ${EMMC_DEV} — refusing to overwrite the running system" ;;
esac

EMMC_SIZE=$(blockdev --getsize64 "${EMMC_DEV}")
EMMC_SIZE_GB=$(awk "BEGIN {printf \"%.1f\", ${EMMC_SIZE}/1073741824}")
echo "==> Detected eMMC: ${EMMC_DEV} (${EMMC_SIZE_GB} GB)"

# Warn if eMMC already has partitions
if lsblk -n -o NAME "${EMMC_DEV}" 2>/dev/null | grep -q "mmcblk2p"; then
    read -rp "eMMC already has partitions. Overwrite? [y/N] " answer
    [[ "${answer,,}" == "y" ]] || { echo "Aborted."; exit 0; }
fi

echo ""
echo "==> Installing to eMMC (${EMMC_DEV}).  All eMMC data will be lost."
echo "    Press Ctrl-C within 5 seconds to abort."
sleep 5

# ── Unmount any existing eMMC partitions ───────────────────────────────────

for part in "${EMMC_DEV}"p*; do
    umount "${part}" 2>/dev/null || true
done

# ── Partition eMMC ─────────────────────────────────────────────────────────

echo "==> Partitioning eMMC..."
parted -s "${EMMC_DEV}" mklabel msdos
parted -s "${EMMC_DEV}" mkpart primary fat32 40MiB $((40 + BOOT_SIZE_MIB))MiB
parted -s "${EMMC_DEV}" mkpart primary ext4  $((40 + BOOT_SIZE_MIB))MiB 100%
partprobe "${EMMC_DEV}"
sleep 1

BOOT_PART="${EMMC_DEV}p1"
ROOT_PART="${EMMC_DEV}p2"

# ── Flash U-Boot ────────────────────────────────────────────────────────────

echo "==> Writing U-Boot at 8 KiB offset..."
dd if="${UBOOT_BIN}" of="${EMMC_DEV}" bs=1k seek=8 conv=notrunc 2>/dev/null
echo "    U-Boot written."

# ── Format partitions ──────────────────────────────────────────────────────

echo "==> Formatting partitions..."
mkfs.vfat -n BOOT "${BOOT_PART}"
mkfs.ext4 -L rootfs -F "${ROOT_PART}"

# ── Mount partitions ──────────────────────────────────────────────────────

mkdir -p "${WORK_DIR}/boot" "${WORK_DIR}/root"
mount "${BOOT_PART}" "${WORK_DIR}/boot"
mount "${ROOT_PART}" "${WORK_DIR}/root"

# ── Copy boot files ────────────────────────────────────────────────────────

echo "==> Copying boot files..."
cp -a /boot/. "${WORK_DIR}/boot/"
# U-Boot binary is flashed raw — no need in the FAT partition
rm -f "${WORK_DIR}/boot/u-boot-sunxi-with-spl.bin"

# Generate an eMMC-specific boot.scr (root on mmcblk2p2)
echo "==> Generating eMMC boot script..."
EMMC_BOOT_CMD=$(mktemp /tmp/emmc-boot.XXXXXX.cmd)
cat > "${EMMC_BOOT_CMD}" <<'BOOTCMD'
# Boot from eMMC on Teres-I
# Linux names internal storage mmcblk2, but U-Boot sees it as mmc 1.
load mmc 1:1 ${kernel_addr_r} Image
load mmc 1:1 ${fdt_addr_r} sun50i-a64-teres-i.dtb
setenv bootargs console=ttyS0,115200 console=tty1 root=/dev/mmcblk2p2 rootfstype=ext4 rootwait panic=10 ${extra}
booti ${kernel_addr_r} - ${fdt_addr_r}
BOOTCMD
mkimage -C none -A arm64 -T script \
    -d "${EMMC_BOOT_CMD}" \
    "${WORK_DIR}/boot/boot.scr"
rm -f "${EMMC_BOOT_CMD}"
echo "    eMMC boot.scr written."

# ── Copy rootfs ────────────────────────────────────────────────────────────

echo "==> Copying rootfs (this takes several minutes)..."
rsync -aAX --exclude=/proc --exclude=/sys --exclude=/dev \
           --exclude=/run  --exclude=/tmp --exclude=/boot \
           / "${WORK_DIR}/root/"

# Recreate essential empty mountpoints
mkdir -p "${WORK_DIR}/root"/{proc,sys,dev,run,tmp,boot}
chmod 1777 "${WORK_DIR}/root/tmp"

# Copy kernel modules
if [[ -d /lib/modules ]]; then
    rsync -aAX /lib/modules/ "${WORK_DIR}/root/lib/modules/"
fi

# ── Update /etc/fstab for eMMC boot ───────────────────────────────────────

echo "==> Updating /etc/fstab for eMMC boot..."
BOOT_UUID=$(blkid -s UUID -o value "${BOOT_PART}")
ROOT_UUID=$(blkid -s UUID -o value "${ROOT_PART}")
cat > "${WORK_DIR}/root/etc/fstab" <<EOF
UUID=${ROOT_UUID}  /      ext4  defaults,noatime  0  1
UUID=${BOOT_UUID}  /boot  vfat  defaults          0  2
tmpfs              /tmp   tmpfs defaults,nosuid,nodev  0  0
EOF

sync
umount "${WORK_DIR}/boot"
umount "${WORK_DIR}/root"

echo ""
echo "==> Done! Remove the SD card and reboot to start from eMMC."
echo ""
echo "    eMMC layout (${EMMC_DEV}):"
echo "      8KiB offset  : U-Boot SPL + proper (raw)"
echo "      ${BOOT_PART} : /boot (FAT32, ${BOOT_SIZE_MIB} MiB)"
echo "      ${ROOT_PART} : /     (ext4, remaining)"
echo ""
echo "    U-Boot will auto-detect the absent SD card and boot from eMMC."
echo "    If it does not, enter U-Boot shell and run:"
echo "      => setenv boot_targets 'mmc1 mmc0'; saveenv; reset"
