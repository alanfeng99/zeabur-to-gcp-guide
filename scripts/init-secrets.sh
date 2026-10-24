#!/usr/bin/env bash
# 第一次部署之前：給 app-env 與 encryption-key 各寫第一個版本，deploy.sh 才跑得起來。
# 在你自己的終端機執行；不要請 agent 代填，也不要把產生的值貼到任何地方。
#
#   ./init-secrets.sh        # 已經有版本的 secret 會跳過，可以重跑
#
# app-env
#   POSTGRES_PASSWORD   隨機產生，只用十六進位：直接放進 DATABASE_URL 也不用跳脫
#   S3_*（選用）        app 用 GCS 存檔案時，替 Terraform 建的 assets 服務帳號建一把 HMAC 金鑰。
#                       secret 只出現這一次，直接寫進暫存檔，不顯示
#   其他變數到 Phase 3 由 sync-env.sh 從 Zeabur 補上；這裡的 POSTGRES_PASSWORD 與 S3_* 會沿用。
# encryption-key
#   staging 用的隨機金鑰（32 bytes、base64；你的程式要別的格式就改這一行）。
#   Phase 3 的 sync-env.sh 會換成 Zeabur 上的那一把。
set -euo pipefail
cd "$(dirname "$0")"
source ./zeabur-lib.sh
require GCP_PROJECT
umask 077
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

has_version() {
  gcloud secrets versions list "$1" --project "$GCP_PROJECT" --limit 1 --format='value(name)' 2> /dev/null | grep -q .
}
add_version() {
  gcloud secrets versions add "$1" --project "$GCP_PROJECT" --data-file="$2" --format='value(name)' \
    | sed "s#.*/versions/#$1: added version #"
}

step "app-env"
if has_version app-env; then
  echo "app-env already has a version: skipped (sync-env.sh updates it in Phase 3)"
else
  echo "POSTGRES_PASSWORD=$(openssl rand -hex 24)" > "$TMP/app-env"
  read -rp "Does the app store files in GCS through the S3 API? [y/N] " use_gcs
  if [ "$use_gcs" = y ] || [ "$use_gcs" = Y ]; then
    require ASSETS_SA ASSETS_BUCKET
    gcloud storage hmac create "$ASSETS_SA" --project "$GCP_PROJECT" --format=json > "$TMP/hmac.json"
    python3 -I - "$TMP/hmac.json" "$ASSETS_BUCKET" >> "$TMP/app-env" << 'PY'
import json, sys
h = json.load(open(sys.argv[1]))
access_id = (h.get('metadata') or {}).get('accessId') or h.get('accessId')
secret = h.get('secret')
if not access_id or not secret:
    sys.exit('unexpected output from gcloud storage hmac create')
for line in ('S3_ENDPOINT=storage.googleapis.com', 'S3_PORT=443', 'S3_USE_SSL=true',
             'S3_ACCESS_KEY=' + access_id, 'S3_SECRET_KEY=' + secret, 'S3_BUCKET=' + sys.argv[2]):
    print(line)
PY
    echo "HMAC key created for $ASSETS_SA (only this service account's bucket access)"
  fi
  add_version app-env "$TMP/app-env"
fi

step "encryption-key"
if has_version encryption-key; then
  echo "encryption-key already has a version: skipped"
else
  openssl rand -base64 32 | tr -d '\n' > "$TMP/encryption-key"
  add_version encryption-key "$TMP/encryption-key"
  echo "staging key: sync-env.sh replaces it with the key from Zeabur in Phase 3"
fi
