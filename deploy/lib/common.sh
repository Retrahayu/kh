# shellcheck shell=bash
# Shared helpers for the Khanza deploy scripts. Source it, never execute it:
#   . "$(dirname "$0")/lib/common.sh"
[ -n "${KHANZA_LIB_LOADED:-}" ] && return 0
KHANZA_LIB_LOADED=1

# ── paths (override via env; khanza.env can set them too) ───────────────────
: "${KHANZA_ENV:=/etc/khanza/khanza.env}"
: "${KHANZA_WEBROOT:=/var/www/html}"
: "${KHANZA_CLIENT:=/opt/simrs-khanza/client}"
: "${KHANZA_WS:=/opt/webswing/webswing-eval-26.2}"
: "${KHANZA_BACKUP_DIR:=/var/backups/khanza}"
: "${KHANZA_GUIDE:=/root/SIMRS-Khanza-Deployment-Guide.md}"
: "${X_DISPLAY_UNDER_TEST:=:99}"

# ── logging ─────────────────────────────────────────────────────────────────
log()   { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
warn()  { log "warn: $*"; }
die()   { log "error: $*"; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }
require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root"; }

# Print a credential-ish value without leaking it.
mask() {
  local v="${1:-}"
  if   [ -z "$v" ];        then printf '<empty>'
  elif [ "${#v}" -lt 4 ];  then printf '<set:%d>' "${#v}"
  else                          printf '<set:%d chars>' "${#v}"
  fi
}

# ── env file ────────────────────────────────────────────────────────────────
load_env() {
  [ -r "$KHANZA_ENV" ] || die "no env file at $KHANZA_ENV (install deploy/conf/khanza.env.example)"
  set -a
  # shellcheck disable=SC1090  # path is intentionally dynamic
  . "$KHANZA_ENV"
  set +a
}
need_var() {
  local name="${1:-}" value="${2:-}"
  [ -n "$value" ] || die "$name is not set in $KHANZA_ENV"
}

# ── assertions + report ─────────────────────────────────────────────────────
KH_PASS=0 KH_FAIL=0 KH_WARN=0 KH_INFO=0
if [ -t 1 ]; then
  C_PASS=$'\033[32m'; C_FAIL=$'\033[31m'; C_WARN=$'\033[33m'; C_INFO=$'\033[36m'; C_OFF=$'\033[0m'
else
  C_PASS='' C_FAIL='' C_WARN='' C_INFO='' C_OFF=''
fi
c_pass() { KH_PASS=$((KH_PASS+1)); printf '  %s[PASS]%s %-46s %s\n' "$C_PASS" "$C_OFF" "$1" "${2:-}"; }
c_fail() { KH_FAIL=$((KH_FAIL+1)); printf '  %s[FAIL]%s %-46s %s\n' "$C_FAIL" "$C_OFF" "$1" "${2:-}"; }
c_warn() { KH_WARN=$((KH_WARN+1)); printf '  %s[WARN]%s %-46s %s\n' "$C_WARN" "$C_OFF" "$1" "${2:-}"; }
c_info() { KH_INFO=$((KH_INFO+1)); printf '  %s[INFO]%s %-46s %s\n' "$C_INFO" "$C_OFF" "$1" "${2:-}"; }
sec()    { printf '\n== %s\n' "$1"; }

eq()     { if [ "$2" = "$3" ]; then c_pass "$1" "$3"; else c_fail "$1" "expected '$2', got '$3'"; fi; }
has()    { case "$2" in *"$3"*) c_pass "$1" "found '$3'";; *) c_fail "$1" "missing '$3'";; esac; }
ge()     { if [ "${3:-0}" -ge "$2" ] 2>/dev/null; then c_pass "$1" "$3"; else c_fail "$1" "expected >= $2, got ${3:-?}"; fi; }

report() {
  printf '\n%s\n' "----------------------------------------------------------------"
  printf '%s — %s\n' "${0##*/}" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf 'PASS %d   FAIL %d   WARN %d   INFO %d\n' "$KH_PASS" "$KH_FAIL" "$KH_WARN" "$KH_INFO"
  if [ "$KH_FAIL" -gt 0 ]; then
    printf 'RESULT: %d check(s) failed.\n' "$KH_FAIL"
    return 1
  fi
  printf 'RESULT: all checks passed (WARN = drift/risk note, not a failure).\n'
  return 0
}
