#!/usr/bin/env bash
# 在 VM 上以 root 執行，由 sync-db.sh 上傳並呼叫：用 dump 取代 VM 上的資料庫。
#
#   sudo bash restore-on-host.sh <dump> <counts.sql> <db-user> <db-name>
#
# VM 上的資料庫從來不是空的（每次部署都跑 migrate），所以不是直接 pg_restore，而是
# 換一個全新的資料目錄。先進 standby，讓 worker 不會在還原途中處理資料；原本的資料
# 目錄改名保留、不刪除（確認無誤後自己清掉 /srv/data/postgres-replaced-*）。
# 最後印出每張表的筆數（COUNT table|n），sync-db.sh 拿來和 Zeabur 比對。
set -euo pipefail
DUMP=$1
COUNTS_SQL=$2
DB_USER=$3
DB_NAME=$4
cd /srv/app

touch standby
docker compose stop worker api admin web
docker compose down postgres
mv /srv/data/postgres "/srv/data/postgres-replaced-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0755 /srv/data/postgres
# 新的資料目錄由 postgres image 依 POSTGRES_USER／POSTGRES_DB 建好空的資料庫
docker compose up --detach --wait postgres

docker compose exec -T postgres pg_restore -U "$DB_USER" -d "$DB_NAME" --no-owner --no-acl --exit-on-error < "$DUMP"
# 限流計數、refresh token、佇列裡的 job 都屬於舊資料
docker compose exec -T redis redis-cli FLUSHALL > /dev/null
docker compose up --detach --wait api admin web > /dev/null

psql() { docker compose exec -T postgres psql -U "$DB_USER" -d "$DB_NAME" "$@"; }
echo "server $(psql -Atc 'show server_version')"
psql -At < "$COUNTS_SQL" | sed 's/^/COUNT /'
rm -f "$DUMP" "$COUNTS_SQL"
