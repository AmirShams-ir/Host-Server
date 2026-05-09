#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Description: Bootstrap and harden a fresh Debian/Ubuntu VPS.
# Author: Amir Shams
# GitHub: https://github.com/AmirShams-ir/LinuxServer
# License: See GitHub repository for license details.
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
# OS Validation
# ==============================================================================
if [[ -f /etc/os-release ]]; then
  source /etc/os-release
else
  printf "Cannot detect OS.\n"
  exit 1
fi

[[ "${ID}" == "debian" || "${ID}" == "ubuntu" || "${ID_LIKE:-}" == *"debian"* ]] \
  || { printf "Debian/Ubuntu only.\n"; exit 1; }

# ==============================================================================
# Logging
# ==============================================================================
LOG="/var/log/server-$(basename "$0" .sh).log"
mkdir -p "$(dirname "$LOG")"
: > "$LOG"

{
  printf "============================================================\n"
  printf " Script: %s\n" "$(basename "$0")"
  printf " Started at: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf " Hostname: %s\n" "$(hostname)"
  printf "============================================================\n"
} >> "$LOG"

exec > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2)

# ==============================================================================
# Helpers
# ==============================================================================
info() { printf "\e[34m%s\e[0m\n" "$*"; }
rept() { printf "\e[32m[✔] %s\e[0m\n" "$*"; }
warn() { printf "\e[33m[!] %s\e[0m\n" "$*"; }
die()  { printf "\e[31m[✖] %s\e[0m\n" "$*"; exit 1; }

has_systemd() {
  [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1
}

# ==============================================================================
# Banner
# ==============================================================================
info "═══════════════════════════════════════════"
info "✔ Bootstrap Script Started"
info "═══════════════════════════════════════════"

# ==============================================================================
# Timezone & Locale
# ==============================================================================
info "Starting timezone and locale configuration..."

if has_systemd; then
  CURRENT_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  [[ "$CURRENT_TZ" != "UTC" ]] && timedatectl set-timezone UTC
else
  warn "Systemd not detected, timezone enforcement skipped"
fi

LOCALE="en_US.UTF-8"
if ! locale -a | grep -qx "$LOCALE"; then
  sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
  locale-gen "$LOCALE"
fi

update-locale LANG="$LOCALE" LC_ALL="$LOCALE"
export LANG="$LOCALE" LC_ALL="$LOCALE"

rept "Timezone and locale configuration completed"

# ==============================================================================
# System Update
# ==============================================================================
info "Starting system update..."

apt-get update || die "apt update failed"
apt-get upgrade -y || die "apt upgrade failed"
apt-get autoremove -y
apt-get autoclean -y

rept "System update completed"

# ==============================================================================
# Essential Packages
# ==============================================================================
info "Starting essential package installation..."

apt-get install -y \
  sudo curl wget git dialog ca-certificates gnupg lsb-release \
  zram-tools zip unzip net-tools openssl build-essential \
  bash-completion unattended-upgrades \
  || die "Package installation failed"

rept "Essential packages installed"

info "Configuring automatic security updates..."
dpkg-reconfigure -f noninteractive unattended-upgrades \
  || warn "Unattended-upgrades configuration skipped"

rept "Automatic security updates configured"

# ==============================================================================
# Swap Configuration
# ==============================================================================
info "Starting swap configuration..."

if ! swapon --show | grep -q swap; then
  RAM_MB="$(free -m | awk '/Mem:/ {print $2}')"
  [[ "$RAM_MB" -lt 2048 ]] && SWAP_SIZE="2G" || SWAP_SIZE="1G"

  fallocate -l "$SWAP_SIZE" /swapfile || die "Swap allocation failed"
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw,pri=10 0 0" >> /etc/fstab

  rept "Swap created and enabled"
else
  warn "Swap already active"
fi

# ==============================================================================
# Zram Configuration
# ==============================================================================
info "Starting Zram configuration..."

systemctl start zramswap.service
systemctl enable zramswap.service
systemctl status zramswap.service

# ==============================================================================
# Sysctl Baseline
# ==============================================================================
info "Applying sysctl baseline..."

cat <<EOF >/etc/sysctl.d/99-bootstrap.conf
vm.swappiness=10
fs.file-max=100000
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
EOF

sysctl --system >/dev/null || die "Sysctl reload failed"

rept "Sysctl baseline applied"

# ==============================================================================
# TCP BBR
# ==============================================================================
info "Configuring TCP BBR..."

modprobe tcp_bbr || true

if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
  cat <<EOF >/etc/sysctl.d/99-bbr.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null
  rept "TCP BBR enabled"
else
  warn "BBR not supported on this kernel"
fi

# ==============================================================================
# Journald Limits
# ==============================================================================
info "Configuring journald limits..."

if has_systemd; then
  mkdir -p /etc/systemd/journald.conf.d
  cat <<EOF >/etc/systemd/journald.conf.d/limit.conf
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=100M
EOF
  systemctl restart systemd-journald
  rept "Journald limits applied"
else
  warn "Systemd not detected, journald skipped"
fi

# ==============================================================================
# Cleanup
# ==============================================================================
info "Performing cleanup..."

apt-get autoremove -y
apt-get autoclean -y

unset LOG CURRENT_TZ LOCALE RAM_MB SWAP_SIZE

rept "Cleanup completed"

# ==============================================================================
# Final Summary
# ==============================================================================
info "══════════════════════════════════════════════════"
rept "Bootstrap completed successfully"
rept "System is clean, updated and production-ready"
info "══════════════════════════════════════════════════"
