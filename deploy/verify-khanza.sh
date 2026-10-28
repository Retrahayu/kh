#!/usr/bin/env bash
# verify-khanza.sh — re-assert every "verified" claim in the runbook against live state.
# Read-only: starts/stops nothing. Exit 1 if any claim is not reproduced.
#
#   ./verify-khanza.sh --quiet          summary only
#   EXPECT_TABLES=1188 EXPECT_PASIEN=19 ./verify-khanza.sh   # accept known drift
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
require_root

# ── claims (from the runbook; box-specific values are overridable) ──────────
EXPECT_OS_ID=${EXPECT_OS_ID:-rocky}
EXPECT_OS_VER=${EXPECT_OS_VER:-9.8}
EXPECT_MARIADB=${EXPECT_MARIADB:-11.3.2}
EXPECT_DB=${EXPECT_DB:-sik}
EXPECT_TABLES=${EXPECT_TABLES:-1188}
EXPECT_PASIEN=${EXPECT_PASIEN:-19}
EXPECT_PHP=${EXPECT_PHP:-8.5.12}
EXPECT_JAVA=${EXPECT_JAVA:-11.0.33}
EXPECT_PMA=${EXPECT_PMA:-5.2.3}
EXPECT_MANIFEST_JARS=${EXPECT_MANIFEST_JARS:-280}
EXPECT_LIB_JARS=${EXPECT_LIB_JARS:-304}
EXPECT_WS_PORT=${EXPECT_WS_PORT:-8080}
X_DISPLAY_UNDER_TEST=${X_DISPLAY_UNDER_TEST:-:99}
JAVA_HOME_EXPECT=${JAVA_HOME_EXPECT:-/usr/lib/jvm/bellsoft-java11-full.x86_64}
QUIET=${QUIET:-0}
[ "${1:-}" = "--quiet" ] && QUIET=1
# optional: pick up AES material / paths from the deployment env (never required)
# shellcheck disable=SC1090  # path comes from the environment by design
if [ -r "$KHANZA_ENV" ]; then set -a; . "$KHANZA_ENV"; set +a; fi

if [ "$QUIET" = "1" ]; then
  c_pass() { KH_PASS=$((KH_PASS+1)); }
  c_info() { KH_INFO=$((KH_INFO+1)); }
fi
sec_q() { [ "$QUIET" = "1" ] || sec "$1"; }

# ── 0. preconditions / doc integrity ────────────────────────────────────────
sec_q "0. Host, tools, doc integrity"
[ -f "$KHANZA_GUIDE" ] && c_pass "runbook present" "$KHANZA_GUIDE" || c_warn "runbook not at $KHANZA_GUIDE" "claims cannot be cross-checked"
for t in openssl unzip curl python3 ss; do
  have "$t" && c_pass "tool: $t" "$(command -v "$t")" || c_fail "tool: $t" "not installed"
done
if [ -f "$KHANZA_GUIDE" ]; then
  grep -qE 'https?://[^ )]*:8081|:8081/' "$KHANZA_GUIDE" \
    && c_fail "runbook free of the bogus :8081 URL" "still claimed" \
    || c_pass "runbook free of the bogus :8081 URL" "only the correction text mentions it"
  grep -q "all 181 manifest-referenced" "$KHANZA_GUIDE" \
    && c_fail "runbook free of the stale '181 jars' figure" "still present" \
    || c_pass "runbook free of the stale '181 jars' figure" "corrected to $EXPECT_MANIFEST_JARS"
fi

# ── 1. host ─────────────────────────────────────────────────────────────────
sec_q "1. Host"
# shellcheck disable=SC1091
. /etc/os-release
eq "OS ID = $EXPECT_OS_ID" "$EXPECT_OS_ID" "$ID"
eq "OS VERSION_ID = $EXPECT_OS_VER" "$EXPECT_OS_VER" "$VERSION_ID"
for p in /opt/simrs-khanza/source /opt/simrs-khanza/binaries "$KHANZA_CLIENT"; do
  [ -d "$p" ] && c_pass "path exists: $p" || c_fail "path exists: $p" "missing"
done
have getenforce && eq "SELinux (runbook says Disabled)" "Disabled" "$(getenforce)"
[ "$(systemctl is-active firewalld 2>/dev/null)" != "active" ] \
  && c_info "firewalld" "$(systemctl is-active firewalld 2>/dev/null)" \
  || c_warn "firewalld active" "runbook says inactive"

# ── 2. database ─────────────────────────────────────────────────────────────
sec_q "2. MariaDB + the connection the client really uses"
eq "mariadb.service active" "active" "$(systemctl is-active mariadb 2>/dev/null)"
eq "mariadb.service enabled" "enabled" "$(systemctl is-enabled mariadb 2>/dev/null)"
has "mariadb version contains $EXPECT_MARIADB" "$(mariadb --version 2>/dev/null | awk '{print $3}')" "$EXPECT_MARIADB"
for p in /usr/bin/mariadb /var/lib/mysql /etc/my.cnf.d; do
  [ -e "$p" ] && c_pass "path exists: $p" || c_fail "path exists: $p" "missing"
done

# AES material: use the deployment's own values when the env file is present
AES_KEY=${KHANZA_AES_KEY:-Bar12345Bar12345}
AES_IV=${KHANZA_AES_IV:-sayangsamakhanza}
CREDS=$(python3 - "$KHANZA_CLIENT/_pkg/app/setting/database.xml" "$AES_KEY" "$AES_IV" <<'PY'
import re,subprocess,sys
K=sys.argv[2].encode().hex(); IV=sys.argv[3].encode().hex()
txt=open(sys.argv[1],encoding='utf-8',errors='replace').read()
want=('HOST','DATABASE','PORT','USER','PAS'); out={}
for k,v in re.findall(r'<entry key="([^"]+)">([^<]*)</entry>',txt):
    if k not in want: continue
    if not v.strip(): out[k]=''; continue
    r=subprocess.run(['openssl','enc','-d','-aes-128-cbc','-K',K,'-iv',IV,'-base64','-A'],
                     input=v.encode(),capture_output=True)
    out[k]=r.stdout.decode('utf-8','replace').rstrip('\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10') if r.returncode==0 else ''
print('|'.join(out.get(k,'') for k in want))
PY
)
IFS='|' read -r DB_HOST DB_NAME DB_PORT DB_USER DB_PASS <<< "$CREDS"
[ -n "${DB_PASS:-}" ] && c_pass "client database.xml decrypts (key+IV)" "PAS $(mask "$DB_PASS")" \
                      || c_fail "client database.xml decrypts (key+IV)" "PAS empty/undecryptable"
eq "database.xml DATABASE" "$EXPECT_DB" "${DB_NAME:-}"
if mariadb -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USER" -p"$DB_PASS" -N -e "SELECT 1" >/dev/null 2>&1; then
  c_pass "TCP login as the client's DB user" "$DB_USER@$DB_HOST"
  q() { mariadb -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USER" -p"$DB_PASS" -N -e "$1" 2>/dev/null; }
  eq "table count in $EXPECT_DB" "$EXPECT_TABLES" "$(q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$EXPECT_DB'")"
  eq "charset/collation" "latin1/latin1_swedish_ci" \
     "$(q "SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$EXPECT_DB'" | tr '\t' '/')"
  P=$(q "SELECT COUNT(*) FROM $EXPECT_DB.pasien")
  [ "$P" = "$EXPECT_PASIEN" ] && c_pass "pasien row count = $EXPECT_PASIEN" "$P" \
    || c_warn "pasien row count" "expected $EXPECT_PASIEN, got ${P:-?} (live data changes)"
  case "$DB_USER" in
    root) c_warn "apps connect as DB superuser" "see SECURITY.md #4" ;;
    *)    c_pass "apps use a non-root DB user" "$DB_USER" ;;
  esac
else
  c_fail "TCP login as the client's DB user" "refused / bad credentials"
fi
if load_env 2>/dev/null; then
  A="mariadb -h 127.0.0.1 -u ${KHANZA_ADMIN_USER} -p${KHANZA_ADMIN_PASS} -N"
  AQ() { $A -e "$1" 2>/dev/null; }
  eq "no anonymous MySQL accounts" "0" "$(AQ "SELECT COUNT(*) FROM mysql.user WHERE user=''")"
  [ "$(AQ "SHOW DATABASES LIKE 'test'")" = "" ] && c_pass "'test' database dropped" || c_warn "'test' database present" "run mariadb-secure-installation"
  c_info "root@'%' still present?" "$(AQ "SELECT IF(COUNT(*)>0,'yes','no') FROM mysql.user WHERE user='root' AND host='%'")"
  BIND=$(ss -ltn 2>/dev/null | awk '$4 ~ /:3306$/ {print $4}' | tr '\n' ' ')
  case "$BIND" in *0.0.0.0:3306*|*\*:3306*) c_warn "MariaDB on all interfaces" "$BIND — harden --db-bind / SG rule";; *) c_info "MariaDB bind" "$BIND";; esac
else
  c_info "no $KHANZA_ENV" "admin-level checks skipped (install deploy/conf/khanza.env.example)"
fi

# ── 3. web stack ────────────────────────────────────────────────────────────
sec_q "3. httpd / PHP / phpMyAdmin"
eq "httpd active" "active" "$(systemctl is-active httpd 2>/dev/null)"
eq "httpd enabled" "enabled" "$(systemctl is-enabled httpd 2>/dev/null)"
eq "PHP version" "$EXPECT_PHP" "$(php -r 'echo PHP_VERSION;' 2>/dev/null)"
MODS=$(php -m 2>/dev/null | tr 'A-Z' 'a-z')
for m in mysqli pdo_mysql mbstring xml curl gd; do has "php extension: $m" "$MODS" "$m"; done
eq "phpMyAdmin version" "$EXPECT_PMA" "$(rpm -q --qf '%{VERSION}' phpMyAdmin 2>/dev/null)"
for u in /webapps/ /epasien/ /phpmyadmin/; do
  eq "HTTP 200 on $u" "200" "$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1$u")"
done

# ── 4. deploy provenance ────────────────────────────────────────────────────
sec_q "4. Deployed modules match the source tree"
D=$(diff -rq /opt/simrs-khanza/source/webapps "$KHANZA_WEBROOT/webapps" 2>&1 | grep -vc 'conf/conf.php')
eq "webapps == source (except conf.php)" "0" "$D"
D=$(diff -rq /opt/simrs-khanza/source/epasien "$KHANZA_WEBROOT/epasien" 2>&1 | grep -vc 'conf/conf.php')
eq "epasien == source (except conf.php)" "0" "$D"
c_info "webroot owner" "$(stat -c '%U:%G' "$KHANZA_WEBROOT/webapps")"

# ── 5. java ─────────────────────────────────────────────────────────────────
sec_q "5. Java"
eq "active java = BellSoft Full 11" "$JAVA_HOME_EXPECT/bin/java" "$(readlink -f "$(command -v java)")"
has "java version contains $EXPECT_JAVA" "$(java -version 2>&1 | head -1)" "$EXPECT_JAVA"
has "java vendor = BellSoft" "$(java -XshowSettings:properties -version 2>&1 | awk -F'= ' '/java.vendor =/{print $2;exit}')" "BellSoft"
FX=0; for m in base controls fxml graphics media swing web; do [ -f "$JAVA_HOME_EXPECT/jmods/javafx.$m.jmod" ] && FX=$((FX+1)); done
eq "7 JavaFX jmods present" "7" "$FX"

# ── 6. client assets ────────────────────────────────────────────────────────
sec_q "6. Client assets"
JAR="$KHANZA_CLIENT/khanza.jar"
eq "Main-Class" "simrskhanza.SIMRSKhanza" \
   "$(unzip -p "$JAR" META-INF/MANIFEST.MF 2>/dev/null | grep -i '^Main-Class:' | tr -d '\r' | awk '{print $2}')"
read -r MJ MU MM <<< "$(python3 - "$JAR" "$KHANZA_CLIENT" <<'PY'
import os,re,sys,zipfile
jar,base=sys.argv[1],sys.argv[2]
mf=zipfile.ZipFile(jar).read('META-INF/MANIFEST.MF').decode('utf-8','replace')
m=re.search(r'Class-Path:(.*?)(?:\r?\n[A-Za-z0-9-]+:)',mf,re.S)
cp=m.group(1).replace('\r','').replace('\n ','').split() if m else []
jars=[e for e in cp if e.endswith('.jar')]
print(len(jars),len(set(jars)),len([e for e in jars if not os.path.exists(os.path.join(base,e))]))
PY
)"
eq "manifest Class-Path jars" "$EXPECT_MANIFEST_JARS" "$MJ"
eq "manifest jar entries are unique" "$MJ" "$MU"
eq "manifest jars missing" "0" "$MM"
eq "client/lib jar count" "$EXPECT_LIB_JARS" "$(ls "$KHANZA_CLIENT"/lib/*.jar 2>/dev/null | wc -l)"
eq "khanza.jar has zero JavaFX references" "0" "$(unzip -l "$JAR" 2>/dev/null | grep -ci javafx)"
eq "_pkg jar hardlinked to client jar" "$(stat -c '%i' "$JAR")" "$(stat -c '%i' "$KHANZA_CLIENT/_pkg/app/khanza.jar")"

# ── 7. webswing ─────────────────────────────────────────────────────────────
sec_q "7. Webswing config + drop-in"
[ -d "$KHANZA_WS" ] && c_pass "Webswing home" "$KHANZA_WS" || c_fail "Webswing home" missing
grep -qF '"/khanza": "${webswing.dropin.dir}/khanza"' "$KHANZA_WS/webswing.config" \
  && c_pass "root /khanza is a drop-in reference" "no inline classpath" \
  || c_fail "root /khanza is a drop-in reference" "inline block — did setup_khanza.py run again?"
grep -q 'binaries' "$KHANZA_WS/webswing.config" \
  && c_fail "root config free of binaries/lib" "references the 50-jar set" \
  || c_pass "root config free of binaries/lib" "clean"
DC="$KHANZA_WS/apps/khanza/webswing.config"
if [ -f "$DC" ]; then
  TR=$(tr -d ' \n' < "$DC")
  has "drop-in classpath: khanza.jar" "$TR" '"khanza.jar"'
  has "drop-in classpath: lib/*.jar" "$TR" '"lib/*.jar"'
  has "drop-in mainClass" "$TR" '"simrskhanza.SIMRSKhanza"'
fi
eq "drop-in lib jars" "$EXPECT_LIB_JARS" "$(ls "$KHANZA_WS"/apps/khanza/app/lib/*.jar 2>/dev/null | wc -l)"
[ -f "$KHANZA_WS/apps/khanza/app/lib/UsuLibrary.jar" ] && c_pass "UsuLibrary.jar present" || c_fail "UsuLibrary.jar present" missing

# ── 8. supervision, display, ports ──────────────────────────────────────────
sec_q "8. Supervision, X display, ports"
have Xvfb && c_pass "Xvfb installed" "$(command -v Xvfb)" || c_fail "Xvfb installed" missing
rpm -q gtk3 >/dev/null 2>&1 && c_pass "gtk3 installed" "$(rpm -q gtk3)" || c_fail "gtk3 installed" missing
PIDS=$(pgrep -f "Xvfb $X_DISPLAY_UNDER_TEST" | tr '\n' ' ')
[ -n "$PIDS" ] && c_pass "Xvfb running on $X_DISPLAY_UNDER_TEST" "pid $PIDS" || c_fail "Xvfb running on $X_DISPLAY_UNDER_TEST" "not running"
for u in xvfb webswing; do
  [ -f "/etc/systemd/system/$u.service" ] && c_pass "$u.service installed" || c_fail "$u.service installed" missing
  eq "$u.service enabled" "enabled" "$(systemctl is-enabled "$u.service" 2>/dev/null || true)"
  eq "$u.service active"  "active"  "$(systemctl is-active  "$u.service" 2>/dev/null || true)"
done
if ss -ltn 2>/dev/null | grep -q ":$EXPECT_WS_PORT "; then
  c_pass "listening on :$EXPECT_WS_PORT" "yes"
  CODE=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "http://127.0.0.1:$EXPECT_WS_PORT/khanza")
  case "$CODE" in
    200|302) c_pass "/khanza reachable (200, or 302 to the login)" "$CODE" ;;
    *)       c_fail "/khanza reachable" "got $CODE" ;;
  esac
else
  c_fail "listening on :$EXPECT_WS_PORT" "nothing listening — GUI down"
fi
c_info "standalone admin port" "$(grep -i 'http.port' "$KHANZA_WS/admin/jetty.properties" 2>/dev/null | cut -d= -f2)"
c_info "admin console (app port)" "/admin via -serveradmin"

# ── 9. exposure ─────────────────────────────────────────────────────────────
sec_q "9. Exposure"
if [ -r "$KHANZA_WS/logs/audit.log" ]; then
  EXT=$(awk -F'|' '$2 ~ /LOGIN/ {ip=$6; gsub(/ /,"",ip); if (ip !~ /^(10\.|127\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|0:0:0)/) print ip}' \
        "$KHANZA_WS/logs/audit.log" | sort -u | wc -l)
  LAST=$(awk -F'|' '$2 ~ /LOGIN/ && $3 ~ /FAILED/ {print $1" <- "$6}' "$KHANZA_WS/logs/audit.log" | tail -1)
  [ "$EXT" -gt 0 ] && c_warn "public IPs reached the Webswing login" "$EXT distinct; last failed: ${LAST:-none}" \
                   || c_pass "no public IPs in the login audit" "internal only"
fi
FREE=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
ge "free disk >= 10G" 10 "${FREE:-0}"
c_info "RAM / swap" "$(free -m | awk '/Mem:/{print $2}') MB / $(free -m | awk '/Swap:/{print $2}') MB"

report
