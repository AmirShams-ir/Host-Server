#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Description: 1 Click Hosting for fresh Debian/Ubuntu VPS.
# Author: Amir Shams
# GitHub: https://github.com/AmirShams-ir/LinuxServer
# License: See GitHub repository for license details.
# -----------------------------------------------------------------------------

set -Eeuo pipefail
IFS=$'\n\t'

# ==============================================================================
# Root
# ==============================================================================
if [[ $EUID -ne 0 ]]; then exec sudo -E bash "$0" "$@"; fi

info(){ printf "\e[34m%s\e[0m\n" "$*"; }
ok(){ printf "\e[32m[✔] %s\e[0m\n" "$*"; }
warn(){ printf "\e[33m[!] %s\e[0m\n" "$*"; }
die(){ printf "\e[31m[✖] %s\e[0m\n" "$*"; exit 1; }
has_systemd(){ [[ -d /run/systemd/system ]]; }

# ==============================================================================
# OS Validation
# ==============================================================================
source /etc/os-release || die "Cannot detect OS"

case "$ID" in
  debian) [[ "$VERSION_ID" == "12" || "$VERSION_ID" == "13" ]] || die "Unsupported Debian";;
  ubuntu) [[ "$VERSION_ID" == "22.04" || "$VERSION_ID" == "24.04" ]] || die "Unsupported Ubuntu";;
  *) die "Unsupported OS";;
esac

ok "OS: $PRETTY_NAME"

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
# Banner
# ==============================================================================
info "═══════════════════════════════════════════"
info "✔ All in One Hosting Script Started"
info "═══════════════════════════════════════════"

# ==============================================================================
# Time & NTP
# ==============================================================================
if has_systemd; then
  timedatectl set-timezone UTC || true
  timedatectl set-ntp true || true
  ok "Timezone UTC & NTP enabled"
fi

# ==============================================================================
# Enterprise FQDN Configuration (Production-Safe)
# ==============================================================================

info "Configuring FQDN..."

read -rp "Enter Subdomain (e.g. vps): " SUB
read -rp "Enter Domain (example.com): " DOMAIN

[[ "$SUB" =~ ^[a-zA-Z0-9-]+$ ]] || die "Invalid subdomain"
[[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || die "Invalid domain"

FQDN="$SUB.$DOMAIN"
SHORT_HOST="${FQDN%%.*}"

# Detect IP
PUBLIC_IP=""
for service in \
  "https://api.ipify.org" \
  "https://ipv4.icanhazip.com" \
  "https://ifconfig.me/ip"
do
  PUBLIC_IP=$(curl -4 -s --max-time 5 "$service" 2>/dev/null || true)
  [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
done

[[ -z "$PUBLIC_IP" ]] && PUBLIC_IP=$(hostname -I | awk '{print $1}')
[[ -z "$PUBLIC_IP" ]] && die "Public IP detection failed"

info "Detected Public IP: $PUBLIC_IP"

CURRENT_HOST=$(hostname)
if [[ "$CURRENT_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  warn "Numeric hostname detected, replacing with FQDN..."
fi

hostnamectl set-hostname "$FQDN" || die "Failed to set hostname"

# Ensure localhost
grep -q "^127.0.0.1" /etc/hosts || echo "127.0.0.1 localhost" >> /etc/hosts

# Remove old entry safely
grep -v -w "$FQDN" /etc/hosts > /etc/hosts.tmp && mv /etc/hosts.tmp /etc/hosts

# Add mapping
echo "$PUBLIC_IP $FQDN $SHORT_HOST" >> /etc/hosts

ok "FQDN set to $FQDN"

# DNS check
RESOLVED_IP=$(getent hosts "$FQDN" | awk '{print $1}' | head -n1 || true)
[[ "$RESOLVED_IP" != "$PUBLIC_IP" ]] && warn "DNS A record not yet resolving"

# Reverse DNS check
PTR=$(dig +short -x "$PUBLIC_IP" 2>/dev/null || true)
[[ -z "$PTR" ]] && warn "PTR record not configured"

# Preseed postfix (important before apt)
echo "postfix postfix/mailname string $DOMAIN" | debconf-set-selections
echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections

ok "FQDN Configuration Set"

# ==============================================================================
# Base Packages
# ==============================================================================
apt update -y && apt upgrade -y

apt install -y \
curl gnupg ca-certificates \
apt-transport-https zip unzip tar \
rsync jq unattended-upgrades default-mysql-client

ok "Base packages installed"

# ==============================================================================
# Port Check
# ==============================================================================
for p in 80 443 8443 3306; do
  ss -lnt | grep -q ":$p " && die "Port $p in use. Clean VPS required."
done

ok "Ports Checked and Free"

# ==============================================================================
# Swap (Adaptive)
# ==============================================================================
if ! swapon --show | grep -q swap; then
  RAM=$(free -m | awk '/Mem:/ {print $2}')
  SIZE="2G"; [[ "$RAM" -gt 2048 ]] && SIZE="1G"
  fallocate -l $SIZE /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
  ok "Swap created ($SIZE)"
fi

# ==============================================================================
# Zram Configuration
# ==============================================================================
info "Starting Zram configuration..."

systemctl start zramswap.service
systemctl enable zramswap.service
systemctl status zramswap.service

ok "Zram created"

# ==============================================================================
# Ultra Kernel & Network Tuning (Adaptive)
# ==============================================================================
info "Applying Ultra Kernel Tuning..."

SYSCTL_FILE="/etc/sysctl.d/99-ultra-hosting.conf"

RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
CONNTRACK=262144
[[ "$RAM_MB" -lt 1500 ]] && CONNTRACK=131072

modprobe nf_conntrack 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

cat > "$SYSCTL_FILE" <<EOF
fs.file-max=500000
vm.swappiness=10
vm.dirty_ratio=15
vm.dirty_background_ratio=5

net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3

net.core.rmem_default=262144
net.core.rmem_max=16777216
net.core.wmem_default=262144
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216

net.core.somaxconn=32768
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.ip_local_port_range=1024 65000

net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.rp_filter=1
net.ipv4.icmp_echo_ignore_broadcasts=1
EOF

# Apply conntrack only if available
if [[ -d /proc/sys/net/netfilter ]]; then
  sysctl -w net.netfilter.nf_conntrack_max=$CONNTRACK 2>/dev/null || true
  sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=600 2>/dev/null || true
  sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=30 2>/dev/null || true
fi

sysctl --system >/dev/null

cat > /etc/security/limits.d/99-hosting.conf <<EOF
* soft nofile 500000
* hard nofile 500000
root soft nofile 500000
root hard nofile 500000
EOF

ok "Kernel tuned safely (Conntrack=$CONNTRACK)"

# ==============================================================================
# Install CloudPanel
# ==============================================================================
info "Installing CloudPanel..."
curl -fsSL https://installer.cloudpanel.io/ce/v2/install.sh -o /tmp/clp.sh
bash /tmp/clp.sh
rm -f /tmp/clp.sh

sleep 5
systemctl is-active --quiet clp-agent || die "CloudPanel failed"
ok "CloudPanel installed"

# ==============================================================================
# MariaDB Optimize (1GB Safe)
# ==============================================================================
cat > /etc/mysql/mariadb.conf.d/99-optimized.cnf <<EOF
[mysqld]
innodb_buffer_pool_size=256M
innodb_log_file_size=64M
max_connections=30
tmp_table_size=32M
max_heap_table_size=32M
thread_cache_size=8
table_open_cache=400
query_cache_type=0
query_cache_size=0
EOF
systemctl restart mariadb
ok "MariaDB optimized"

# ==============================================================================
# PHP-FPM Optimize
# ==============================================================================
for v in 8.1 8.2; do
  DIR="/etc/php/$v/fpm/pool.d"
  [[ -d "$DIR" ]] || continue
  sed -i "s/^pm.max_children.*/pm.max_children = 4/" $DIR/*.conf || true
  sed -i "s/^pm.start_servers.*/pm.start_servers = 2/" $DIR/*.conf || true
  sed -i "s/^pm.min_spare_servers.*/pm.min_spare_servers = 1/" $DIR/*.conf || true
  sed -i "s/^pm.max_spare_servers.*/pm.max_spare_servers = 2/" $DIR/*.conf || true
  sed -i "s/^pm.max_requests.*/pm.max_requests = 300/" $DIR/*.conf || true
  systemctl restart php$v-fpm || true
done
ok "PHP-FPM optimized"

# ==============================================================================
# OPcache
# ==============================================================================
for v in 8.1 8.2; do
  [[ -d /etc/php/$v ]] || continue
  cat > /etc/php/$v/fpm/conf.d/99-opcache.ini <<EOF
opcache.enable=1
opcache.memory_consumption=64
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=10000
opcache.validate_timestamps=1
opcache.revalidate_freq=60
EOF
  systemctl restart php$v-fpm || true
done
ok "OPcache enabled"

# ==============================================================================
# Firewall (UFW)
# ==============================================================================
info "Installing and configuring UFW..."

apt-get update || die "APT update failed"
apt-get install -y ufw || die "UFW installation failed"

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 8443/tcp comment 'CLOUDPANEL'

ufw --force enable

ok "Firewall installed and configured and enabled"

# ==============================================================================
# Fail2Ban
# ==============================================================================
info "Installing and configuring Fail2Ban..."

apt-get update -y || die "APT update failed"
apt-get install -y fail2ban apache2-utils || die "Fail2Ban installation failed"

mkdir -p /etc/fail2ban

cat > /etc/fail2ban/jail.local <<'EOF'
# Default Settings
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
usedns   = warn
banaction = iptables-multiport

# SSH Protection
[sshd]
enabled  = true
port     = 22
logpath  = /var/log/auth.log
maxretry = 5

# CloudPanel Nginx Protection
[nginx-badbots]
enabled  = true
port     = http,https
logpath  = /home/*/logs/nginx/*access.log
maxretry = 5

[nginx-http-auth]
enabled  = true
port     = http,https
logpath  = /home/*/logs/nginx/*error.log
maxretry = 5
EOF

systemctl enable fail2ban
systemctl restart fail2ban || die "Fail2Ban failed to start"
sleep 2
fail2ban-client status

ok "Fail2Ban fully hardened and active"

# ==============================================================================
# Final
# ==============================================================================
IP=$(hostname -I | awk '{print $1}')

echo
info "═══════════════════════════════════════════"
ok " CloudPanel Ultra Hosting Ready"
ok " Access: https://$IP:8443"
ok " FQDN  : $FQDN"
ok " Reboot recommended now"
info "═══════════════════════════════════════════"
