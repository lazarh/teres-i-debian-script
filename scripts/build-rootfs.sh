#!/bin/bash
# build-rootfs.sh — Bootstrap a Debian 13 (trixie) arm64 rootfs for Teres-I.
#
# Must be run as root on an x86-64 Debian/Ubuntu build host.
#
# Prerequisites:
#   1. scripts/install-deps.sh    (installs debootstrap, qemu-user-static, etc.)
#   2. scripts/build-kernel.sh    (produces build/kernel/modules/ and Image)
#
# Environment variables:
#   HOSTNAME=myteres    — set board hostname (default: teres-i)
#   WIFI_SSID=MyNetwork — pre-configure WiFi (requires WIFI_PASSWORD)
#   WIFI_PASSWORD=secret — WPA2 passphrase for WIFI_SSID
#   BOOT_RETRY_TIMEOUT=90 — optional forced reboot timer in userspace (0 disables)
#   BOOT_RETRY_MAX_REBOOTS=3 — max automatic reboot attempts before giving up
#
# Produces: debian-rootfs/
# Consumed by: scripts/assemble-sd-image.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYSROOT="${REPO_ROOT}/debian-rootfs"
KERNEL_BUILD="${REPO_ROOT}/build/kernel"
MODULES_DIR="${KERNEL_BUILD}/modules"
HOSTNAME="${HOSTNAME:-teres-i}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
BOOT_RETRY_TIMEOUT="${BOOT_RETRY_TIMEOUT:-0}"
BOOT_RETRY_MAX_REBOOTS="${BOOT_RETRY_MAX_REBOOTS:-3}"
ARCH=arm64
SUITE=trixie
MIRROR=http://deb.debian.org/debian

# ── Helpers ────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must be run as root (debootstrap requires chroot)"

[[ -d "${KERNEL_BUILD}" ]] || die "build/kernel/ not found — run scripts/build-kernel.sh first"
[[ -f "${KERNEL_BUILD}/Image" ]] || die "build/kernel/Image not found — run scripts/build-kernel.sh first"

mount_chroot() {
    mount -t proc  proc     "${SYSROOT}/proc"
    mount -t sysfs sysfs    "${SYSROOT}/sys"
    mount --bind   /dev     "${SYSROOT}/dev"
    mount --bind   /dev/pts "${SYSROOT}/dev/pts"
    mount -t tmpfs tmpfs    "${SYSROOT}/run"
}

umount_chroot() {
    umount "${SYSROOT}/run"     2>/dev/null || true
    umount "${SYSROOT}/dev/pts" 2>/dev/null || true
    umount "${SYSROOT}/dev"     2>/dev/null || true
    umount "${SYSROOT}/sys"     2>/dev/null || true
    umount "${SYSROOT}/proc"    2>/dev/null || true
}

trap umount_chroot EXIT

command -v debootstrap          >/dev/null || die "debootstrap not found — run scripts/install-deps.sh"
command -v qemu-aarch64-static  >/dev/null || die "qemu-user-static not found — run scripts/install-deps.sh"
[[ "${BOOT_RETRY_TIMEOUT}" =~ ^[0-9]+$ ]] || die "BOOT_RETRY_TIMEOUT must be an integer number of seconds"
[[ "${BOOT_RETRY_MAX_REBOOTS}" =~ ^[0-9]+$ ]] || die "BOOT_RETRY_MAX_REBOOTS must be an integer"

# ── First stage debootstrap ─────────────────────────────────────────────────

echo "==> Stage 1: debootstrap ${SUITE} ${ARCH} into ${SYSROOT}"
if [[ -d "${SYSROOT}/debootstrap" ]]; then
    echo "    Stage 1 already done, skipping."
else
    rm -rf "${SYSROOT}"
    debootstrap \
        --arch="${ARCH}" \
        --foreign \
        --components=main,contrib,non-free,non-free-firmware \
        --include=ca-certificates,curl,gnupg,locales,apt-transport-https \
        "${SUITE}" "${SYSROOT}" "${MIRROR}"
fi

# Copy QEMU binary so the chroot can execute AArch64 binaries on x86
cp /usr/bin/qemu-aarch64-static "${SYSROOT}/usr/bin/"

# ── Second stage (inside chroot) ────────────────────────────────────────────

echo "==> Stage 2: debootstrap second stage inside chroot"
chroot "${SYSROOT}" /debootstrap/debootstrap --second-stage

mount_chroot

# ── Configure the system ────────────────────────────────────────────────────

echo "==> Configuring Debian system..."

cat > "${SYSROOT}/etc/apt/sources.list" <<EOF
deb ${MIRROR} ${SUITE} main contrib non-free non-free-firmware
deb ${MIRROR} ${SUITE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${SUITE}-security main contrib non-free non-free-firmware
EOF

echo "${HOSTNAME}" > "${SYSROOT}/etc/hostname"
cat > "${SYSROOT}/etc/hosts" <<EOF
127.0.0.1  localhost
127.0.1.1  ${HOSTNAME}
::1        localhost ip6-localhost ip6-loopback
EOF

echo "en_US.UTF-8 UTF-8" >> "${SYSROOT}/etc/locale.gen"
chroot "${SYSROOT}" locale-gen

echo "UTC" > "${SYSROOT}/etc/timezone"
chroot "${SYSROOT}" dpkg-reconfigure -f noninteractive tzdata

# /etc/fstab for SD card boot; overwritten by install-to-nand.sh for eMMC boot
cat > "${SYSROOT}/etc/fstab" <<EOF
/dev/mmcblk0p2  /      ext4  defaults,noatime  0  1
/dev/mmcblk0p1  /boot  vfat  defaults          0  2
tmpfs           /tmp   tmpfs defaults,nosuid,nodev  0  0
EOF

# Enable serial console (ttyS0 = Allwinner UART0 on A64)
chroot "${SYSROOT}" systemctl enable serial-getty@ttyS0.service || true

# ── Install base packages ───────────────────────────────────────────────────

echo "==> Installing packages..."
chroot "${SYSROOT}" apt-get update -q
chroot "${SYSROOT}" apt-get install -y --no-install-recommends \
    systemd-sysv dbus systemd-timesyncd \
    iproute2 iputils-ping iw wpasupplicant network-manager \
    openssh-server \
    firmware-brcm80211 \
    firmware-realtek \
    usbutils pciutils \
    vim-tiny less \
    util-linux e2fsprogs dosfstools parted cloud-guest-utils \
    rsync wget curl \
    mtd-utils \
    u-boot-tools \
    kmod iptables conntrack nftables

# ── Kernel modules ──────────────────────────────────────────────────────────

echo "==> Installing kernel modules from ${MODULES_DIR}..."
if [[ -d "${MODULES_DIR}/lib/modules" ]]; then
    # Debian trixie uses usrmerge (/lib -> usr/lib symlink).
    # Copy into usr/ so modules land at usr/lib/modules without breaking the symlink.
    cp -a "${MODULES_DIR}/lib/modules" "${SYSROOT}/usr/lib/"
    KVER=$(ls "${SYSROOT}/usr/lib/modules/" | head -1)
    if ! chroot "${SYSROOT}" depmod -a "${KVER}"; then
        echo "    WARNING: depmod failed for kernel ${KVER} — modules may not load at boot"
    fi
    echo "    Installed modules for kernel ${KVER}"
else
    echo "    WARNING: No modules found in ${MODULES_DIR}/lib/modules"
fi

# ── WiFi firmware ───────────────────────────────────────────────────────────
# Teres-I uses AP6212 (BCM43438) or RTL8723BS depending on board revision.
# firmware-brcm80211 covers BCM43438; firmware-realtek covers RTL8723BS.
# Load brcmfmac and rtl8723bs at boot so whichever chip is present is found.

echo "brcmfmac"  >> "${SYSROOT}/etc/modules"
echo "rtl8723bs" >> "${SYSROOT}/etc/modules"

# ── SSH — allow root login ──────────────────────────────────────────────────

echo "==> Configuring sshd (PermitRootLogin yes, PasswordAuthentication yes)..."
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' \
    "${SYSROOT}/etc/ssh/sshd_config"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
    "${SYSROOT}/etc/ssh/sshd_config"
chroot "${SYSROOT}" systemctl enable ssh.service || true

# ── NTP ─────────────────────────────────────────────────────────────────────

echo "==> Enabling systemd-timesyncd (NTP)..."
chroot "${SYSROOT}" systemctl enable systemd-timesyncd.service || true

# ── First-boot partition resize ─────────────────────────────────────────────

echo "==> Installing first-boot partition resize service..."

cat > "${SYSROOT}/usr/local/sbin/resize-rootfs.sh" <<'RESIZE_SCRIPT'
#!/bin/bash
# Expand the root partition and filesystem to fill the entire storage device.
# Runs once on first boot, then disables itself.
set -e

ROOT_PART=$(findmnt -n -o SOURCE /)
ROOT_DEV=$(lsblk -n -o PKNAME "${ROOT_PART}" | head -1)
PART_NUM=$(cat /sys/class/block/$(basename "${ROOT_PART}")/partition)

echo "resize-rootfs: expanding /dev/${ROOT_DEV} partition ${PART_NUM}..."
growpart "/dev/${ROOT_DEV}" "${PART_NUM}" || true
resize2fs "${ROOT_PART}" || true

echo "resize-rootfs: done, disabling service"
systemctl disable resize-rootfs.service
rm -f /etc/systemd/system/resize-rootfs.service
RESIZE_SCRIPT
chmod 0755 "${SYSROOT}/usr/local/sbin/resize-rootfs.sh"

cat > "${SYSROOT}/etc/systemd/system/resize-rootfs.service" <<'UNIT'
[Unit]
Description=Expand root partition to fill storage
DefaultDependencies=no
Before=local-fs-pre.target
After=systemd-remount-fs.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/resize-rootfs.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
UNIT

chroot "${SYSROOT}" systemctl enable resize-rootfs.service || true

# ── Embed install-to-nand.sh ────────────────────────────────────────────────

echo "==> Embedding install-to-nand.sh..."
install -m 0755 "${SCRIPT_DIR}/install-to-nand.sh" \
    "${SYSROOT}/usr/local/sbin/install-to-nand.sh"

# ── Optional boot-retry reboot service ───────────────────────────────────────

echo "==> Installing optional boot-retry reboot service..."

cat > "${SYSROOT}/usr/local/sbin/boot-retry-reboot.sh" <<'REBOOT_SCRIPT'
#!/bin/bash
set -euo pipefail

CONFIG="/etc/default/boot-retry-reboot"
CANCEL_FILE="/run/boot-retry-reboot.cancel"
STATE_DIR="/var/lib/boot-retry-reboot"
COUNT_FILE="${STATE_DIR}/count"

[[ -r "${CONFIG}" ]] || exit 0
. "${CONFIG}"

: "${BOOT_RETRY_TIMEOUT:=0}"
: "${BOOT_RETRY_MAX_REBOOTS:=3}"
[[ "${BOOT_RETRY_TIMEOUT}" =~ ^[0-9]+$ ]] || {
    echo "boot-retry-reboot: invalid BOOT_RETRY_TIMEOUT='${BOOT_RETRY_TIMEOUT}'" >&2
    exit 1
}
[[ "${BOOT_RETRY_MAX_REBOOTS}" =~ ^[0-9]+$ ]] || {
    echo "boot-retry-reboot: invalid BOOT_RETRY_MAX_REBOOTS='${BOOT_RETRY_MAX_REBOOTS}'" >&2
    exit 1
}

display_ready() {
    local connector status modes_file

    for connector in /sys/class/drm/card*-*; do
        [[ -e "${connector}" ]] || continue
        [[ -f "${connector}/status" ]] || continue
        status="$(cat "${connector}/status" 2>/dev/null || true)"
        [[ "${status}" == "connected" ]] || continue

        modes_file="${connector}/modes"
        if [[ ! -s "${modes_file}" ]]; then
            continue
        fi

        echo "boot-retry-reboot: display ready on $(basename "${connector}")"
        return 0
    done

    return 1
}

if (( BOOT_RETRY_TIMEOUT == 0 )); then
    exit 0
fi

echo "boot-retry-reboot: waiting ${BOOT_RETRY_TIMEOUT}s before forced reboot"
sleep "${BOOT_RETRY_TIMEOUT}"

if [[ -e "${CANCEL_FILE}" ]]; then
    echo "boot-retry-reboot: canceled via ${CANCEL_FILE}"
    exit 0
fi

if display_ready; then
    rm -f "${COUNT_FILE}"
    exit 0
fi

mkdir -p "${STATE_DIR}"
count=0
if [[ -r "${COUNT_FILE}" ]]; then
    count="$(cat "${COUNT_FILE}")"
fi

if ! [[ "${count}" =~ ^[0-9]+$ ]]; then
    count=0
fi

if (( count >= BOOT_RETRY_MAX_REBOOTS )); then
    echo "boot-retry-reboot: maximum reboot attempts (${BOOT_RETRY_MAX_REBOOTS}) reached, not rebooting"
    exit 0
fi

count=$((count + 1))
echo "${count}" > "${COUNT_FILE}"

echo "boot-retry-reboot: no DRM display detected, reboot attempt ${count}/${BOOT_RETRY_MAX_REBOOTS}"
echo "boot-retry-reboot: rebooting"
exec systemctl --force --force reboot
REBOOT_SCRIPT
chmod 0755 "${SYSROOT}/usr/local/sbin/boot-retry-reboot.sh"

cat > "${SYSROOT}/etc/systemd/system/boot-retry-reboot.service" <<'UNIT'
[Unit]
Description=Experimental fixed-time boot retry reboot
After=network.target ssh.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/boot-retry-reboot.sh

[Install]
WantedBy=multi-user.target
UNIT

if (( BOOT_RETRY_TIMEOUT > 0 )); then
    cat > "${SYSROOT}/etc/default/boot-retry-reboot" <<EOF
BOOT_RETRY_TIMEOUT=${BOOT_RETRY_TIMEOUT}
BOOT_RETRY_MAX_REBOOTS=${BOOT_RETRY_MAX_REBOOTS}
EOF
    chroot "${SYSROOT}" systemctl enable boot-retry-reboot.service || true
    echo "    Enabled boot-retry-reboot.service (${BOOT_RETRY_TIMEOUT}s timeout, max ${BOOT_RETRY_MAX_REBOOTS} reboots)."
else
    rm -f "${SYSROOT}/etc/default/boot-retry-reboot"
    chroot "${SYSROOT}" systemctl disable boot-retry-reboot.service >/dev/null 2>&1 || true
    echo "    Disabled (set BOOT_RETRY_TIMEOUT=N to enable)."
fi

# ── Copy U-Boot binary to /boot ─────────────────────────────────────────────
# Stored on the SD card FAT /boot partition so install-to-nand.sh can find it
# at /boot/u-boot-sunxi-with-spl.bin when running on the board.

echo "==> Copying U-Boot to /boot..."
UBOOT_BIN="${REPO_ROOT}/build/uboot/u-boot-sunxi-with-spl.bin"
if [[ -f "${UBOOT_BIN}" ]]; then
    install -m 0644 "${UBOOT_BIN}" "${SYSROOT}/boot/u-boot-sunxi-with-spl.bin"
else
    echo "    WARNING: ${UBOOT_BIN} not found — run scripts/build-uboot.sh first"
fi

# ── root password ───────────────────────────────────────────────────────────

echo "==> Setting root password to 'root' (change after first boot!)"
echo "root:root" | chroot "${SYSROOT}" chpasswd

# ── WiFi pre-configuration ──────────────────────────────────────────────────

if [[ -n "${WIFI_SSID}" && -n "${WIFI_PASSWORD}" ]]; then
    echo "==> Pre-configuring WiFi for SSID: ${WIFI_SSID}"
    NM_DIR="${SYSROOT}/etc/NetworkManager/system-connections"
    mkdir -p "${NM_DIR}"
    cat > "${NM_DIR}/wifi-preconfigured.nmconnection" <<EOF
[connection]
id=${WIFI_SSID}
type=wifi
autoconnect=true

[wifi]
ssid=${WIFI_SSID}
mode=infrastructure

[wifi-security]
key-mgmt=wpa-psk
psk=${WIFI_PASSWORD}

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=auto
EOF
    chmod 600 "${NM_DIR}/wifi-preconfigured.nmconnection"
    echo "    WiFi profile written (SSID: ${WIFI_SSID})."
elif [[ -n "${WIFI_SSID}" || -n "${WIFI_PASSWORD}" ]]; then
    echo "    WARNING: Both WIFI_SSID and WIFI_PASSWORD must be set to pre-configure WiFi. Skipping."
fi

# ── Cleanup ─────────────────────────────────────────────────────────────────

rm -f "${SYSROOT}/usr/bin/qemu-aarch64-static"
chroot "${SYSROOT}" apt-get clean
rm -rf "${SYSROOT}/var/lib/apt/lists/"*

echo ""
echo "==> Debian 13 (trixie) arm64 rootfs ready at: ${SYSROOT}"
echo "    HOSTNAME  was: ${HOSTNAME}"
echo "    WIFI_SSID was: ${WIFI_SSID:-<not set>}"
echo "    Next step: sudo scripts/assemble-sd-image.sh"
