#!/usr/bin/env bash
# 最後封存：加密、上傳、驗證。刪除 Zeabur 的資料服務之前跑。
#
#   ./final-archive.sh <工作目錄>
#
# 工作目錄裡要有 db.dump 與 minio/：db.dump 是切換後（Zeabur 已停止寫入）取回的 pg_dump -Fc，
# 例如把 sync-db.sh 最後一次取回的 zeabur.dump 複製進來改名；minio/ 由 fetch-minio-data.sh 取回。
# 金鑰隨機產生，只存在 Secret Manager，不印出來。要下載回來、用 Secret Manager 裡的金鑰
# 解密、SHA-256 一致，才算完成。成功後自己刪掉工作目錄裡所有明文與金鑰檔。
#
# Archive class 最便宜，但有 365 天最低保存期，提早刪除仍照一年計費。
# 不要給 VM 的服務帳號這個 bucket 或這把金鑰的讀取權限。
set -euo pipefail
PROJECT='<gcp-project>'
REGION='<region>'
BUCKET="gs://$PROJECT-zeabur-archive"
SECRET=zeabur-archive-key
WORK=${1:?usage: final-archive.sh <work-dir>}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
umask 077
cd "$WORK"
[ -s db.dump ] && [ -d minio ] || { echo "error: need db.dump and minio/ in $WORK" >&2; exit 1; }
sha() { shasum -a 256 < "$1" | cut -d' ' -f1; }
GPG=(gpg --batch --yes --quiet --pinentry-mode loopback)

echo "== package"
tar -czf minio-data.tgz -C minio .
echo "dump: $(pg_restore -l db.dump | grep -c ' TABLE DATA ') tables with data"

echo "== encrypt (AES-256, random key)"
openssl rand -base64 48 | tr -d '\n' > archive.key
for f in db.dump minio-data.tgz; do
  "${GPG[@]}" --passphrase-file archive.key --symmetric --cipher-algo AES256 -o "$f.gpg" "$f"
done

echo "== key → Secret Manager"
gcloud secrets describe "$SECRET" --project "$PROJECT" > /dev/null 2>&1 \
  || gcloud secrets create "$SECRET" --project "$PROJECT" --replication-policy=user-managed --locations="$REGION"
gcloud secrets versions add "$SECRET" --project "$PROJECT" --data-file=archive.key

echo "== bucket (Archive class)"
gcloud storage buckets describe "$BUCKET" --project "$PROJECT" > /dev/null 2>&1 \
  || gcloud storage buckets create "$BUCKET" --project "$PROJECT" --location="$REGION" \
    --default-storage-class=ARCHIVE --uniform-bucket-level-access --public-access-prevention

echo "== upload"
gcloud storage cp --project "$PROJECT" db.dump.gpg minio-data.tgz.gpg "$BUCKET/$STAMP/"

echo "== verify: download, decrypt with the stored key, compare"
mkdir -p verify
gcloud storage cp --project "$PROJECT" "$BUCKET/$STAMP/*" verify/
gcloud secrets versions access latest --secret "$SECRET" --project "$PROJECT" > verify/key
for f in db.dump minio-data.tgz; do
  "${GPG[@]}" --passphrase-file verify/key -o "verify/$f" -d "verify/$f.gpg"
  [ "$(sha "verify/$f")" = "$(sha "$f")" ] || { echo "MISMATCH $f" >&2; exit 1; }
done
echo "restored dump: $(pg_restore -l verify/db.dump | grep -c ' TABLE DATA ') tables with data (must equal the source)"
echo "sha256 db.dump        $(sha db.dump)"
echo "sha256 minio-data.tgz $(sha minio-data.tgz)"
echo "archived to $BUCKET/$STAMP/ (key: Secret Manager $SECRET, latest version)"
echo "now delete the plaintext and key files: minio db.dump minio-data.tgz archive.key verify"
