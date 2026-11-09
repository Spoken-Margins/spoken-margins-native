#!/usr/bin/env bash
# Read-only check that the VPS keeps no visitor IP addresses (#2034).
# Run from the Mac, as root or as a user with passwordless sudo:
#
#   ssh root@<vps> 'bash -s' < research/B4/deploy/check-visitor-ips.sh
#
# (use `ssh -i "$SM_SSH_KEY" -o IdentitiesOnly=yes ...` if deploy.sh needs the key)
#
# It changes nothing on the host. It prints settings and COUNTS only, never an
# address, a log line or a ban list. Where a command needs root and sudo asks
# for a password it prints "needs sudo" and goes on.
# Item 4 of the issue (the provider) has no command: see the last section.
set -uo pipefail
IFS=$'\n\t'

retention_days=14
v4='([0-9]{1,3}\.){3}[0-9]{1,3}'
v6='([0-9A-Fa-f]{1,4}:){3,}[0-9A-Fa-f]{1,4}'

section() { printf '\n== %s\n' "$*"; }
say() { printf '   %s\n' "$*"; }

# priv CMD...: run as root (directly, or through sudo -n). Returns 99 when
# neither is possible.
if [[ "$(id -u)" == 0 ]]; then
  priv() { "$@"; }
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  priv() { sudo -n "$@"; }
else
  priv() { return 99; }
fi
priv true 2>/dev/null || say "note: not root and no passwordless sudo; root-only checks print 'needs sudo'"

# count_matches PATTERN: number of non-loopback matches read from stdin.
count_matches() {
  local n
  n="$(grep -Eo "$1" | grep -vc -e '^127\.' -e '^::1$')" || true
  echo "${n:-0}"
}
# journal_counts LABEL JOURNALCTL_ARGS...: IPv4/IPv6-looking strings in the window.
journal_counts() {
  local label="$1" a b
  shift
  if ! priv journalctl "$@" --since "-${retention_days} days" -o cat --no-pager -q >/dev/null 2>&1; then
    say "${label}: needs sudo (or no such journal)"
    return
  fi
  a="$(priv journalctl "$@" --since "-${retention_days} days" -o cat --no-pager -q 2>/dev/null | count_matches "${v4}")"
  b="$(priv journalctl "$@" --since "-${retention_days} days" -o cat --no-pager -q 2>/dev/null | count_matches "${v6}")"
  say "${label}: IPv4-looking ${a}, IPv6-looking ${b} (last ${retention_days} days, loopback excluded)"
}
# file_info PATH: whether it exists, its size in bytes and its age.
file_info() {
  if [[ -e "$1" ]]; then
    say "$1: exists, $(stat -c %s "$1" 2>/dev/null || echo '?') bytes, last written $(date -d "@$(stat -c %Y "$1" 2>/dev/null || echo 0)" +%F 2>/dev/null || echo '?')"
  else
    say "$1: absent"
  fi
}
# file_ip_count PATH: IPv4-looking strings in a root-only log file.
file_ip_count() {
  [[ -e "$1" ]] || return 0
  if priv test -r "$1" 2>/dev/null; then
    say "$1: $(priv cat "$1" 2>/dev/null | count_matches "${v4}") IPv4-looking strings"
  else
    say "$1: needs sudo"
  fi
}

section "1. journald (does the journal keep addresses, and for how long)"
if command -v journalctl >/dev/null 2>&1; then
  say "disk usage: $(priv journalctl --disk-usage 2>/dev/null || journalctl --disk-usage 2>/dev/null || echo 'needs sudo')"
  say "effective journald.conf settings (non-comment lines of systemd-analyze cat-config):"
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -vE '^[[:space:]]*(#|\[|$)' | sed 's/^/      /'
  else
    say "systemd-analyze missing"
  fi
  if [[ -f /etc/systemd/journald.conf.d/50-spokenmargins.conf ]]; then
    say "main-journal retention drop-in 50-spokenmargins.conf: installed"
  else
    say "main-journal retention drop-in 50-spokenmargins.conf: NOT installed (distro defaults apply)"
  fi
  oldest="$(priv journalctl -o json --output-fields=MESSAGE_ID --no-pager -q 2>/dev/null | head -1 | sed -n 's/.*"__REALTIME_TIMESTAMP" *: *"\([0-9]*\)".*/\1/p')"
  if [[ -n "${oldest}" ]]; then
    say "oldest entry in the main journal: $(date -u -d "@$((oldest / 1000000))" +%F)"
  else
    say "oldest entry in the main journal: needs sudo (or the journal is empty)"
  fi
  journal_counts "caddy journal" -u caddy
  journal_counts "smserver journal" --namespace=smserver
  journal_counts "sshd journal" -u ssh -u sshd
else
  say "journalctl not found"
fi

section "2. Firewall (ufw / iptables / nft)"
if command -v ufw >/dev/null 2>&1; then
  if out="$(priv ufw status verbose 2>/dev/null)"; then
    grep -E '^(Status|Logging|Default):' <<<"${out}" | sed 's/^/   /'
  else
    say "ufw status: needs sudo"
  fi
else
  say "ufw: not installed"
fi
if command -v journalctl >/dev/null 2>&1; then
  if priv journalctl -k --since "-${retention_days} days" --no-pager -q >/dev/null 2>&1; then
    say "kernel journal, last ${retention_days} days: UFW BLOCK lines $(priv journalctl -k --since "-${retention_days} days" --no-pager -q -o cat 2>/dev/null | grep -c 'UFW BLOCK' || true), lines with SRC= $(priv journalctl -k --since "-${retention_days} days" --no-pager -q -o cat 2>/dev/null | grep -c 'SRC=' || true)"
  else
    say "kernel journal: needs sudo"
  fi
fi
for f in /var/log/ufw.log /var/log/kern.log; do
  file_info "${f}"
  if [[ -e "${f}" ]]; then
    if priv test -r "${f}" 2>/dev/null; then
      say "${f}: UFW BLOCK lines $(priv grep -c 'UFW BLOCK' "${f}" 2>/dev/null || true), lines with SRC= $(priv grep -c 'SRC=' "${f}" 2>/dev/null || true)"
    else
      say "${f}: needs sudo to count"
    fi
  fi
done
if command -v iptables-save >/dev/null 2>&1; then
  if out="$(priv iptables-save 2>/dev/null)"; then say "iptables LOG rules: $(grep -c -e '-j LOG' <<<"${out}" || true)"; else say "iptables-save: needs sudo"; fi
else
  say "iptables-save: not installed"
fi
if command -v nft >/dev/null 2>&1; then
  if out="$(priv nft list ruleset 2>/dev/null)"; then say "nft rules with log: $(grep -cE '(^|[[:space:]])log([[:space:]]|$)' <<<"${out}" || true)"; else say "nft ruleset: needs sudo"; fi
else
  say "nft: not installed"
fi

section "3. fail2ban, sshd and other places addresses can be kept"
if command -v fail2ban-client >/dev/null 2>&1 || [[ -d /etc/fail2ban ]]; then
  say "fail2ban: installed, service $(systemctl is-active fail2ban 2>/dev/null || echo unknown)"
  if out="$(priv fail2ban-client status 2>/dev/null)"; then
    grep -E 'Number of jail|Jail list' <<<"${out}" | sed 's/^[[:space:]|`-]*/   /'
  else
    say "fail2ban-client status: needs sudo (or not running)"
  fi
  db=/var/lib/fail2ban/fail2ban.sqlite3
  file_info "${db}"
  if [[ -e "${db}" ]]; then
    if command -v sqlite3 >/dev/null 2>&1; then
      say "fail2ban database bans rows: $(priv sqlite3 -readonly "${db}" 'select count(*) from bans' 2>/dev/null || echo 'needs sudo')"
    else
      say "fail2ban database bans rows: sqlite3 not installed on the host, not counted"
    fi
  fi
  say "fail2ban dbpurgeage: $(priv fail2ban-client get dbpurgeage 2>/dev/null || priv grep -rhE '^[[:space:]]*dbpurgeage' /etc/fail2ban/fail2ban.conf /etc/fail2ban/fail2ban.d 2>/dev/null | tail -1 || echo 'needs sudo (default is 1d)')"
else
  say "fail2ban: not installed"
fi
if command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]]; then
  say "sshd LogLevel: $(priv /usr/sbin/sshd -T 2>/dev/null | grep -i '^loglevel' || echo 'needs sudo')"
fi
say "the next files hold the owner's and internet scanners' addresses from ssh logins, not app visitors':"
for f in /var/log/auth.log /var/log/secure /var/log/btmp /var/log/wtmp /var/log/lastlog; do file_info "${f}"; done
file_ip_count /var/log/auth.log
say "rsyslog: $(systemctl is-active rsyslog 2>/dev/null || echo 'not running')"
fwd="$(grep -rhE '^[[:space:]]*[^#[:space:]].*(@@?[A-Za-z0-9\[]|omfwd)' /etc/rsyslog.conf /etc/rsyslog.d 2>/dev/null | wc -l | tr -d ' ')"
say "rsyslog forwarding rules (lines naming a remote target): ${fwd}"
say "auditd: $(systemctl is-active auditd 2>/dev/null || echo 'not running')"
if command -v auditctl >/dev/null 2>&1; then
  say "audit rules loaded: $(priv auditctl -l 2>/dev/null | grep -vc 'No rules' || echo 'needs sudo')"
fi
say "listeners on ports 80 and 443 (port and process only):"
if command -v ss >/dev/null 2>&1; then
  ss -ltnpH '( sport = :80 or sport = :443 )' 2>/dev/null |
    awk '{n=split($4, a, ":"); p="(process hidden)"; if ($NF ~ /^users:/) { p=$NF; sub(/^users:\(\(/, "", p) }; print "      port " a[n] "  " p}' |
    sort -u
  [[ -n "$(ss -ltnH '( sport = :80 or sport = :443 )' 2>/dev/null)" ]] || say "none seen"
  say "(process names show only with root; Caddy should be the only one)"
else
  say "ss not installed"
fi

section "4. Hosting provider"
say "Nothing to run. Open the provider's console and check, by hand: flow or traffic"
say "logs, DDoS-protection logs, any 'network monitoring' or snapshot/backup add-on,"
say "and how long the provider keeps connection logs (their privacy terms)."

printf '\nDone. Nothing on this host was changed.\n'
