#!/usr/bin/env bash
# 物件儲存：在 Zeabur 的 API 容器裡跑 copy-assets.js，把 MinIO 的物件複製到 GCS
# （key 不變、可重跑）。API 容器的網路連得到 MinIO，所以在那裡跑；切換當晚要在暫停 API 之前。
#
# 先建一把只對 assets bucket 有權限的暫時 HMAC 金鑰，用完就停用並刪除：
#   gcloud storage hmac create <service-account-email> --project <gcp-project>
#   gcloud storage hmac update <access-id> --deactivate --project <gcp-project>
#   gcloud storage hmac delete <access-id> --project <gcp-project>
#
#   export DEST_ACCESS_KEY=<access-id> DEST_BUCKET=<assets-bucket>
#   read -rs DEST_SECRET_KEY; export DEST_SECRET_KEY   # 隱藏輸入，不留在 shell 歷史
#   ./sync-assets.sh
#
# 注意：金鑰會出現在 npx 與容器內 sh -c 的命令列參數，執行期間用 ps 看得到。
# 所以只用暫時金鑰，跑完立刻停用刪除。
set -euo pipefail
cd "$(dirname "$0")"
source ./zeabur-lib.sh
require ZEABUR_API_ID ZEABUR_ENV_ID
: "${DEST_ACCESS_KEY:?export DEST_ACCESS_KEY (temporary HMAC access id)}"
: "${DEST_SECRET_KEY:?export DEST_SECRET_KEY (temporary HMAC secret; read -rs it)}"
: "${DEST_BUCKET:?export DEST_BUCKET (the GCS assets bucket)}"

# 腳本以 base64 帶進容器，避開引號問題
JS=$(base64 < copy-assets.js | tr -d '\n')
out=$(zexec "$ZEABUR_API_ID" sh -c "echo $JS | base64 -d > /tmp/copy.js && DEST_ACCESS_KEY='$DEST_ACCESS_KEY' DEST_SECRET_KEY='$DEST_SECRET_KEY' DEST_BUCKET='$DEST_BUCKET' node /tmp/copy.js; rm -f /tmp/copy.js")
echo "$out"
# exec 不一定回傳容器裡的結束碼，所以看輸出的統計
grep -q '"failed":0' <<< "$out" || die "some objects were not copied"
