#!/usr/bin/env bash
# 本機執行：建置並部署。
#
#   ./release.sh                   用 Cloud Build 建置 HEAD，再部署到 VM
#   ./release.sh --deploy-only T   重新部署已建好的 tag T（回滾，或讓新的 secret 生效）
#
# 一律從 git archive HEAD 取內容，未 commit 的檔案不會被帶上去。假設你的專案把
# cloudbuild.yaml 放在 deploy/，VM 上的檔案全部平放在 deploy/host/：compose.yaml、
# deploy.sh、backup.sh、db-backup.service、db-backup.timer（deploy.sh 從同一個目錄安裝
# systemd 單元）。路徑不同就改下面兩處。
# 合併到 main 不會自動部署：上線一律跑這支。
set -euo pipefail
PROJECT='<gcp-project>'
REGION='<region>'
ZONE='<zone>'
HOST='<vm-name>'
BUILD_SA="<build-service-account>@$PROJECT.iam.gserviceaccount.com"

ROOT=$(git rev-parse --show-toplevel)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ "${1:-}" = "--deploy-only" ]; then
  TAG=${2:?usage: release.sh --deploy-only <tag>}
else
  TAG=$(git -C "$ROOT" rev-parse --short=12 HEAD)
  if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
    echo "note: uncommitted changes are not part of this release ($TAG)" >&2
  fi
  git -C "$ROOT" archive --format=tar.gz -o "$TMP/source.tgz" HEAD
  git -C "$ROOT" show HEAD:deploy/cloudbuild.yaml > "$TMP/cloudbuild.yaml"
  gcloud builds submit "$TMP/source.tgz" \
    --project "$PROJECT" \
    --region "$REGION" \
    --config "$TMP/cloudbuild.yaml" \
    --substitutions "_TAG=$TAG" \
    --service-account "projects/$PROJECT/serviceAccounts/$BUILD_SA" \
    --gcs-source-staging-dir "gs://$PROJECT-build/source"
fi

# VM 上的檔案也從 HEAD 來（--deploy-only 時也是：它們很少變，要能跨 tag 相容）
git -C "$ROOT" archive --format=tar.gz -o "$TMP/host.tgz" HEAD:deploy/host
SSH=(--project "$PROJECT" --zone "$ZONE" --tunnel-through-iap --quiet)
gcloud compute scp "${SSH[@]}" "$TMP/host.tgz" "$HOST:/tmp/host.tgz"
gcloud compute ssh "${SSH[@]}" "$HOST" --command \
  "sudo mkdir -p /srv/app && sudo tar -xzf /tmp/host.tgz -C /srv/app && rm /tmp/host.tgz && sudo /srv/app/deploy.sh $(printf %q "$TAG")"
