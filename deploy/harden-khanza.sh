#!/usr/bin/env bash
# harden-khanza.sh — idempotent security mitigations (dry-run unless --apply).
#
#   ./harden-khanza.sh                 # dry-run: report what would change
#   ./harden-khanza.sh --apply         # apply anon + db-user + units
#   ./harden-khanza.sh --apply --all   # ... plus the DB bind restriction
#   ./harden-khanza.sh --db-bind       # only consider the bind-address change
#
# Each step checks current state first and reports "already satisfied" instead of redoing work.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"  # symlink-safe
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
require_root

APPLY=0 ANON=0 DBUSER=0 DBBIND=0 UNITS=0
for arg in "$@"; do
  case "$arg" in
    --apply)  APPLY=1 ;;
    --anon)   ANON=1 ;;
    --db-user) DBUSER=1 ;;
    --db-bind) DBBIND=1 ;;
    --units)  UNITS=1 ;;
    --all)    ANON=1 DBUSER=1 UNITS=1 DBBIND=1 ;;
    --help|-h) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown option: $arg (try --help)" ;;
  esac
done
# default set when no scope flags were given
if [ $((ANON+DBUSER+DBBIND+UNITS)) -eq 0 ]; then ANON=1 DBUSER=1 UNITS=1; fi

load_env
need_var KHANZA_ADMIN_PASS "$KHANZA_ADMIN_PASS"
RUN=1; [ "$APPLY" = "1" ] || RUN=0
act() { if [ "$RUN" = "1" ]; then log "APPLY: $*"; "$@"; else log "would run: $*"; fi; }
# for commands whose arguments embed a secret: log the intent, never the command
act_masked() { local desc="$1"; shift
  if [ "$RUN" = "1" ]; then log "APPLY: $desc"; "$@" >/dev/null; else log "would run: $desc"; fi
}

sql() { mariadb -h 127.0.0.1 -u "$KHANZA_ADMIN_USER" -p"$KHANZA_ADMIN_PASS" -N -e "${1:?sql() requires a query}"; }
if ! mariadb -h 127.0.0.1 -u "$KHANZA_ADMIN_USER" -p"$KHANZA_ADMIN_PASS" -N -e "SELECT 1" >/dev/null 2>&1; then
  die "cannot log in as ${KHANZA_ADMIN_USER}@127.0.0.1 — check KHANZA_ADMIN_* in $KHANZA_ENV"
fi

printf '== harden-khanza.sh (%s)\n' "$([ "$RUN" = 1 ] && echo APPLY || echo DRY-RUN)"

# ── 1. anonymous MySQL accounts ─────────────────────────────────────────────
if [ "$ANON" = "1" ]; then
  sec "1. Anonymous MySQL accounts"
  N=$(sql "SELECT COUNT(*) FROM mysql.user WHERE user=''")
  if [ "${N:-0}" = "0" ]; then
    c_pass "no anonymous accounts" "already satisfied"
  else
    c_warn "anonymous accounts present" "count=$N — a scanner can match them"
    act sql "DELETE FROM mysql.user WHERE user=''; FLUSH PRIVILEGES;"
    [ "$RUN" = "1" ] && eq "anonymous accounts removed" "0" "$(sql "SELECT COUNT(*) FROM mysql.user WHERE user=''")"
  fi
fi

# ── 2. least-privilege DB user + rendered configs ───────────────────────────
if [ "$DBUSER" = "1" ]; then
  sec "2. Least-privilege DB user (${KHANZA_DB_USER}) and one-source-of-truth configs"
  if [ "$KHANZA_DB_USER" = "root" ]; then
    c_fail "app user is not root" "set KHANZA_DB_USER in $KHANZA_ENV first"
  else
    GRANTS="SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, CREATE TEMPORARY TABLES,
            LOCK TABLES, EXECUTE, CREATE VIEW, SHOW VIEW, TRIGGER, REFERENCES"
    sql "SELECT 1 FROM mysql.user WHERE user='$KHANZA_DB_USER' AND host='%'" | grep -q 1 \
      && c_pass "user ${KHANZA_DB_USER}@'%' exists" "already satisfied" \
      || { c_warn "user ${KHANZA_DB_USER}@'%' missing" "will create with a generated-strength password";
           act_masked "create user ${KHANZA_DB_USER}@'%' with the password from $KHANZA_ENV" \
             sql "CREATE USER IF NOT EXISTS '$KHANZA_DB_USER'@'%' IDENTIFIED BY '$KHANZA_DB_PASS';"; }
    if [ "$RUN" = "1" ]; then
      # idempotent: set the password to what the env file says and scope grants to one schema
      act_masked "align ${KHANZA_DB_USER}@'%' password with $KHANZA_ENV" \
        sql "ALTER USER '$KHANZA_DB_USER'@'%' IDENTIFIED BY '$KHANZA_DB_PASS';"
      sql "GRANT $(echo "$GRANTS" | tr -s ' \n' ' ') ON \`$KHANZA_DB_NAME\`.* TO '$KHANZA_DB_USER'@'%'; FLUSH PRIVILEGES;"
      eq "schema-scoped grants only" "N" \
         "$(sql "SELECT IF(COUNT(*)=0,'N','Y') FROM mysql.user WHERE user='$KHANZA_DB_USER' AND Super_priv='Y'")"
      if mariadb -h "$KHANZA_JDBC_HOST" -P "${KHANZA_JDBC_PORT:-3306}" -u "$KHANZA_DB_USER" -p"$KHANZA_DB_PASS" -N \
           -e "SELECT COUNT(*) FROM \`$KHANZA_DB_NAME\`.pasien" >/dev/null 2>&1; then
        c_pass "new user can reach the app DB over TCP" "$KHANZA_DB_USER@$KHANZA_JDBC_HOST"
      else
        c_fail "new user can reach the app DB over TCP" "fix grants before switching configs"
      fi
    else
      log "would render: $HERE/render-config.py --apply"
    fi
    # render every consumer from the env file, then reload what consumes it
    if [ "$RUN" = "1" ]; then
      python3 "$HERE/render-config.py" --apply || die "render-config failed"
      systemctl is-active --quiet webswing.service && act systemctl restart webswing.service
      c_info "web modules pick up conf.php per request" "no restart needed"
    fi
  fi
fi

# ── 3. systemd supervision ──────────────────────────────────────────────────
if [ "$UNITS" = "1" ]; then
  sec "3. GUI supervision (xvfb + webswing)"
  for u in xvfb webswing; do
    if [ -f "/etc/systemd/system/$u.service" ]; then
      c_pass "$u.service present" "ok"
    else
      c_fail "$u.service present" "install deploy/systemd/$u.service"
    fi
  done
  act systemctl daemon-reload
  # A hand-started Xvfb (the exact cause of the original outage) holds :99 and makes
  # `systemctl start xvfb.service` fail with "Server is already active for display 99".
  if [ "$(systemctl is-active xvfb.service 2>/dev/null || true)" != "active" ]; then
    STRAY=$(pgrep -f "^Xvfb $X_DISPLAY_UNDER_TEST" | grep -vx "$$" | tr '\n' ' ')
    if [ -n "$STRAY" ]; then
      c_warn "stray Xvfb holds $X_DISPLAY_UNDER_TEST (pid $STRAY)" "stopping it so the unit can bind the display"
      # shellcheck disable=SC2086  # word-splitting the pid list is intended
      act kill $STRAY
      sleep 2
    fi
  fi
  for u in xvfb webswing; do
    [ -f "/etc/systemd/system/$u.service" ] || continue
    if [ "$(systemctl is-enabled "$u.service" 2>/dev/null || true)" = "enabled" ]; then
      c_pass "$u.service already enabled" "ok"
    else
      act systemctl enable "$u.service"
    fi
    if [ "$(systemctl is-active "$u.service" 2>/dev/null || true)" = "active" ]; then
      c_pass "$u.service already active" "ok"
    else
      act systemctl start "$u.service"
    fi
  done
  if [ "$RUN" = "1" ]; then
    eq "xvfb.service active" "active" "$(systemctl is-active xvfb.service 2>/dev/null || true)"
    # the JVM needs ~10 s to bind both ports; poll instead of racing it
    for _ in $(seq 1 40); do
      ss -ltn 2>/dev/null | grep -q ':8080 ' && break
      sleep 1
    done
    eq "webswing.service active" "active" "$(systemctl is-active webswing.service 2>/dev/null || true)"
    eq ":8080 listening" "yes" "$(ss -ltn 2>/dev/null | grep -q ':8080 ' && echo yes || echo no)"
    CODE=$(curl -s -o /dev/null -m 20 -w '%{http_code}' http://127.0.0.1:8080/khanza)
    case "$CODE" in
      200|302) c_pass "/khanza reachable (200, or 302 to the login)" "$CODE" ;;
      *)       c_fail "/khanza reachable" "got $CODE" ;;
    esac
  fi
fi

# ── 4. DB bind restriction (opt-in: breaks remote DB clients) ───────────────
if [ "$DBBIND" = "1" ]; then
  sec "4. MariaDB bind-address restriction"
  PRIV="$KHANZA_JDBC_HOST"
  if [ "$(ss -ltn 2>/dev/null | grep -c ':3306 ')" -gt 0 ] && ss -ltn 2>/dev/null | grep -q '0.0.0.0:3306'; then
    if printf '%s' "$PRIV" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      c_warn "MariaDB bound to all interfaces" "would bind 127.0.0.1,$PRIV (keeps this host's JDBC path)"
      log "note: any *external* PC connecting on the public IP:3306 will stop working"
      if [ "$RUN" = "1" ]; then
        F=$(grep -rl 'bind-address' /etc/my.cnf.d/ 2>/dev/null | head -1)
        F=${F:-/etc/my.cnf.d/khanza-bind.cnf}
        cp -a "$F" "$F.bak.$(date +%s)"
        if grep -q 'bind-address' "$F" 2>/dev/null; then
          sed -i "s/^bind-address.*/bind-address = 127.0.0.1,$PRIV/" "$F"
        else
          printf '[mysqld]\nbind-address = 127.0.0.1,%s\n' "$PRIV" >> "$F"
        fi
        act systemctl restart mariadb
        sleep 3
        eq "MariaDB restricted to loopback+private" "yes" \
           "$(ss -ltn 2>/dev/null | grep -q '0.0.0.0:3306' && echo no || echo yes)"
      fi
    else
      c_warn "KHANZA_JDBC_HOST is not an IP" "skipping bind restriction"
    fi
  else
    c_pass "MariaDB not on 0.0.0.0" "already satisfied"
  fi
fi

report
