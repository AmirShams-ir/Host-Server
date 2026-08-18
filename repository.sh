#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Description: Configure Debian repositories with prioritized Iranian mirrors
#              and preserve Armbian repositories on Armbian systems.
#
# Supports:
#   - Debian 12 Bookworm
#   - Debian 13 Trixie
#   - Armbian based on Debian
#   - Ubuntu 22.04 Jammy
#   - Ubuntu 24.04 Noble
#
# Author: Amir Shams
# GitHub: https://github.com/AmirShams-ir/Host-Server
# -----------------------------------------------------------------------------

set -Eeuo pipefail
IFS=$'\n\t'

# ==============================================================================
# Root Handling
# ==============================================================================

if [[ "${EUID}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        exec sudo --preserve-env=PATH bash "$0" "$@"
    else
        printf "Root privileges required.\n"
        exit 1
    fi
fi

# ==============================================================================
# OS Detection
# ==============================================================================

if [[ ! -f /etc/os-release ]]; then
    printf "Cannot detect OS.\n"
    exit 1
fi

source /etc/os-release

OS_ID="${ID:-}"
OS_ID_LIKE="${ID_LIKE:-}"
OS_VER="${VERSION_ID:-}"
PRETTY="${PRETTY_NAME:-Unknown}"

# Detect Debian-family systems
IS_DEBIAN=false
IS_UBUNTU=false
IS_ARMBIAN=false

if [[ "$OS_ID" == "debian" || "$OS_ID_LIKE" == *"debian"* ]]; then
    IS_DEBIAN=true
fi

if [[ "$OS_ID" == "ubuntu" || "$OS_ID_LIKE" == *"ubuntu"* ]]; then
    IS_UBUNTU=true
fi

if [[ "$OS_ID" == "armbian" || -n "${ARMBIAN_PRETTY_NAME:-}" ]] ||
   [[ -f /etc/armbian-release ]]; then
    IS_ARMBIAN=true
fi

if ! $IS_DEBIAN && ! $IS_UBUNTU; then
    printf "Unsupported OS: %s\n" "$PRETTY"
    exit 1
fi

# ==============================================================================
# Architecture
# ==============================================================================

ARCH="$(dpkg --print-architecture 2>/dev/null || true)"

if [[ -z "$ARCH" ]]; then
    printf "Cannot determine Debian architecture.\n"
    exit 1
fi

# ==============================================================================
# Paths
# ==============================================================================

MAIN_LIST="/etc/apt/sources.list"
IR_LIST="/etc/apt/sources.list.d/ir-mirrors.list"
ARMBIAN_LIST="/etc/apt/sources.list.d/armbian.sources"
PIN_FILE="/etc/apt/preferences.d/99-mirror-priority"
APT_CONF="/etc/apt/apt.conf.d/99-fast-retries"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p /etc/apt/sources.list.d
mkdir -p /etc/apt/preferences.d
mkdir -p /etc/apt/apt.conf.d

# ==============================================================================
# Logging
# ==============================================================================

LOG="/var/log/server-$(basename "$0" .sh).log"

mkdir -p "$(dirname "$LOG")"
touch "$LOG"

exec > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2)

# ==============================================================================
# Helpers
# ==============================================================================

info() {
    printf "\e[34m%s\e[0m\n" "$*"
}

rept() {
    printf "\e[32m[✔] %s\e[0m\n" "$*"
}

warn() {
    printf "\e[33m[!] %s\e[0m\n" "$*"
}

die() {
    printf "\e[31m[✖] %s\e[0m\n" "$*"
    exit 1
}

# ==============================================================================
# Banner
# ==============================================================================

info "══════════════════════════════════════════════════════════"
info " Repository Configuration"
info "══════════════════════════════════════════════════════════"

echo "Detected OS   : $PRETTY"
echo "OS ID         : $OS_ID"
echo "OS Version    : $OS_VER"
echo "Architecture  : $ARCH"
echo "Armbian       : $IS_ARMBIAN"

# ==============================================================================
# Backup Existing Configuration
# ==============================================================================

if [[ -f "$MAIN_LIST" ]]; then
    cp -a "$MAIN_LIST" "${MAIN_LIST}.bak.${TIMESTAMP}"
fi

if [[ -f "$IR_LIST" ]]; then
    cp -a "$IR_LIST" "${IR_LIST}.bak.${TIMESTAMP}"
fi

if [[ -f "$ARMBIAN_LIST" ]]; then
    cp -a "$ARMBIAN_LIST" "${ARMBIAN_LIST}.bak.${TIMESTAMP}"
fi

rept "APT configuration backup created."

# ==============================================================================
# Debian / Armbian
# ==============================================================================

if $IS_DEBIAN; then

    case "$OS_VER" in
        12|12.*)
            CODENAME="bookworm"
            COMPONENTS="main contrib non-free non-free-firmware"
            ;;

        13|13.*)
            CODENAME="trixie"
            COMPONENTS="main contrib non-free non-free-firmware"
            ;;

        *)
            die "Unsupported Debian/Armbian version: $OS_VER"
            ;;
    esac

    info "Debian base detected: $CODENAME"

    # --------------------------------------------------------------------------
    # Official Debian repositories
    # Fallback only
    # --------------------------------------------------------------------------

    cat > "$MAIN_LIST" <<EOF
# Official Debian repositories
# Fallback source

deb https://deb.debian.org/debian $CODENAME $COMPONENTS
deb https://deb.debian.org/debian $CODENAME-updates $COMPONENTS
deb https://security.debian.org/debian-security $CODENAME-security $COMPONENTS
EOF

    # --------------------------------------------------------------------------
    # Iranian Debian mirrors
    # Primary sources
    # --------------------------------------------------------------------------

    cat > "$IR_LIST" <<EOF
# ==============================================================================
# Iranian Debian Mirrors
# Primary repositories
# ==============================================================================

deb http://mirror.cdn.ir/repository/debian $CODENAME $COMPONENTS
deb http://mirror.cdn.ir/repository/debian $CODENAME-updates $COMPONENTS
deb http://mirror.cdn.ir/repository/debian-security $CODENAME-security $COMPONENTS

deb http://repo.iut.ac.ir/debian $CODENAME $COMPONENTS
deb http://repo.iut.ac.ir/debian $CODENAME-updates $COMPONENTS

deb http://mirror.arvancloud.ir/debian $CODENAME $COMPONENTS
deb http://mirror.arvancloud.ir/debian-security $CODENAME-security $COMPONENTS
EOF

    # --------------------------------------------------------------------------
    # Debian repository priority
    # --------------------------------------------------------------------------

    cat > "$PIN_FILE" <<EOF
# ==============================================================================
# Debian Mirror Priority
# ==============================================================================

Package: *
Pin: origin "mirror.cdn.ir"
Pin-Priority: 900

Package: *
Pin: origin "repo.iut.ac.ir"
Pin-Priority: 850

Package: *
Pin: origin "mirror.arvancloud.ir"
Pin-Priority: 800

Package: *
Pin: origin "deb.debian.org"
Pin-Priority: 400

Package: *
Pin: origin "security.debian.org"
Pin-Priority: 400
EOF

    rept "Debian repositories configured."

    # --------------------------------------------------------------------------
    # Armbian repositories
    # --------------------------------------------------------------------------

    if $IS_ARMBIAN; then

        info "Armbian system detected."

        # Keep existing Armbian repository files intact.
        #
        # We deliberately do NOT replace apt.armbian.com or
        # github.armbian.com here because these repositories contain
        # Armbian-specific packages such as:
        #
        #   armbian-config
        #   armbian-firmware
        #   linux-image-current-*
        #
        # If an existing Armbian source configuration is present,
        # preserve it.

        if [[ -f /etc/apt/sources.list.d/armbian.list ]]; then
            rept "Existing Armbian repository preserved:"
            echo "  /etc/apt/sources.list.d/armbian.list"

        elif [[ -f /etc/apt/sources.list.d/armbian.sources ]]; then
            rept "Existing Armbian repository preserved:"
            echo "  /etc/apt/sources.list.d/armbian.sources"

        else
            warn "No Armbian repository file detected."
            warn "Existing Armbian APT configuration was not found."
        fi

    fi
fi

# ==============================================================================
# Ubuntu
# ==============================================================================

if $IS_UBUNTU; then

    case "$OS_VER" in
        22.04)
            CODENAME="jammy"
            ;;

        24.04)
            CODENAME="noble"
            ;;

        *)
            die "Unsupported Ubuntu version: $OS_VER"
            ;;
    esac

    COMPONENTS="main restricted universe multiverse"

    info "Ubuntu detected: $CODENAME"

    # --------------------------------------------------------------------------
    # Official Ubuntu repositories
    # --------------------------------------------------------------------------

    cat > "$MAIN_LIST" <<EOF
# Official Ubuntu repositories
# Fallback source

deb https://archive.ubuntu.com/ubuntu $CODENAME $COMPONENTS
deb https://archive.ubuntu.com/ubuntu $CODENAME-updates $COMPONENTS
deb https://security.ubuntu.com/ubuntu $CODENAME-security $COMPONENTS
EOF

    # --------------------------------------------------------------------------
    # Iranian Ubuntu mirrors
    # --------------------------------------------------------------------------

    cat > "$IR_LIST" <<EOF
# ==============================================================================
# Iranian Ubuntu Mirrors
# ==============================================================================

deb http://mirror.cdn.ir/ubuntu $CODENAME $COMPONENTS
deb http://mirror.cdn.ir/ubuntu $CODENAME-updates $COMPONENTS
deb http://mirror.cdn.ir/ubuntu $CODENAME-security $COMPONENTS

deb http://repo.iut.ac.ir/ubuntu $CODENAME $COMPONENTS
deb http://repo.iut.ac.ir/ubuntu $CODENAME-updates $COMPONENTS
deb http://repo.iut.ac.ir/ubuntu $CODENAME-security $COMPONENTS

deb http://mirror.arvancloud.ir/ubuntu $CODENAME $COMPONENTS
EOF

    # --------------------------------------------------------------------------
    # Ubuntu repository priority
    # --------------------------------------------------------------------------

    cat > "$PIN_FILE" <<EOF
# ==============================================================================
# Ubuntu Mirror Priority
# ==============================================================================

Package: *
Pin: origin "mirror.cdn.ir"
Pin-Priority: 900

Package: *
Pin: origin "repo.iut.ac.ir"
Pin-Priority: 850

Package: *
Pin: origin "mirror.arvancloud.ir"
Pin-Priority: 800

Package: *
Pin: origin "archive.ubuntu.com"
Pin-Priority: 400

Package: *
Pin: origin "security.ubuntu.com"
Pin-Priority: 400
EOF

    rept "Ubuntu repositories configured."
fi

# ==============================================================================
# APT Performance / Failover
# ==============================================================================

cat > "$APT_CONF" <<EOF
Acquire::Retries "5";

Acquire::http::Timeout "15";
Acquire::https::Timeout "15";

Acquire::Queue-Mode "access";

APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF

rept "APT retry/failover configuration applied."

# ==============================================================================
# IPv4 Preference
# ==============================================================================

# Armbian/Orange Pi systems may have working IPv6 DNS resolution while
# IPv6 routing to external repositories is unavailable.
#
# Force APT to use IPv4 for repository access.
#
# This does NOT disable IPv6 system-wide.

cat > /etc/apt/apt.conf.d/99-force-ipv4 <<EOF
Acquire::ForceIPv4 "true";
EOF

rept "APT configured to prefer IPv4."

# ==============================================================================
# Clean & Update
# ==============================================================================

info "Cleaning APT cache..."

apt-get clean

info "Updating package indexes..."

if ! apt-get update; then
    die "APT update failed. Check repository connectivity."
fi

# ==============================================================================
# Repository Verification
# ==============================================================================

info "Repository policy:"

apt-cache policy bash | sed -n '1,20p'

# ==============================================================================
# Final Summary
# ==============================================================================

info "══════════════════════════════════════════════════════════"
rept "OS           : $PRETTY"
rept "Architecture : $ARCH"
rept "Debian base  : ${CODENAME:-N/A}"
rept "IR Mirrors   : Enabled"
rept "Official     : Fallback"
rept "Armbian Repo : $IS_ARMBIAN"
rept "APT IPv4     : Forced"
info "══════════════════════════════════════════════════════════"

unset OS_ID OS_ID_LIKE OS_VER PRETTY ARCH
unset IS_DEBIAN IS_UBUNTU IS_ARMBIAN
unset CODENAME COMPONENTS
unset MAIN_LIST IR_LIST ARMBIAN_LIST PIN_FILE APT_CONF