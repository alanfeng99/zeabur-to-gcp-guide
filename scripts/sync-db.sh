#!/usr/bin/env bash
# 資料庫：在 Zeabur 的 Postgres 容器裡 dump → 分片取回 → 驗 SHA-256 → 在 VM 上換成這份
# 資料（restore-on-host.sh：進 standby、換新的資料目錄、還原）→ 兩邊逐表筆數比對，
# 任何一張不同就以非 0 結束。可以重跑：每次都從 Zeabur 重新 dump。
#
# 目標 Postgres 用和 Zeabur 同一個 major 版本。Zeabur 市集版 Postgres 常見的資料庫名稱
# 是 zeabur、使用者是 root，以容器的環境變數為準。
set -euo pipefail
cd "$(dirname "$0")"
source ./zeabur-lib.sh
source ./fetch-file.sh
require ZEABUR_POSTGRES_ID ZEABUR_ENV_ID GCP_PROJECT GCP_ZONE GCP_VM GCP_DB_USER GCP_DB_NAME
umask 077

step "1. dump inside the Zeabur Postgres container"
INFO=$(zexec "$ZEABUR_POSTGRES_ID" sh -c 'umask 077; pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --no-owner --no-acl -f /tmp/final.dump && echo "size=$(wc -c < /tmp/final.dump) sha256=$(sha256sum /tmp/final.dump | cut -d" " -f1)"' | grep '^size=' || true)
[ -n "$INFO" ] || die "pg_dump on Zeabur returned nothing"
SIZE=$(sed -E 's/size=([0-9]+).*/\1/' <<< "$INFO")
SHA=$(sed -E 's/.*sha256=([0-9a-f]+).*/\1/' <<< "$INFO")
echo "dump: $SIZE bytes"

step "2. fetch and verify, then remove the dump from the container"
fetch_file "$ZEABUR_POSTGRES_ID" /tmp/final.dump "$SIZE" "$SHA" ./zeabur.dump
zexec "$ZEABUR_POSTGRES_ID" rm -f /tmp/final.dump

step "3. replace the database on the VM (enters standby; the previous data directory is kept)"
gscp ./zeabur.dump restore-on-host.sh counts.sql "$GCP_VM:/tmp/"
gssh "sudo bash /tmp/restore-on-host.sh /tmp/zeabur.dump /tmp/counts.sql $GCP_DB_USER $GCP_DB_NAME; status=\$?; rm -f /tmp/restore-on-host.sh; exit \$status" \
  | tee restore.log
grep '^COUNT ' restore.log | sed 's/^COUNT //' | sort > gcp-counts.txt || true

step "4. row count of every table on Zeabur"
Q=$(base64 < counts.sql | tr -d '\n')
zexec "$ZEABUR_POSTGRES_ID" sh -c "echo $Q | base64 -d | psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -At -f -" \
  | grep '|' | sort > zeabur-counts.txt || true

# 陽性對照：一邊沒拿到資料時，兩個空檔案也會「相同」
[ -s zeabur-counts.txt ] || die "no row counts came back from Zeabur"
[ -s gcp-counts.txt ] || die "no row counts came back from the VM (see restore.log)"
diff zeabur-counts.txt gcp-counts.txt || die "row counts differ"
echo "every table matches ($(wc -l < gcp-counts.txt | tr -d ' ') tables)"
