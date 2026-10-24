#!/usr/bin/env bash
# 在 VM 上以 root 執行，由 sync-db.sh 上傳並呼叫：用 dump 取代 VM 上的資料庫。
#
#   sudo bash restore-on-host.sh <dump> <counts.sql> <db-user> <db-name>
#
# VM 上的資料庫從來不是空的（每次部署都跑 migrate），所以不是直接 pg_restore，而是
# 換一個全新的資料目錄。先進 standby，讓 worker 不會在還原途中處理資料；原本的資料
# 目錄改名保留、不刪除（確認無誤後自己清掉 /srv/data/postgres-replaced-*）。
# 最後印出每張表的筆數（COUNT table|n），sync-db.sh 拿來和 Zeabur 比對。
#
# 切換之後（cutover.sh 建立了 /srv/app/live）一律拒絕：那時再還原會用 Zeabur 的舊資料蓋掉
# 正式資料庫。真的要這麼做（例如 rollback 後重來），先自己確認、刪掉 live 標記。
set -euo pipefail
DUMP=$1
COUNTS_SQL=$2
DB_USER=$3
DB_NAME=$4
cd /srv/app
if [ -e live ]; then
  echo "refusing: /srv/app/live exists, this database is production now" >&2
  exit 1
fi

# 空間：每次還原都把舊的資料目錄改名保留，演練幾輪就會累積。資料庫在磁碟上通常是 dump 的
# 好幾倍，粗估要 dump 的 5 倍
for d in /srv/data/postgres-replaced-*; do
  if [ -e "$d" ]; then echo "kept from an earlier restore: $d ($(du -sh "$d" | cut -f1))"; fi
done
need=$(($(stat -c %s "$DUMP") * 5 / 1024))
avail=$(df -Pk /srv/data | tail -1 | awk '{print $4}')
if [ "$avail" -lt "$need" ]; then
  echo "refusing: ${avail}k free on /srv/data, want ${need}k. Delete old postgres-replaced-* directories (ask first)" >&2
  exit 1
fi

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
# 和每次部署一樣跑 migrate，schema 才會和 VM 上的程式一致。GCP 部署的版本比 Zeabur 新、
# 多了新的表時，下面的逐表筆數會對不上：代表兩邊跑的不是同一版，切換前要先對齊
docker compose run --rm migrate
docker compose up --detach --wait api admin web > /dev/null

psql() { docker compose exec -T postgres psql -U "$DB_USER" -d "$DB_NAME" "$@"; }
echo "server $(psql -Atc 'show server_version')"
psql -At < "$COUNTS_SQL" | sed 's/^/COUNT /'
rm -f "$DUMP" "$COUNTS_SQL"
