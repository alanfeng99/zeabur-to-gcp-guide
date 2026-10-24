#!/usr/bin/env bash
# 切換前的最後驗證，由 cutover.sh 在資料庫同步之後呼叫；任何一項不過就以非 0 結束，
# 切換會停在這裡，GCP 的 worker 不會啟動。
#
# 前兩項是通用的；第三項是專案自己的檢查，一定要補上（例如在 API 容器裡把所有加密欄位
# 實際解一次），然後刪掉那一行 die。cutover.sh 在動到 Zeabur 之前會先檢查這件事。
set -euo pipefail
cd "$(dirname "$0")"
source ./zeabur-lib.sh
require NEW_API_URL ASSETS_BUCKET FILES_KEY_QUERY GCP_PROJECT GCP_ZONE GCP_VM GCP_DB_USER GCP_DB_NAME
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

step "1. GCP API health (checks the body, not only the status code)"
body=$(curl -fsS -m 15 "$NEW_API_URL/api/health") || die "health endpoint unreachable"
grep -q '"status":"ok"' <<< "$body" || die "health: $body"
echo "ok"

step "2. every file the database refers to exists in GCS"
# 每次都重新匯出：最後一次同步前剛上傳的檔案也要算進來
Q=$(printf %s "$FILES_KEY_QUERY" | base64 | tr -d '\n')
gssh "cd /srv/app && echo $Q | base64 -d | sudo docker compose exec -T postgres psql -U $GCP_DB_USER -d $GCP_DB_NAME -At -f -" \
  | sed '/^$/d' | LC_ALL=C sort -u > "$TMP/keys.txt"
[ -s "$TMP/keys.txt" ] || die "the database query returned no keys: check FILES_KEY_QUERY"
# 一次列出整個 bucket 再比對，不逐一查詢（key 也不會被當成萬用字元）
gcloud storage ls --project "$GCP_PROJECT" "gs://$ASSETS_BUCKET/**" \
  | sed "s#^gs://$ASSETS_BUCKET/##" | LC_ALL=C sort -u > "$TMP/objects.txt"
missing=$(LC_ALL=C comm -23 "$TMP/keys.txt" "$TMP/objects.txt")
[ -z "$missing" ] || die "$(wc -l <<< "$missing" | tr -d ' ') referenced file(s) missing from GCS, e.g. $(head -1 <<< "$missing")"
echo "all $(wc -l < "$TMP/keys.txt" | tr -d ' ') referenced files present"

step "3. project-specific checks"
# 例：在 VM 的 API 容器裡跑一支解密所有加密欄位的腳本，有任何一筆失敗就 exit 1
# gssh "cd /srv/app && sudo docker compose exec -T api node scripts/verify-decrypt.js"
die "add your project's own checks here, then remove this line"
