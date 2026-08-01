#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Description : One Click Mail Forwarder for Debian / Ubuntu VPS
# Author      : Amir Shams
# GitHub      : https://github.com/AmirShams-ir/LinuxServer
# License     : See GitHub repository for license details.
# -----------------------------------------------------------------------------

set -Eeuo pipefail
IFS=$'\n\t'

# ==============================================================================
# Root Check
# ==============================================================================

if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

# ==============================================================================
# Colors
# ==============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { printf "${BLUE}%s${NC}\n" "$*"; }
ok()    { printf "${GREEN}[✔] %s${NC}\n" "$*"; }
warn()  { printf "${YELLOW}[!] %s${NC}\n" "$*"; }
die()   { printf "${RED}[✖] %s${NC}\n" "$*"; exit 1; }

has_systemd() {
    [[ -d /run/systemd/system ]]
}

# ==============================================================================
# OS Validation
# ==============================================================================

source /etc/os-release || die "Cannot detect operating system."

case "$ID" in

    debian)

        [[ "$VERSION_ID" == "12" || "$VERSION_ID" == "13" ]] \
            || die "Unsupported Debian version."

    ;;

    ubuntu)

        [[ "$VERSION_ID" == "22.04" || "$VERSION_ID" == "24.04" ]] \
            || die "Unsupported Ubuntu version."

    ;;

    *)

        die "Unsupported operating system."

    ;;

esac

ok "Detected OS : $PRETTY_NAME"

# ==============================================================================
# Logging
# ==============================================================================

LOG="/var/log/server-$(basename "$0" .sh).log"

mkdir -p "$(dirname "$LOG")"

: > "$LOG"

{

printf "============================================================\n"
printf " Script     : %s\n" "$(basename "$0")"
printf " Started    : %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf " Hostname   : %s\n" "$(hostname)"
printf "============================================================\n"

} >> "$LOG"

exec > >(tee -a "$LOG") 2> >(tee -a "$LOG" >&2)

# ==============================================================================
# Banner
# ==============================================================================

clear

echo
info "═══════════════════════════════════════════════════════════════"
info "               LinuxServer Mail Forwarder"
info "═══════════════════════════════════════════════════════════════"
echo

ok "Logging  : $LOG"

# ==============================================================================
# Global Variables
# ==============================================================================

POSTFIX_MAIN="/etc/postfix/main.cf"

POSTFIX_MASTER="/etc/postfix/master.cf"

POSTFIX_VIRTUAL="/etc/postfix/virtual"

BACKUP_DIR="/root/mailforward-backup"

mkdir -p "$BACKUP_DIR"

# ==============================================================================
# Trap
# ==============================================================================

cleanup() {

    true

}

trap cleanup EXIT

trap 'die "Interrupted."' INT TERM

# ==============================================================================
# Start
# ==============================================================================

info "Starting Mail Forwarder..."
echo

# ==============================================================================
# Postfix Detection
# ==============================================================================

info "Checking Postfix..."

if command -v postconf >/dev/null 2>&1; then

    POSTFIX_INSTALLED=true

    POSTFIX_VERSION="$(postconf -h mail_version 2>/dev/null || true)"

    ok "Postfix detected (Version: ${POSTFIX_VERSION:-Unknown})"

else

    POSTFIX_INSTALLED=false

    warn "Postfix not installed."

fi

# ==============================================================================
# Install Postfix (If Missing)
# ==============================================================================

if [[ "$POSTFIX_INSTALLED" == false ]]; then

    info "Installing Postfix..."

    HOSTNAME="$(hostname -f)"
    DOMAIN="$(hostname -d)"

    [[ -z "$DOMAIN" ]] && DOMAIN="localhost"

    echo "postfix postfix/mailname string mail.$DOMAIN" \
        | debconf-set-selections

    echo "postfix postfix/main_mailer_type string 'Internet Site'" \
        | debconf-set-selections

    apt-get update

    apt-get install -y postfix mailutils \
        || die "Postfix installation failed."

    ok "Postfix installed successfully."

fi

# ==============================================================================
# Service Check
# ==============================================================================

info "Checking Postfix service..."

systemctl enable postfix >/dev/null 2>&1 || true

systemctl restart postfix \
    || die "Unable to start Postfix."

systemctl is-active --quiet postfix \
    || die "Postfix service is not running."

ok "Postfix service is active."

# ==============================================================================
# Port 25 Check
# ==============================================================================

info "Checking SMTP listener..."

if ss -lnt | grep -q ":25 "; then

    ok "SMTP port 25 is listening."

else

    die "Port 25 is not listening."

fi

# ==============================================================================
# Backup Current Configuration
# ==============================================================================

info "Creating configuration backup..."

DATE="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR/$DATE"

cp -a "$POSTFIX_MAIN" \
      "$BACKUP_DIR/$DATE/" 2>/dev/null || true

cp -a "$POSTFIX_MASTER" \
      "$BACKUP_DIR/$DATE/" 2>/dev/null || true

cp -a "$POSTFIX_VIRTUAL" \
      "$BACKUP_DIR/$DATE/" 2>/dev/null || true

[[ -f /etc/aliases ]] && \
cp -a /etc/aliases \
      "$BACKUP_DIR/$DATE/"

ok "Backup created."

# ==============================================================================
# Host FQDN
# ==============================================================================

HOST_FQDN="$(hostname -f)"

if [[ -z "$HOST_FQDN" || "$HOST_FQDN" == "$(hostname -s)" ]]; then

    die "Unable to detect Host FQDN."

fi

ok "Host FQDN : $HOST_FQDN"

echo

# ==============================================================================
# Mail FQDN
# ==============================================================================

read -rp "Mail FQDN (example: mail.example.com): " MAIL_FQDN

[[ "$MAIL_FQDN" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]] \
    || die "Invalid Mail FQDN."

if ! getent hosts "$MAIL_FQDN" >/dev/null; then
    warn "Mail FQDN does not currently resolve."
fi

ok "Mail FQDN : $MAIL_FQDN"

echo

# ==============================================================================
# Mailname
# ==============================================================================

MAILNAME="/etc/mailname"

CURRENT_DOMAIN="$(hostname -d)"

if [[ -n "$CURRENT_DOMAIN" ]]; then

    echo "$MAIL_FQDN" > "$MAILNAME"

    ok "Mailname: $MAIL_FQDN"

else

    warn "Unable to detect domain."

fi

# ==============================================================================
# Hostname Validation
# ==============================================================================

FQDN="$(hostname -f)"

SHORT="$(hostname -s)"

info "Hostname : $SHORT"
info "FQDN     : $FQDN"

if [[ "$FQDN" == "$SHORT" ]]; then

    warn "FQDN is not configured."

else

    ok "FQDN looks valid."

fi

# ==============================================================================
# Reverse DNS
# ==============================================================================

PUBLIC_IP="$(curl -4 -fsSL https://api.ipify.org || true)"

if [[ -z "$PUBLIC_IP" ]]; then
    warn "Unable to detect public IP."
else

    PTR="$(dig +short -x "$PUBLIC_IP" | head -n1)"

    PTR_HOST="${PTR%.}"

    A_IP="$(dig +short A "$PTR_HOST" | head -n1)"

    if [[ "$A_IP" == "$PUBLIC_IP" ]]; then
        ok "FCrDNS verified."
    else
        warn "PTR/A mismatch."
    fi
fi
# ==============================================================================
# Internet Connectivity
# ==============================================================================

info "Testing SMTP connectivity..."

if timeout 10 bash -c "</dev/tcp/gmail-smtp-in.l.google.com/25" \
    >/dev/null 2>&1; then

    ok "SMTP outbound connection successful."

else

    warn "Unable to reach Gmail SMTP."

fi

echo
ok "Environment validation completed."
echo

# ==============================================================================
# Configure Postfix
# ==============================================================================

info "Configuring Postfix..."

# ==============================================================================
# Backup Current Configuration
# ==============================================================================

postconf -n > "$BACKUP_DIR/$DATE/postconf.before"

# ==============================================================================
# Basic Configuration
# ==============================================================================

postconf -e "myhostname = $MAIL_FQDN"
postconf -e "mydomain = $DOMAIN"
postconf -e "myorigin = \$mydomain"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = all"
postconf -e 'smtpd_banner = $myhostname ESMTP $mail_name (Debian/GNU)'

# ==============================================================================
# Local Delivery
# ==============================================================================

postconf -e "mydestination = localhost"

postconf -e "local_recipient_maps ="

# ==============================================================================
# Relay
# ==============================================================================

postconf -e "relay_domains ="

postconf -e "relayhost ="

# ==============================================================================
# Virtual Alias
# ==============================================================================

postconf -e "virtual_alias_domains ="

postconf -e "virtual_alias_maps = hash:/etc/postfix/virtual"

# ==============================================================================
# Security
# ==============================================================================

postconf -e "disable_vrfy_command = yes"

postconf -e "strict_rfc821_envelopes = yes"

postconf -e "smtpd_helo_required = yes"

postconf -e "smtpd_delay_reject = yes"

# ==============================================================================
# TLS
# ==============================================================================

postconf -e "smtp_tls_security_level = may"

postconf -e "smtp_tls_loglevel = 1"

postconf -e "smtp_tls_note_starttls_offer = yes"

# ==============================================================================
# Limits
# ==============================================================================

postconf -e "message_size_limit = 26214400"

postconf -e "mailbox_size_limit = 0"

# ==============================================================================
# Compatibility
# ==============================================================================

postconf -e "compatibility_level = 3.6"

# ==============================================================================
# Queue Lifetime
# ==============================================================================

postconf -e "maximal_queue_lifetime = 2d"

postconf -e "bounce_queue_lifetime = 1d"

# ==============================================================================
# Performance
# ==============================================================================

postconf -e "default_process_limit = 50"

postconf -e "default_destination_concurrency_limit = 20"

postconf -e "smtp_destination_concurrency_limit = 20"

# ==============================================================================
# Aliases Database
# ==============================================================================

if [[ ! -f /etc/aliases ]]; then

    touch /etc/aliases

fi

newaliases >/dev/null 2>&1 || true

# ==============================================================================
# Virtual Database
# ==============================================================================

touch "$POSTFIX_VIRTUAL"

postmap "$POSTFIX_VIRTUAL"

# ==============================================================================
# Verify
# ==============================================================================

postconf -n > "$BACKUP_DIR/$DATE/postconf.after"

ok "Postfix configured successfully."

echo

# ==============================================================================
# Mail Forward Wizard
# ==============================================================================

info "Mail Forward Configuration"

echo

read -rp "Domain (example.com): " DOMAIN

[[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] \
    || die "Invalid domain."

echo

read -rp "Destination Email: " DESTINATION

[[ "$DESTINATION" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] \
    || die "Invalid destination email."

echo

# ==============================================================================
# Catch-All
# ==============================================================================

echo "Enable Catch-All?"

echo "  1) Yes"

echo "  2) No"

echo

read -rp "Select [1-2]: " CATCH_ALL

case "$CATCH_ALL" in

    1|y|Y|yes|YES)

        ENABLE_CATCH_ALL=true

        ok "Catch-All enabled."

    ;;

    *)

        ENABLE_CATCH_ALL=false

        ok "Catch-All disabled."

    ;;

esac

echo

ok "Domain      : $DOMAIN"
ok "Destination : $DESTINATION"

echo

# ==============================================================================
# Default Aliases
# ==============================================================================

ALIASES=(
info
support
admin
contact
webmaster
postmaster
abuse
hostmaster
)

# ==============================================================================
# Virtual Alias File
# ==============================================================================

touch "$POSTFIX_VIRTUAL"

# Remove old entries for this domain

sed -i "/@$DOMAIN[[:space:]]/d" "$POSTFIX_VIRTUAL"

# ==============================================================================
# Build Forward Rules
# ==============================================================================

info "Creating forward rules..."

for USER in "${ALIASES[@]}"
do

    printf "%-35s %s\n" \
        "${USER}@${DOMAIN}" \
        "$DESTINATION" \
        >> "$POSTFIX_VIRTUAL"

done

if [[ "$ENABLE_CATCH_ALL" == true ]]; then

    printf "%-35s %s\n" \
        "@${DOMAIN}" \
        "$DESTINATION" \
        >> "$POSTFIX_VIRTUAL"

fi

ok "Forward rules created."

echo

# ==============================================================================
# Build virtual_alias_domains Automatically
# ==============================================================================

info "Updating virtual_alias_domains..."

DOMAINS="$(
awk '
$1 !~ /^#/ && NF {
    split($1,a,"@")
    if(length(a[2]))
        print a[2]
}
' "$POSTFIX_VIRTUAL" \
| sort -u \
| paste -sd, -
)"

postconf -e "virtual_alias_domains = $DOMAINS"

ok "virtual_alias_domains updated."

echo

# ==============================================================================
# Build Database
# ==============================================================================

info "Updating virtual database..."

postmap "$POSTFIX_VIRTUAL" \
    || die "Unable to build virtual.db"

ok "virtual.db updated."

echo

# ==============================================================================
# Reload Postfix
# ==============================================================================

info "Reloading Postfix..."

systemctl reload postfix \
    || die "Unable to reload Postfix."

ok "Postfix reloaded."

echo

# ==============================================================================
# Postfix Configuration Check
# ==============================================================================

info "Checking Postfix configuration..."

postfix check \
    || die "Postfix configuration contains errors."

ok "Configuration is valid."

echo

# ==============================================================================
# Display Current Rules
# ==============================================================================

info "Configured Forward Rules"

echo "------------------------------------------------------------"

grep "@${DOMAIN}" "$POSTFIX_VIRTUAL" || true

echo "------------------------------------------------------------"

echo

# ==============================================================================
# Test Mail
# ==============================================================================

info "Sending test email..."

TEST_ALIAS="info@${DOMAIN}"

mail \
    -s "MailForward Test" \
    "$TEST_ALIAS" <<EOF
Congratulations!

Your Mail Forwarder has been configured successfully.

Source VPS:
$(hostname -f)

Forward Address:
$DESTINATION

Time:
$(date)

This message was generated automatically.
EOF

ok "Test email submitted."

echo

# ==============================================================================
# Queue Flush
# ==============================================================================

info "Flushing queue..."

postqueue -f

sleep 2

ok "Queue flushed."

echo

# ==============================================================================
# SMTP Log
# ==============================================================================

info "Latest Postfix log"

journalctl \
    -u postfix \
    -n 20 \
    --no-pager || true

echo

# ==============================================================================
# DNS Verification
# ==============================================================================

info "Verifying DNS records..."

MX_RECORDS="$(dig +short MX "$DOMAIN" 2>/dev/null || true)"

if [[ -z "$MX_RECORDS" ]]; then

    warn "No MX records found."

else

    ok "MX Records"

    echo "$MX_RECORDS"

fi

echo

# ==============================================================================
# A Record
# ==============================================================================

A_RECORDS="$(dig +short A "$DOMAIN" 2>/dev/null || true)"

if [[ -n "$A_RECORDS" ]]; then

    ok "A Record"

    echo "$A_RECORDS"

else

    warn "No A record found."

fi

echo

# ==============================================================================
# AAAA Record
# ==============================================================================

AAAA_RECORDS="$(dig +short AAAA "$DOMAIN" 2>/dev/null || true)"

if [[ -n "$AAAA_RECORDS" ]]; then

    ok "AAAA Record"

    echo "$AAAA_RECORDS"

else

    warn "No IPv6 record."

fi

echo

# ==============================================================================
# SPF
# ==============================================================================

SPF="$(dig +short TXT "$DOMAIN" | grep "v=spf1" || true)"

if [[ -n "$SPF" ]]; then

    ok "SPF Record"

    echo "$SPF"

else

    warn "SPF record not found."

fi

echo

# ==============================================================================
# DMARC
# ==============================================================================

DMARC="$(dig +short TXT "_dmarc.$DOMAIN" || true)"

if [[ -n "$DMARC" ]]; then

    ok "DMARC Record"

    echo "$DMARC"

else

    warn "DMARC record not found."

fi

echo

# ==============================================================================
# SMTP Connectivity
# ==============================================================================

info "Testing outbound SMTP..."

if timeout 10 bash -c "</dev/tcp/gmail-smtp-in.l.google.com/25" \
    >/dev/null 2>&1
then

    ok "SMTP outbound connection successful."

else

    warn "Unable to reach Gmail SMTP."

fi

echo

# ==============================================================================
# Mail Queue Status
# ==============================================================================

QUEUE="$(mailq)"

if echo "$QUEUE" | grep -q "Mail queue is empty"; then

    ok "Mail queue is empty."

else

    warn "Mail queue contains pending messages."

    echo
    echo "$QUEUE"
    echo
fi


# ==============================================================================
# Verify Virtual Database
# ==============================================================================

info "Verifying virtual alias database..."

if postmap -q "info@$DOMAIN" hash:$POSTFIX_VIRTUAL \
    >/dev/null
then

    ok "Virtual alias database is working."

else

    warn "Unable to verify virtual alias."

fi

echo

# ==============================================================================
# Service Status
# ==============================================================================

info "Checking Postfix status..."

systemctl --no-pager --full status postfix \
    | head -15

echo

# ==============================================================================
# Verification
# ==============================================================================

info "Performing final verification..."

FAILED=0
PASSED=0

check() {

    local TITLE="$1"
    shift

    if "$@" >/dev/null 2>&1; then

        ok "$TITLE"
        ((++PASSED))

    else

        warn "$TITLE"
        ((++FAILED))

    fi

}

check "Postfix Installed" command -v postconf

check "Postfix Running" systemctl is-active --quiet postfix

check "Port 25 Listening" bash -c "ss -lnt | grep -q ':25 '"

check "Virtual Database" test -f /etc/postfix/virtual.db

check "Virtual File" test -f /etc/postfix/virtual

check "Main Config" test -f /etc/postfix/main.cf

echo

# ==============================================================================
# Backup Information
# ==============================================================================

info "Backup Information"

echo

echo "Backup Location"

echo "    $BACKUP_DIR/$DATE"

echo

echo "Files"

find "$BACKUP_DIR/$DATE" -maxdepth 1 -type f

echo

# ==============================================================================
# Restore Function
# ==============================================================================

restore_backup() {

    local LAST

    LAST="$(ls -1 "$BACKUP_DIR" | tail -1)"

    [[ -z "$LAST" ]] && die "No backup found."

    info "Restoring backup..."

    cp -af "$BACKUP_DIR/$LAST/main.cf" \
        /etc/postfix/ 2>/dev/null || true

    cp -af "$BACKUP_DIR/$LAST/master.cf" \
        /etc/postfix/ 2>/dev/null || true

    cp -af "$BACKUP_DIR/$LAST/virtual" \
        /etc/postfix/ 2>/dev/null || true

    systemctl restart postfix

    ok "Backup restored."

}


# ==============================================================================
# Mail Queue
# ==============================================================================

info "Final Queue Status"

mailq

echo

# ==============================================================================
# Statistics
# ==============================================================================

TOTAL=$((PASSED + FAILED))

echo

echo "============================================================"

printf "%-25s %d\n" "Checks Passed :" "$PASSED"

printf "%-25s %d\n" "Checks Failed :" "$FAILED"

printf "%-25s %d\n" "Total Checks  :" "$TOTAL"

echo "============================================================"

echo

# ==============================================================================
# Final Recommendation
# ==============================================================================

if (( FAILED == 0 )); then

    ok "Everything looks good."

elif (( FAILED <= 2 )); then

    warn "Configuration completed with minor warnings."

else

    warn "Configuration completed but requires attention."

fi

echo

# ==============================================================================
# Configuration Summary
# ==============================================================================

info "Configuration Summary"

echo "------------------------------------------------------------"

printf "%-20s %s\n" "Domain:" "$DOMAIN"

printf "%-20s %s\n" "Forward To:" "$DESTINATION"

printf "%-20s %s\n" "Virtual Map:" "$POSTFIX_VIRTUAL"

printf "%-20s %s\n" "Host FQDN:" "$HOST_FQDN"

printf "%-20s %s\n" "Mail FQDN:" "$MAIL_FQDN"

printf "%-20s %s\n" "Postfix:" "$POSTFIX_VERSION"

echo "------------------------------------------------------------"

echo