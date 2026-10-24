#!/usr/bin/env bash
# 最後封存：加密、上傳、驗證。刪除 Zeabur 上任何有資料的服務之前跑。
#
#   ./final-archive.sh [工作目錄]          # 預設是 zeabur-lib.sh 的 $WORK
#
# 封存工作目錄裡有的每一份資料：
#   zeabur.dump      必要。切換當晚 sync-db.sh 最後一次取回的 dump（Zeabur 從那時起就停止寫入）
#   minio/           有 MinIO 時：fetch-minio-data.sh 取回的 /data（打包成 minio-data.tgz）
#   volumes/*.tgz    有 app volume 時：sync-volume.sh 取回的封包
# 金鑰隨機產生，只存在 Secret Manager，不印出來。要下載回來、用 Secret Manager 裡的金鑰
# 解密、SHA-256 一致，才算完成。成功後自己刪掉工作目錄裡所有明文與金鑰檔。
#
# Archive class 最便宜，但有 365 天最低保存期，提早刪除仍照一年計費。
# 不要給 VM 的服務帳號這個 bucket 或這把金鑰的讀取權限。
set -euo pipefail
cd "$(dirname "$0")"
source ./zeabur-lib.sh
require GCP_PROJECT GCP_REGION
WORK=${1:-$WORK}
BUCKET="gs://$GCP_PROJECT-zeabur-archive"
SECRET=zeabur-archive-key
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
umask 077
cd "$WORK"
[ -s zeabur.dump ] || die "no zeabur.dump in $WORK (sync-db.sh writes it)"
sha() { shasum -a 256 < "$1" | cut -d' ' -f1; }
GPG=(gpg --batch --yes --quiet --pinentry-mode loopback)

step "package"
files=(zeabur.dump)
echo "zeabur.dump: $(pg_restore -l zeabur.dump | grep -c ' TABLE DATA ') tables with data"
if [ -d minio ]; then
  tar -czf minio-data.tgz -C minio .
  files+=(minio-data.tgz)
  echo "minio-data.tgz: $(tar -tzf minio-data.tgz | grep -vc '/$' || true) files"
fi
for f in volumes/*.tgz; do
  [ -e "$f" ] || continue
  files+=("$f")
  echo "$f: $(tar -tzf "$f" | grep -vc '/$' || true) files"
done

step "encrypt (AES-256, random key)"
openssl rand -base64 48 | tr -d '\n' > archive.key
for f in "${files[@]}"; do
  "${GPG[@]}" --passphrase-file archive.key --symmetric --cipher-algo AES256 -o "$f.gpg" "$f"
done

step "key → Secret Manager"
gcloud secrets describe "$SECRET" --project "$GCP_PROJECT" > /dev/null 2>&1 \
  || gcloud secrets create "$SECRET" --project "$GCP_PROJECT" --replication-policy=user-managed --locations="$GCP_REGION"
gcloud secrets versions add "$SECRET" --project "$GCP_PROJECT" --data-file=archive.key

step "bucket (Archive class)"
gcloud storage buckets describe "$BUCKET" --project "$GCP_PROJECT" > /dev/null 2>&1 \
  || gcloud storage buckets create "$BUCKET" --project "$GCP_PROJECT" --location="$GCP_REGION" \
    --default-storage-class=ARCHIVE --uniform-bucket-level-access --public-access-prevention

step "upload"
for f in "${files[@]}"; do
  gcloud storage cp --project "$GCP_PROJECT" "$f.gpg" "$BUCKET/$STAMP/$f.gpg"
done

step "verify: download, decrypt with the stored key, compare"
mkdir -p verify/volumes
gcloud secrets versions access latest --secret "$SECRET" --project "$GCP_PROJECT" > verify/key
for f in "${files[@]}"; do
  gcloud storage cp --project "$GCP_PROJECT" "$BUCKET/$STAMP/$f.gpg" "verify/$f.gpg"
  "${GPG[@]}" --passphrase-file verify/key -o "verify/$f" -d "verify/$f.gpg"
  [ "$(sha "verify/$f")" = "$(sha "$f")" ] || die "MISMATCH $f"
  echo "ok $f  sha256 $(sha "$f")"
done
echo "restored dump: $(pg_restore -l verify/zeabur.dump | grep -c ' TABLE DATA ') tables with data (must equal the source)"
echo "archived to $BUCKET/$STAMP/ (key: Secret Manager $SECRET, latest version)"
echo "now delete the plaintext and key files in $WORK: zeabur.dump minio minio-data.tgz volumes archive.key verify *.gpg"
