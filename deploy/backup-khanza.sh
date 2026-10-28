#!/usr/bin/env bash
# backup-khanza.sh — DB dump + config/unit snapshot + SHA-256 manifest, with retention.
#   ./backup-khanza.sh [--keep N] [--out DIR] [--no-db]
# Restore: see the footer it prints (mysqldump gzip → mysql; tar → /).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
require_root
load_env

KEEP=7 OUT="$KHANZA_BACKUP_DIR" DO_DB=1
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP="$2"; shift 2 ;;
    --out)  OUT="$2";  shift 2 ;;
    --no-db) DO_DB=0;  shift ;;
    *) die "unknown option: $1" ;;
  esac
done

mkdir -p "$OUT"; chmod 700 "$OUT"
STAMP=$(date +%Y%m%d-%H%M)
DB_OUT="$OUT/${KHANZA_DB_NAME}-$STAMP.sql.gz"
CFG_OUT="$OUT/configs-$STAMP.tar.gz"

if [ "$DO_DB" = "1" ]; then
  log "dumping ${KHANZA_DB_NAME}…"
  # try the admin account first, fall back to the app account
  if mariadb-dump --single-transaction --routines --triggers --events \
       -h 127.0.0.1 -u "$KHANZA_ADMIN_USER" -p"$KHANZA_ADMIN_PASS" "$KHANZA_DB_NAME" 2>/dev/null | gzip -9 > "$DB_OUT"; then
    :
  else
    log "admin creds failed, using the app account"
    mariadb-dump --single-transaction --routines --triggers -h "$KHANZA_JDBC_HOST" \
      -u "$KHANZA_DB_USER" -p"$KHANZA_DB_PASS" "$KHANZA_DB_NAME" | gzip -9 > "$DB_OUT" \
      || die "mysqldump failed"
  fi
  log "db dump: $(du -h "$DB_OUT" | cut -f1)"
fi

log "snapshotting configs and units…"
SNAP_LIST=$(mktemp)
trap 'rm -f "$SNAP_LIST"' EXIT
for f in /etc/systemd/system/xvfb.service /etc/systemd/system/webswing.service \
         "$KHANZA_WEBROOT/webapps/conf/conf.php" "$KHANZA_WEBROOT/epasien/conf/conf.php" \
         "$KHANZA_CLIENT/setting/database.xml" "$KHANZA_WS/webswing.config"; do
  [ -f "$f" ] && printf '%s\n' "$f" >> "$SNAP_LIST"
done
[ -s "$SNAP_LIST" ] || die "nothing to snapshot — check KHANZA_* paths"
tar czf "$CFG_OUT" -T "$SNAP_LIST"          # absolute paths; restore with -C /
if [ -f /etc/khanza/khanza.env ]; then
  tar czf "$OUT/env-$STAMP.tar.gz" -C /etc/khanza khanza.env
  chmod 600 "$OUT/env-$STAMP.tar.gz"
fi

( cd "$OUT" && sha256sum ./*"$STAMP"* > "MANIFEST-$STAMP.sha256" )
log "manifest: $OUT/MANIFEST-$STAMP.sha256"

# retention
ls -1t "$OUT"/"${KHANZA_DB_NAME}"-*.sql.gz 2>/dev/null | tail -n "+$((KEEP+1))" | while read -r f; do
  log "pruning $f"; rm -f "$f"
done

cat <<EOF

Restore:
  gunzip -c $DB_OUT | mariadb -h 127.0.0.1 -u <admin> -p '$KHANZA_DB_NAME'
  tar xzf $CFG_OUT -C /           # units + conf.php + database.xml + webswing.config
  systemctl daemon-reload && systemctl restart webswing.service

Files kept in $OUT (retention: $KEEP dumps):
$(ls -1 "$OUT" | sed 's/^/  /')
EOF
