# shellcheck shell=bash
# 從 Zeabur 容器取回一個檔案。由其他腳本在 zeabur-lib.sh 之後 `source` 載入。
#
#   fetch_file <service-id> <容器內路徑> <bytes> <sha256> <本機路徑>
#
# 大小與 SHA-256 先在容器內算好再傳進來。Zeabur exec 的輸出有大小上限，所以
# 以 1 MB 為一片 base64 取回；整檔 SHA-256 不符就重來，最多 3 次。
# 本機已有且 SHA-256 相符就跳過，所以可以重跑。

fetch_file() {
  local id=$1 remote=$2 size=$3 sha=$4 dest=$5 n try
  if [ -f "$dest" ] && [ "$(shasum -a 256 < "$dest" | cut -d' ' -f1)" = "$sha" ]; then return 0; fi
  for try in 1 2 3; do
    : > "$dest"
    for ((n = 0; n * 1048576 < size; n++)); do
      zexec "$id" sh -c "echo BEGIN; dd if='$remote' bs=1048576 skip=$n count=1 2>/dev/null | base64; echo END" \
        | sed -n '/^BEGIN$/,/^END$/p' | sed '1d;$d' | base64 -d >> "$dest" || true
    done
    [ "$(shasum -a 256 < "$dest" | cut -d' ' -f1)" = "$sha" ] && return 0
    echo "  retry $try: $remote" >&2
    sleep 5
  done
  die "checksum mismatch after 3 tries: $remote"
}
