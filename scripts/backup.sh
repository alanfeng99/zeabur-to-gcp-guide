#!/usr/bin/env bash
# 每晚由 db-backup.timer 執行：pg_dump（custom format）上傳到備份 bucket。
# 放在 VM 的 /srv/app。VM 的服務帳號對這個 bucket 只有「建立物件」權限，
# 不能覆寫、不能刪除舊備份（防勒索）；bucket 用 lifecycle 規則自動過期。
set -euo pipefail
cd "$(dirname "$0")"

# 和 compose.yaml 的 POSTGRES_USER／POSTGRES_DB 相同（範本是 app／app）
DB_USER=app
DB_NAME=app

METADATA=http://metadata.google.internal/computeMetadata/v1
PROJECT=$(curl -fsS -H 'Metadata-Flavor: Google' "$METADATA/project/project-id")
BUCKET="$PROJECT-backups"
NAME="postgres/db-$(date -u +%Y%m%dT%H%M%SZ).dump"

# 先 dump 成完整的本機檔再上傳：直接串流到 bucket，dump 中途失敗會留下截斷的物件，
# 而 VM 沒有權限刪掉它
TMP=$(mktemp /srv/data/backup.XXXXXX)
trap 'rm -f "$TMP"' EXIT
docker compose exec -T postgres pg_dump -U "$DB_USER" -d "$DB_NAME" --format=custom > "$TMP"

# 用 GCS JSON API 上傳：gcloud storage cp 會讀物件中繼資料，需要的權限比「只能建立」多。
# ifGenerationMatch=0：只建立新物件，絕不覆蓋
TOKEN=$(curl -fsS -H 'Metadata-Flavor: Google' "$METADATA/instance/service-accounts/default/token" \
  | sed -E 's/.*"access_token":"([^"]+)".*/\1/')
# token 從 stdin 給 curl，不放在命令列參數（ps 看得到）
printf 'Authorization: Bearer %s\n' "$TOKEN" | curl -fsS -o /dev/null -X POST --upload-file "$TMP" \
  -H @- \
  -H "Content-Type: application/octet-stream" \
  "https://storage.googleapis.com/upload/storage/v1/b/$BUCKET/o?uploadType=media&ifGenerationMatch=0&name=${NAME//\//%2F}"
echo "backup written to gs://$BUCKET/$NAME ($(stat -c %s "$TMP") bytes)"
