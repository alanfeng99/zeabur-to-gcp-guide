#!/usr/bin/env bash
# 最後封存的第一步：把 Zeabur 上 MinIO 的整個 /data 目錄（後端格式：xl.meta、part.1）
# 逐檔取回到 <工作目錄>/minio，每個檔案都比對容器內算好的 SHA-256。可重跑。
#
#   ./fetch-minio-data.sh <工作目錄>
#
# MinIO 的 image 沒有 tar、gzip、find，所以用 sh 走目錄。`.minio.sys` 裡的 usage、bloom、
# heal 檔一直在變，取回後 checksum 一定對不上，要排除。還原時用 `minio server <目錄>` 開起來。
set -euo pipefail
umask 077
# 在 cd 之前轉成絕對路徑：相對路徑以執行時所在的目錄為準，和 final-archive.sh 一致
WORK=$(mkdir -p "${1:?usage: fetch-minio-data.sh <work-dir>}" && cd "$1" && pwd)
cd "$(dirname "$0")"
source ./zeabur-lib.sh
source ./fetch-file.sh
require ZEABUR_MINIO_ID ZEABUR_ENV_ID
mkdir -p "$WORK/minio"

step "List every file with its size and SHA-256"
zexec "$ZEABUR_MINIO_ID" sh -c 'walk(){ for f in "$1"/* "$1"/.[!.]*; do [ -e "$f" ] || continue; if [ -d "$f" ]; then walk "$f"; else echo "F $(wc -c < "$f") $(sha256sum "$f" | cut -d" " -f1) $f"; fi; done; }; walk /data' \
  | grep '^F ' \
  | grep -vE '/\.minio\.sys/(tmp|multipart)/|\.usage-cache\.bin|\.usage\.json|\.bloomcycle\.bin|\.background-heal' \
  > "$WORK/minio-files.txt" || true
FILES=$(wc -l < "$WORK/minio-files.txt" | tr -d ' ')
[ "$FILES" -gt 0 ] || die "no files listed: check ZEABUR_MINIO_ID"
echo "$FILES files, $(awk '{s += $2} END {print s}' "$WORK/minio-files.txt") bytes"

step "Fetch and verify each file"
i=0
# 欄位：F <bytes> <sha256> <path>，路徑是第 4 欄起
while read -r _ size sha path; do
  i=$((i + 1))
  rel=${path#/data/}
  mkdir -p "$WORK/minio/$(dirname "$rel")"
  fetch_file "$ZEABUR_MINIO_ID" "$path" "$size" "$sha" "$WORK/minio/$rel"
  [ $((i % 10)) -eq 0 ] && echo "  $i/$FILES"
done < "$WORK/minio-files.txt"

step "Drop local files that are not on the verified list"
( cd "$WORK/minio" && find . -type f | sed 's#^\./##' | LC_ALL=C sort ) > "$WORK/local-files.txt"
cut -d' ' -f4- "$WORK/minio-files.txt" | sed 's#^/data/##' | LC_ALL=C sort > "$WORK/listed-files.txt"
# 防呆：清單上的每個路徑都必須在本機找得到才清。欄位切錯（例如路徑變成空字串）時清單
# 會對不上任何本機檔案，下面就會把剛取回的檔案全部刪掉
[ -z "$(LC_ALL=C comm -13 "$WORK/local-files.txt" "$WORK/listed-files.txt")" ] \
  || die "some listed paths are missing locally; not pruning"
LC_ALL=C comm -23 "$WORK/local-files.txt" "$WORK/listed-files.txt" | while IFS= read -r f; do
  rm -f "$WORK/minio/$f"
  echo "  dropped $f"
done
echo "local copy: $(cd "$WORK/minio" && find . -type f | wc -l | tr -d ' ') files (expected $FILES)"
