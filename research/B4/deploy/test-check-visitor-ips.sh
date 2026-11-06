#!/usr/bin/env bash
# Tests for the #2034 host check and the main-journal drop-in. The check runs
# on the VPS, so here it is only parsed, read for write commands, and run on
# this machine to confirm it prints no address.
#   research/B4/deploy/test-check-visitor-ips.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${here}/check-visitor-ips.sh"
pass=0
ok() { echo "ok   $*"; pass=$((pass + 1)); }
fail() { echo "FAIL $*" >&2; exit 1; }

bash -n "${script}" || fail "check-visitor-ips.sh does not parse"
bash -n "${here}/remote-install.sh" && bash -n "${here}/deploy.sh" || fail "an install script does not parse"
ok "scripts parse"

# Read-only: no command that writes, restarts, deletes or edits settings.
# Comments are stripped first; the script's own words about "changes nothing" stay out of it.
code="$(sed -E 's/^[[:space:]]*#.*$//' "${script}")"
if grep -nE '(^|[[:space:];|&(])(rm|mv|cp|tee|chmod|chown|install|truncate|kill|pkill|systemctl +(start|stop|restart|reload|enable|disable|try-restart)|ufw +(enable|disable|allow|deny|delete|reload|logging)|fail2ban-client +(set|unban|reload|stop|start)|journalctl +[^|]*--(vacuum|rotate|flush)|sed +-i|sqlite3 +[^|]*(insert|update|delete|drop))([[:space:]]|$)' <<<"${code}"; then
  fail "check-visitor-ips.sh contains a command that could change the host"
fi
# Output redirection may go only to /dev/null or a file descriptor.
if grep -nE '>>?[[:space:]]*[^&[:space:]/]' <<<"${code}" | grep -vE '>&|/dev/null|<<<|>/dev/null'; then
  fail "check-visitor-ips.sh redirects output to a file"
fi
ok "check-visitor-ips.sh has no write commands"

# It prints counts and settings, never an address.
out="$(bash "${script}" 2>&1 </dev/null)" || fail "check-visitor-ips.sh exited non-zero on this machine"
if grep -qE '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9A-Fa-f]{1,4}:){3,}[0-9A-Fa-f]{1,4}' <<<"${out}"; then
  fail "check-visitor-ips.sh printed something that looks like an IP address"
fi
grep -q '== 4. Hosting provider' <<<"${out}" || fail "provider reminder missing"
ok "check-visitor-ips.sh runs and prints no address"

# The main-journal drop-in: a retention cap that changes nothing else.
conf="${here}/journald-main.conf"
grep -qx 'MaxRetentionSec=14day' "${conf}" && grep -qx 'MaxFileSec=1day' "${conf}" || fail "drop-in lacks the retention cap"
if grep -qE '^(Storage|SystemMaxUse|RuntimeMaxUse|SystemKeepFree|ForwardTo[A-Za-z]*)=' "${conf}"; then fail "drop-in changes more than retention"; fi
grep -q 'journald-main.conf' "${here}/deploy.sh" || fail "deploy.sh does not ship the drop-in"
grep -q 'journald-main.conf' "${here}/remote-install.sh" || fail "remote-install.sh does not install the drop-in"
grep -q 'show_diff "${jmain}"' "${here}/remote-install.sh" || fail "dry run does not show the drop-in diff"
ok "journald drop-in is retention-only, shipped, diffed and installed"

echo "${pass} passed"
