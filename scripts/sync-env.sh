#!/usr/bin/env bash
# 環境變數：Zeabur 上每個 app 服務（ENV_SERVICE_IDS）的變數 → 依對照表分類並合併
# （build-app-env.py）→ Secret Manager 的 app-env；加密金鑰換成 Zeabur 上的那一把，並比對兩邊的指紋。
# 內容沒變就不新增版本。
#
# 先跑過 init-secrets.sh（app-env 要有第一個版本，含 POSTGRES_PASSWORD）。
# 含 secret 的檔案只放在暫存目錄，結束就刪；值從不印到螢幕。
#
#   ./sync-env.sh          standby 期間：build-app-env.py 的 HOLD（會對外發訊息的憑證）不放正式值
#   ./sync-env.sh --live   切換前：HOLD 也換成 Zeabur 上的正式值（cutover.sh 會檢查）
#
# 寫進 Secret Manager 之後，VM 要重新部署才會讀到：
#   release.sh --deploy-only <目前的 tag>
# cutover.sh 開始前會檢查這一點。
set -euo pipefail
cd "$(dirname "$0")"
source ./zeabur-lib.sh
require ZEABUR_ENV_ID GCP_PROJECT
[ -n "$ENV_SERVICE_IDS" ] || die "ENV_SERVICE_IDS is empty in zeabur-lib.sh"
for id in $ENV_SERVICE_IDS; do
  case "$id" in '<'*) die "ENV_SERVICE_IDS still has a placeholder: fill in the service IDs (or drop the ones you don't have)" ;; esac
done
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
files=()
for id in $ENV_SERVICE_IDS; do
  zeabur variable list --id "$id" --env-id "$ZEABUR_ENV_ID" -i=false --json > "$TMP/zeabur-$id.json"
  files+=("$TMP/zeabur-$id.json")
done
gcloud secrets versions access latest --secret app-env --project "$GCP_PROJECT" > "$TMP/current" \
  || die "app-env has no version yet: run init-secrets.sh first"
live=()
[ "${1:-}" = --live ] && live=(--live)
ENCRYPTION_KEY_VAR="$ENCRYPTION_KEY_VAR" python3 -I build-app-env.py ${live[@]+"${live[@]}"} "$TMP/current" "${files[@]}" > "$TMP/app.env"
add_version app-env "$TMP/app.env"

step "encryption-key"
if [ -z "$ENCRYPTION_KEY_VAR" ]; then
  echo "ENCRYPTION_KEY_VAR is empty: the app has no encryption key, skipped"
  echo "next: redeploy so the VM reads the new values (release.sh --deploy-only with the deployed tag)"
  exit 0
fi
require ZEABUR_API_ID
# 從容器取到暫存檔（不經過螢幕），再寫進 Secret Manager
zexec "$ZEABUR_API_ID" printenv "$ENCRYPTION_KEY_VAR" | tr -d '\n' > "$TMP/encryption-key"
[ -s "$TMP/encryption-key" ] || die "$ENCRYPTION_KEY_VAR is empty on Zeabur (no encryption key? set ENCRYPTION_KEY_VAR='' in zeabur-lib.sh)"
add_version encryption-key "$TMP/encryption-key"

# 兩邊的指紋必須相同（只印 SHA-256 的前 12 碼）
zeabur_fp=$(zexec "$ZEABUR_API_ID" sh -c "printenv '$ENCRYPTION_KEY_VAR' | tr -d '\\n' | sha256sum | cut -c1-12")
gcp_fp=$(gcloud secrets versions access latest --secret encryption-key --project "$GCP_PROJECT" | tr -d '\n' | shasum -a 256 | cut -c1-12)
# 陽性對照：空字串的 SHA-256 開頭是 e3b0c44298fc，兩邊都是空的也會「一致」
[ "$gcp_fp" != e3b0c44298fc ] || die "encryption key is empty"
[ "$zeabur_fp" = "$gcp_fp" ] || die "encryption key fingerprints differ: $zeabur_fp vs $gcp_fp"
echo "encryption key fingerprint matches: $gcp_fp"
echo "next: redeploy so the VM reads the new values (release.sh --deploy-only with the deployed tag)"
