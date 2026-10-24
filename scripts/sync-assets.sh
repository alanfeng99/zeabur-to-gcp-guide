#!/usr/bin/env bash
# 物件儲存：在 Zeabur 的 API 容器裡跑 copy-assets.js，把 MinIO 的物件複製到 GCS
# （key 不變、可重跑）。API 容器的網路連得到 MinIO，所以在那裡跑；切換當晚要在暫停 API 之前。
#
#   ./sync-assets.sh --create-key   替 assets 服務帳號建一把暫時 HMAC 金鑰，存進 $WORK/dest-hmac.json
#   ./sync-assets.sh                複製（可重跑）
#   ./sync-assets.sh --delete-key   停用並刪除那把金鑰（切換完成後）
#
# 金鑰的 secret 只寫進權限 600 的檔案，不顯示，所以 agent 可以代跑。assets 服務帳號只對
# assets bucket 有權限。注意：複製期間金鑰會出現在 npx 與容器內 sh -c 的命令列參數，用 ps
# 看得到，所以只用暫時金鑰，切換後立刻刪除。
set -euo pipefail
cd "$(dirname "$0")"
source ./zeabur-lib.sh
require GCP_PROJECT ASSETS_SA ASSETS_BUCKET
KEYFILE="$WORK/dest-hmac.json"
umask 077
# 從 gcloud storage hmac create 的輸出讀一個欄位（accessId 在 metadata 裡，secret 在最上層）
field() {
  python3 -I -c 'import json, sys; h = json.load(open(sys.argv[1])); print((h.get("metadata") or {}).get(sys.argv[2]) or h.get(sys.argv[2]) or "")' "$KEYFILE" "$1"
}

case "${1:-}" in
  --create-key)
    work_dir
    [ ! -e "$KEYFILE" ] || die "$KEYFILE already exists: use it, or remove it with --delete-key first"
    gcloud storage hmac create "$ASSETS_SA" --project "$GCP_PROJECT" --format=json > "$KEYFILE"
    [ -n "$(field secret)" ] || { rm -f "$KEYFILE"; die "unexpected output from gcloud storage hmac create"; }
    echo "temporary HMAC key $(field accessId) created for $ASSETS_SA (secret kept in $KEYFILE)"
    exit 0
    ;;
  --delete-key)
    [ -s "$KEYFILE" ] || die "no $KEYFILE: nothing to delete"
    id=$(field accessId)
    gcloud storage hmac update "$id" --deactivate --project "$GCP_PROJECT" > /dev/null
    gcloud storage hmac delete "$id" --project "$GCP_PROJECT"
    rm -f "$KEYFILE"
    echo "temporary HMAC key $id deleted"
    exit 0
    ;;
  '') ;;
  *) die "usage: sync-assets.sh [--create-key | --delete-key]" ;;
esac

require ZEABUR_API_ID ZEABUR_ENV_ID
[ -s "$KEYFILE" ] || die "no temporary key: run ./sync-assets.sh --create-key first"
DEST_ACCESS_KEY=$(field accessId)
DEST_SECRET_KEY=$(field secret)

# 腳本以 base64 帶進容器，避開引號問題
JS=$(base64 < copy-assets.js | tr -d '\n')
out=$(zexec "$ZEABUR_API_ID" sh -c "echo $JS | base64 -d > /tmp/copy.js && DEST_ACCESS_KEY='$DEST_ACCESS_KEY' DEST_SECRET_KEY='$DEST_SECRET_KEY' DEST_BUCKET='$ASSETS_BUCKET' node /tmp/copy.js; rm -f /tmp/copy.js")
echo "$out"
# exec 不一定回傳容器裡的結束碼，所以看輸出的統計
grep -q '"failed":0' <<< "$out" || die "some objects were not copied"
