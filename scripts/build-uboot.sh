#!/bin/bash
# build-uboot.sh — Download, build ARM Trusted Firmware (TF-A) and U-Boot
#                  for Olimex Teres-I (Allwinner A64 / sun50i-a64, AArch64).
#
# The Allwinner A64 requires TF-A BL31 (secure monitor) to be embedded
# in the U-Boot binary. This script compiles both automatically.
#
# Produces:
#   build/uboot/u-boot-sunxi-with-spl.bin  — flash to SD/NAND at 8 KiB offset
#   build/uboot/boot.scr                   — U-Boot boot script (from boot/boot.cmd)
#
# Requires: gcc-aarch64-linux-gnu, make, bc, flex, bison, libssl-dev,
#           python3, python3-cryptography, u-boot-tools, libgnutls28-dev
# Run: scripts/install-deps.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ARM Trusted Firmware (TF-A) — BL31 for Allwinner sun50i_a64
TFA_VERSION="v2.10.0"
TFA_URL="https://github.com/ARM-software/arm-trusted-firmware/archive/refs/tags/${TFA_VERSION}.tar.gz"
TFA_SHA256=""  # Set to SHA256 of the tarball to enable verification

# U-Boot
UBOOT_VERSION="2024.01"
UBOOT_URL="https://ftp.denx.de/pub/u-boot/u-boot-${UBOOT_VERSION}.tar.bz2"
UBOOT_SHA256=""  # Set to SHA256 of the tarball to enable verification
UBOOT_PATCH_MODE="${UBOOT_PATCH_MODE:-all}"  # all|none (none keeps host-only build fixes)

CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
# U-Boot uses ARCH=arm for ALL ARM targets (32-bit and 64-bit alike).
# AArch64 mode is selected by the defconfig, not by this variable.
# ARCH=arm64 is a Linux kernel convention that U-Boot does not recognise
# (there is no arch/arm64/ in U-Boot — only arch/arm/).
ARCH=arm
JOBS="${JOBS:-$(nproc)}"

BUILD_DIR="${REPO_ROOT}/build/uboot"
SOURCES_DIR="${REPO_ROOT}/build/sources"
TFA_SRC="${SOURCES_DIR}/arm-trusted-firmware-${TFA_VERSION#v}"
TFA_BL31="${SOURCES_DIR}/bl31-sun50i_a64.bin"
PATCHES_DIR="${REPO_ROOT}/patches/uboot"

# ── Helpers ────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

extract_tarball_tree() {
    local tarball="$1"
    local topdir="$2"
    local destination="$3"
    local tmpdir

    tmpdir="$(mktemp -d "${SOURCES_DIR}/.extract-XXXXXX")"
    tar -xjf "${tarball}" -C "${tmpdir}"
    [[ -d "${tmpdir}/${topdir}" ]] || die "Could not locate ${topdir} after extraction"
    mv "${tmpdir}/${topdir}" "${destination}"
    rmdir "${tmpdir}"
}

command -v "${CROSS_COMPILE}gcc" >/dev/null || die "${CROSS_COMPILE}gcc not found — run scripts/install-deps.sh"
command -v mkimage              >/dev/null || die "mkimage not found — install u-boot-tools"

case "${UBOOT_PATCH_MODE}" in
    all)
        UBOOT_SRC="${SOURCES_DIR}/u-boot-${UBOOT_VERSION}"
        APPLY_UBOOT_PATCHES=1
        ;;
    none)
        UBOOT_SRC="${SOURCES_DIR}/u-boot-${UBOOT_VERSION}-vanilla"
        APPLY_UBOOT_PATCHES=0
        ;;
    *)
        die "Unsupported UBOOT_PATCH_MODE='${UBOOT_PATCH_MODE}' (expected: all or none)"
        ;;
esac

mkdir -p "${BUILD_DIR}" "${SOURCES_DIR}"

# ── Download TF-A ──────────────────────────────────────────────────────────

TFA_TARBALL="${SOURCES_DIR}/arm-trusted-firmware-${TFA_VERSION}.tar.gz"
if [[ ! -f "${TFA_TARBALL}" ]]; then
    echo "==> Downloading ARM Trusted Firmware ${TFA_VERSION}..."
    curl -fL --progress-bar "${TFA_URL}" -o "${TFA_TARBALL}"
fi

if [[ -n "${TFA_SHA256}" ]]; then
    echo "==> Verifying TF-A checksum..."
    echo "${TFA_SHA256}  ${TFA_TARBALL}" | sha256sum -c -
else
    echo "==> TF-A checksum not set — skipping verification."
    echo "    SHA256: $(sha256sum "${TFA_TARBALL}" | cut -d' ' -f1)"
fi

# ── Extract TF-A ───────────────────────────────────────────────────────────

if [[ ! -d "${TFA_SRC}" ]]; then
    echo "==> Extracting ARM Trusted Firmware..."
    tar -xzf "${TFA_TARBALL}" -C "${SOURCES_DIR}"
    # GitHub releases produce trusted-firmware-a-<version without 'v'>; rename to our expected path
    if [[ -d "${SOURCES_DIR}/trusted-firmware-a-${TFA_VERSION#v}" ]]; then
        mv "${SOURCES_DIR}/trusted-firmware-a-${TFA_VERSION#v}" "${TFA_SRC}"
    fi
    [[ -d "${TFA_SRC}" ]] || die "Could not locate TF-A source after extraction — check tarball layout"
fi

# ── Build TF-A BL31 for sun50i_a64 ────────────────────────────────────────

if [[ ! -f "${TFA_BL31}" ]]; then
    echo "==> Building TF-A BL31 for sun50i_a64 (-j${JOBS})..."
    make -C "${TFA_SRC}" \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        PLAT=sun50i_a64 \
        DEBUG=0 \
        -j"${JOBS}" \
        bl31
    cp "${TFA_SRC}/build/sun50i_a64/release/bl31.bin" "${TFA_BL31}"
    echo "==> TF-A BL31: ${TFA_BL31}"
fi

# ── Download U-Boot ────────────────────────────────────────────────────────

UBOOT_TARBALL="${SOURCES_DIR}/u-boot-${UBOOT_VERSION}.tar.bz2"
if [[ ! -f "${UBOOT_TARBALL}" ]]; then
    echo "==> Downloading U-Boot ${UBOOT_VERSION}..."
    curl -fL --progress-bar "${UBOOT_URL}" -o "${UBOOT_TARBALL}"
fi

if [[ -n "${UBOOT_SHA256}" ]]; then
    echo "==> Verifying U-Boot checksum..."
    echo "${UBOOT_SHA256}  ${UBOOT_TARBALL}" | sha256sum -c -
else
    echo "==> U-Boot checksum not set — skipping verification."
    echo "    SHA256: $(sha256sum "${UBOOT_TARBALL}" | cut -d' ' -f1)"
fi

# ── Extract U-Boot ─────────────────────────────────────────────────────────

if [[ ! -d "${UBOOT_SRC}" ]]; then
    echo "==> Extracting U-Boot..."
    extract_tarball_tree "${UBOOT_TARBALL}" "u-boot-${UBOOT_VERSION}" "${UBOOT_SRC}"
fi

# ── Apply patches ──────────────────────────────────────────────────────────

PATCH_STAMP="${UBOOT_SRC}/.patched"
if (( APPLY_UBOOT_PATCHES )); then
    if [[ ! -f "${PATCH_STAMP}" ]]; then
        echo "==> Applying U-Boot patches..."
        for patch in "${PATCHES_DIR}"/*.patch; do
            [[ -f "${patch}" ]] || continue
            echo "    Applying: $(basename "${patch}")"
            if ! patch -N -d "${UBOOT_SRC}" -p1 < "${patch}"; then
                echo "    WARNING: patch $(basename "${patch}") did not apply cleanly — continuing anyway"
            fi
        done
        touch "${PATCH_STAMP}"
    fi
else
    if [[ ! -f "${PATCH_STAMP}" ]]; then
        echo "==> U-Boot patch mode: none (skipping Teres/runtime patches, keeping host build fixes)"
        for patch in "${PATCHES_DIR}"/*.patch; do
            [[ -f "${patch}" ]] || continue
            case "$(basename "${patch}")" in
                0001-pylibfdt-fix-SWIG_Python_AppendOutput-arity-for-SWIG-4.2.patch)
                    echo "    Applying host compatibility: $(basename "${patch}")"
                    if ! patch -N -d "${UBOOT_SRC}" -p1 < "${patch}"; then
                        echo "    WARNING: patch $(basename "${patch}") did not apply cleanly — continuing anyway"
                    fi
                    ;;
            esac
        done
        touch "${PATCH_STAMP}"
    fi
fi

# ── Configure U-Boot ──────────────────────────────────────────────────────

echo "==> Configuring U-Boot (teres_i_defconfig)..."
make -C "${UBOOT_SRC}" \
    ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    BL31="${TFA_BL31}" \
    O="${BUILD_DIR}" \
    teres_i_defconfig

# ── Build U-Boot ───────────────────────────────────────────────────────────

echo "==> Building U-Boot (-j${JOBS})..."
# SCP=/dev/null tells binman we have no SCP firmware; SCP (OpenRISC power
# management co-processor) is only needed for system suspend and is optional.
make -C "${UBOOT_SRC}" \
    ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    BL31="${TFA_BL31}" \
    SCP=/dev/null \
    O="${BUILD_DIR}" \
    -j"${JOBS}"

echo "==> U-Boot binary: ${BUILD_DIR}/u-boot-sunxi-with-spl.bin"

# ── Generate boot.scr ──────────────────────────────────────────────────────

echo "==> Generating boot.scr from boot/boot.cmd..."
mkimage -C none -A arm64 -T script \
    -d "${REPO_ROOT}/boot/boot.cmd" \
    "${BUILD_DIR}/boot.scr"
echo "==> Boot script: ${BUILD_DIR}/boot.scr"

echo ""
echo "==> U-Boot build complete."
echo "    Artifacts in: ${BUILD_DIR}/"
echo "    Next step: scripts/build-kernel.sh"
