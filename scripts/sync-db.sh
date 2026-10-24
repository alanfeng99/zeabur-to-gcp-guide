#!/usr/bin/env bash
# 資料庫：在 Zeabur 的 Postgres 容器裡 dump → 分片取回 → 驗 SHA-256 → 在 VM 上換成這份
# 資料（restore-on-host.sh：進 standby、換新的資料目錄、還原）→ 兩邊逐表筆數比對，
# 任何一張不同就以非 0 結束。可以重跑：每次都從 Zeabur 重新 dump。
#
# 切換之後 VM 上有 /srv/app/live 標記，restore-on-host.sh 會拒絕：這時再跑會用 Zeabur 的舊資料
# 蓋掉正式資料庫。
#
# dump、比對結果與還原紀錄放在 $WORK（預設 ~/.zeabur-to-gcp-work），不放在專案目錄：
# 裡面是正式環境的個資。切換當晚最後一次的 zeabur.dump 就是最後封存要用的那一份。
# 目標 Postgres 用和 Zeabur 同一個 major 版本；Zeabur 這一邊的使用者與資料庫從容器的環境變數讀。
#
#   ./sync-db.sh               dump → 取回 → 還原到 VM → 比對
#   ./sync-db.sh --dump-only   只 dump 並取回到 $WORK/zeabur.dump（Phase 0 的備份；還沒有 VM 也能跑）
set -euo pipefail
cd "$(dirname "$0")"
source ./zeabur-lib.sh
source ./fetch-file.sh
DUMP_ONLY=
[ "${1:-}" = --dump-only ] && DUMP_ONLY=1
require ZEABUR_POSTGRES_ID ZEABUR_ENV_ID
[ -n "$DUMP_ONLY" ] || require GCP_PROJECT GCP_ZONE GCP_VM GCP_DB_USER GCP_DB_NAME
umask 077
work_dir

step "1. dump inside the Zeabur Postgres container"
# 中途失敗也要刪掉容器裡的 dump：裡面是正式環境的個資
trap 'zexec "$ZEABUR_POSTGRES_ID" rm -f /tmp/final.dump > /dev/null 2>&1 || true' EXIT
# 容器的 /tmp 要放得下：以資料庫大小估（custom format 有壓縮，實際的 dump 通常小很多）
OUT=$(zexec "$ZEABUR_POSTGRES_ID" sh -c 'umask 077; need=$(psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "select pg_database_size(current_database()) / 1024"); avail=$(df -Pk /tmp | tail -1 | tr -s " " | cut -d" " -f4); if [ "$avail" -le "${need:-0}" ]; then echo "nospace ${avail}k free, database ${need}k"; exit 0; fi; pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --no-owner --no-acl -f /tmp/final.dump && echo "size=$(wc -c < /tmp/final.dump) sha256=$(sha256sum /tmp/final.dump | cut -d" " -f1)"' || true)
! grep -q '^nospace' <<< "$OUT" || die "not enough room in /tmp of the Zeabur Postgres container: $(grep '^nospace' <<< "$OUT")"
INFO=$(grep '^size=' <<< "$OUT" || true)
[ -n "$INFO" ] || die "pg_dump on Zeabur returned nothing"
SIZE=$(sed -E 's/size=([0-9]+).*/\1/' <<< "$INFO")
SHA=$(sed -E 's/.*sha256=([0-9a-f]+).*/\1/' <<< "$INFO")
echo "dump: $SIZE bytes"

step "2. fetch and verify, then remove the dump from the container"
fetch_file "$ZEABUR_POSTGRES_ID" /tmp/final.dump "$SIZE" "$SHA" "$WORK/zeabur.dump"
zexec "$ZEABUR_POSTGRES_ID" rm -f /tmp/final.dump
trap - EXIT
if [ -n "$DUMP_ONLY" ]; then
  echo "saved $WORK/zeabur.dump: $(pg_restore -l "$WORK/zeabur.dump" | grep -c ' TABLE DATA ') tables with data (not restored anywhere)"
  exit 0
fi

step "3. replace the database on the VM (enters standby; the previous data directory is kept)"
gscp "$WORK/zeabur.dump" restore-on-host.sh counts.sql "$GCP_VM:/tmp/"
gssh "sudo bash /tmp/restore-on-host.sh /tmp/zeabur.dump /tmp/counts.sql $GCP_DB_USER $GCP_DB_NAME; status=\$?; rm -f /tmp/restore-on-host.sh /tmp/zeabur.dump /tmp/counts.sql; exit \$status" \
  | tee "$WORK/restore.log"
grep '^COUNT ' "$WORK/restore.log" | sed 's/^COUNT //' | sort > "$WORK/gcp-counts.txt" || true

step "4. row count of every table on Zeabur"
Q=$(base64 < counts.sql | tr -d '\n')
zexec "$ZEABUR_POSTGRES_ID" sh -c "echo $Q | base64 -d | psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -At -f -" \
  | grep '|' | sort > "$WORK/zeabur-counts.txt" || true

# 陽性對照：一邊沒拿到資料時，兩個空檔案也會「相同」
[ -s "$WORK/zeabur-counts.txt" ] || die "no row counts came back from Zeabur"
[ -s "$WORK/gcp-counts.txt" ] || die "no row counts came back from the VM (see $WORK/restore.log)"
diff "$WORK/zeabur-counts.txt" "$WORK/gcp-counts.txt" || die "row counts differ"
echo "every table matches ($(wc -l < "$WORK/gcp-counts.txt" | tr -d ' ') tables)"
