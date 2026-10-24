#!/usr/bin/env bash
# app 服務自己掛的 volume（例如上傳的檔案存在 /data/media）：在 Zeabur 容器裡打包 → 分片取回
# → 驗 SHA-256 → 解開到 VM 的資料碟 → 兩邊比對檔案數。zeabur-lib.sh 的 VOLUMES 每一項跑一次。
#
#   ./sync-volume.sh                取回並解開到 VM
#   ./sync-volume.sh --fetch-only   只取回到 $WORK/volumes/（Phase 0 的備份；還沒有 VM 也能跑）
#
# 可以重跑：VM 上的目錄會先清空再解開（保留目錄本身，正在跑的容器的 bind mount 不受影響）。
# compose.yaml 要把 VM 上的目錄掛回容器裡原本的路徑（範本 api 服務的 volumes 註解）。
# 取回的封包留在 $WORK/volumes/，最後封存（final-archive.sh）會一起加密保存。
# 需要容器裡有 tar、sha256sum、stat（Node、Debian 系的 image 都有）。檔案在這個容器裡寫入，
# 所以切換當晚要在暫停這個服務之前跑；之後幾秒內的新上傳由 verify.sh 抓出來。
set -euo pipefail
cd "$(dirname "$0")"
source ./zeabur-lib.sh
source ./fetch-file.sh
FETCH_ONLY=
[ "${1:-}" = --fetch-only ] && FETCH_ONLY=1
require ZEABUR_ENV_ID
[ -n "$FETCH_ONLY" ] || require GCP_PROJECT GCP_ZONE GCP_VM
[ -n "$VOLUMES" ] || die "VOLUMES is empty in zeabur-lib.sh: nothing to sync"
umask 077
work_dir
mkdir -p "$WORK/volumes"

for item in $VOLUMES; do
  IFS=: read -r sid src dst <<< "$item"
  [ -n "$sid" ] && [ -n "$src" ] && [ -n "$dst" ] || die "VOLUMES item '$item' is not <service-id>:<dir>:<vm-dir>"
  case "$item" in *'<'*) die "fill in VOLUMES in zeabur-lib.sh" ;; esac
  # VM 上的目錄會先被清空：只能在資料碟 /srv/data 底下，而且不能是資料庫、Redis、Traefik 的目錄
  case "$dst" in
    *..* | /srv/data/postgres* | /srv/data/redis* | /srv/data/traefik*) die "VOLUMES item '$item': $dst is not allowed" ;;
    /srv/data/?*) ;;
    *) die "VOLUMES item '$item': the VM directory must be under /srv/data/" ;;
  esac
  name=$(printf %s "$sid$src" | tr '/' '_')
  step "$src in service $sid → $dst on the VM"

  # 中途失敗也要刪掉容器裡的封包（$sid 要現在展開）；容器的 /tmp 要放得下整個目錄
  # shellcheck disable=SC2064
  trap "zexec '$sid' rm -f /tmp/volume.tgz > /dev/null 2>&1 || true" EXIT
  OUT=$(zexec "$sid" sh -c "cd '$src' && "'need=$(du -sk . | cut -f1) && avail=$(df -Pk /tmp | tail -1 | tr -s " " | cut -d" " -f4) && if [ "$avail" -le "$need" ]; then echo "nospace ${avail}k free, directory ${need}k"; exit 0; fi && tar -czf /tmp/volume.tgz . && echo "size=$(wc -c < /tmp/volume.tgz) sha256=$(sha256sum /tmp/volume.tgz | cut -d" " -f1) files=$(tar -tzf /tmp/volume.tgz | grep -vc "/\$") owner=$(stat -c %u:%g .)"' || true)
  ! grep -q '^nospace' <<< "$OUT" || die "not enough room in /tmp of service $sid: $(grep '^nospace' <<< "$OUT")"
  INFO=$(grep '^size=' <<< "$OUT" || true)
  [ -n "$INFO" ] || die "could not pack $src in service $sid (does the image have tar and stat?)"
  SIZE=$(sed -E 's/size=([0-9]+).*/\1/' <<< "$INFO")
  SHA=$(sed -E 's/.*sha256=([0-9a-f]+).*/\1/' <<< "$INFO")
  FILES=$(sed -E 's/.*files=([0-9]+).*/\1/' <<< "$INFO")
  OWNER=$(sed -E 's/.*owner=([0-9]+:[0-9]+).*/\1/' <<< "$INFO")
  echo "$FILES files, $SIZE bytes compressed"

  fetch_file "$sid" /tmp/volume.tgz "$SIZE" "$SHA" "$WORK/volumes/$name.tgz"
  zexec "$sid" rm -f /tmp/volume.tgz
  trap - EXIT
  local_files=$(tar -tzf "$WORK/volumes/$name.tgz" | grep -vc '/$' || true)
  [ "$local_files" = "$FILES" ] || die "file count differs after the fetch: $local_files here, $FILES in the container"
  if [ -n "$FETCH_ONLY" ]; then
    echo "saved $WORK/volumes/$name.tgz ($FILES files)"
    continue
  fi

  gscp "$WORK/volumes/$name.tgz" "$GCP_VM:/tmp/volume.tgz"
  # 檔案的擁有者保留容器裡的數字 uid／gid：VM 上跑的是同一個 image、同一個使用者
  vm_files=$(gssh "set -e; sudo mkdir -p '$dst'; sudo find '$dst' -mindepth 1 -delete; sudo tar --numeric-owner -xzf /tmp/volume.tgz -C '$dst'; sudo chown '$OWNER' '$dst'; rm -f /tmp/volume.tgz; sudo find '$dst' -mindepth 1 ! -type d | wc -l" | tail -1 | tr -d ' ')
  [ "$vm_files" = "$FILES" ] || die "file count on the VM differs: $vm_files there, $FILES in the container"
  echo "ok: $FILES files in $dst"
done
