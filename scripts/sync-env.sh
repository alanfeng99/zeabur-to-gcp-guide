#!/usr/bin/env bash
# 環境變數：Zeabur → 依對照表分類（build-app-env.py）→ Secret Manager 的 app-env；
# 加密金鑰另存 encryption-key，並比對兩邊的指紋。內容沒變就不新增版本。
#
# 兩個 secret 要先建好，app-env 要先有一個版本，含 build-app-env.py 的 KEEP 變數
# （資料庫密碼、GCS 的 S3 相容金鑰）。含 secret 的檔案只放在暫存目錄，結束就刪；
# 值從不印到螢幕。下一次部署才會生效。
set -euo pipefail
cd "$(dirname "$0")"
source ./zeabur-lib.sh
require ZEABUR_API_ID ZEABUR_ENV_ID GCP_PROJECT
umask 077
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 內容和最新版本相同就不新增版本
add_version() {
  local secret=$1 file=$2 latest wanted
  latest=$(gcloud secrets versions access latest --secret "$secret" --project "$GCP_PROJECT" 2> /dev/null | shasum -a 256 | cut -c1-16)
  wanted=$(shasum -a 256 < "$file" | cut -c1-16)
  if [ "$latest" = "$wanted" ]; then
    echo "$secret: unchanged"
  else
    gcloud secrets versions add "$secret" --project "$GCP_PROJECT" --data-file="$file" --format='value(name)' \
      | sed "s#.*/versions/#$secret: added version #"
  fi
}

step "app-env"
zeabur variable list --id "$ZEABUR_API_ID" --env-id "$ZEABUR_ENV_ID" -i=false --json > "$TMP/zeabur-env.json"
gcloud secrets versions access latest --secret app-env --project "$GCP_PROJECT" > "$TMP/current" \
  || die "app-env has no version yet: write one with POSTGRES_PASSWORD and the GCS S3_* values first"
python3 -I build-app-env.py "$TMP/zeabur-env.json" "$TMP/current" > "$TMP/app.env"
add_version app-env "$TMP/app.env"

step "encryption-key"
# 從容器取到暫存檔（不經過螢幕），再寫進 Secret Manager
zexec "$ZEABUR_API_ID" printenv ENCRYPTION_KEY | tr -d '\n' > "$TMP/encryption-key"
[ -s "$TMP/encryption-key" ] || die "ENCRYPTION_KEY is empty on Zeabur"
add_version encryption-key "$TMP/encryption-key"

# 兩邊的指紋必須相同（只印 SHA-256 的前 12 碼）
zeabur_fp=$(zexec "$ZEABUR_API_ID" sh -c 'printf %s "$ENCRYPTION_KEY" | sha256sum | cut -c1-12')
gcp_fp=$(gcloud secrets versions access latest --secret encryption-key --project "$GCP_PROJECT" | tr -d '\n' | shasum -a 256 | cut -c1-12)
# 陽性對照：空字串的 SHA-256 開頭是 e3b0c44298fc，兩邊都是空的也會「一致」
[ "$gcp_fp" != e3b0c44298fc ] || die "encryption key is empty"
[ "$zeabur_fp" = "$gcp_fp" ] || die "encryption key fingerprints differ: $zeabur_fp vs $gcp_fp"
echo "encryption key fingerprint matches: $gcp_fp"
