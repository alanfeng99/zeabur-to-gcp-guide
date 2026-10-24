#!/usr/bin/env bash
# 這個 repo 自己的檢查：改了腳本、範本或文件，全部通過才發 PR。
#
#   tests/run.sh                      全部
#   tests/run.sh static unit …        只跑其中幾段：
#     static     bash -n（本機的 bash 與 bash 5）、shellcheck、Python 與 JS 語法、Terraform、compose
#     unit       build-app-env.py：分類、HOLD 與 --live、錯誤訊息不含值
#     layout     照 AGENTS.md 複製成模擬的使用者專案：佔位值檢查、設定錯了要在動到 Zeabur 之前就停
#     container  在 Debian、Alpine、Postgres 容器裡實際跑 dump、打包、VM 上解開與計數的那幾行
#     docs       文件的相對連結與錨點、不該公開的識別資訊
#
# 不會連到 Zeabur 或 GCP：gcloud、npx、curl 都換成假的，要測的那幾行直接從腳本裡取出來執行。
# 需要 bash、python3、git、Docker（含 compose），第一次會下載幾個 image。
# terraform 沒裝就用 Docker 跑（TERRAFORM=docker 也會）。
set -euo pipefail
cd "$(dirname "$0")/.."
RUN_ID=zeabur-to-gcp-guide-test-$$
T=$(mktemp -d)
cleanup() {
  local ids
  ids=$(docker ps -aq --filter "label=$RUN_ID" 2> /dev/null || true)
  [ -z "$ids" ] || docker rm -f $ids > /dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT

# --- 共用 -------------------------------------------------------------------
pass=0
fail=0
# 每一項在 subshell 裡以 set -e 執行：任何一行失敗就算這一項失敗，並印出是哪一行
t() {
  local name=$1 rc
  shift
  set +e
  (
    set -eE
    trap 'echo "failed: $BASH_COMMAND"' ERR
    "$@"
  ) > "$T/log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    pass=$((pass + 1))
    echo "  ok    $name"
  else
    fail=$((fail + 1))
    echo "  FAIL  $name"
    tail -30 "$T/log" | sed 's/^/        /'
  fi
}

# 跑一個指令，輸出存到 $T/last，再用 has／lacks／line 檢查
succeeds() { "$@" > "$T/last" 2>&1 || { cat "$T/last"; echo "expected success: $*"; return 1; }; }
fails() { if "$@" > "$T/last" 2>&1; then cat "$T/last"; echo "expected failure: $*"; return 1; fi; }
has() { grep -qF -- "$1" "$T/last" || { cat "$T/last"; echo "missing in the output: $1"; return 1; }; }
lacks() { if grep -qF -- "$1" "$T/last"; then cat "$T/last"; echo "unexpected in the output: $1"; return 1; fi; }
line() { grep -qxF -- "$1" "$T/last" || { cat "$T/last"; echo "missing line: $1"; return 1; }; }
# 最後一行：腳本停在預期的那一步，而不是後面的某一步
ends() { [ "$(tail -1 "$T/last")" = "$1" ] || { cat "$T/last"; echo "the last line should be: $1"; return 1; }; }

# 從腳本裡取出含 <片段> 的那一行（必須剛好一行），給 eval 用：測的是腳本裡實際的寫法
code_line() {
  local n
  n=$(grep -cF -- "$2" "$1" || true)
  [ "$n" = 1 ] || { echo "expected exactly one line containing '$2' in $1, found $n"; return 1; }
  grep -F -- "$2" "$1" | sed 's/^ *//'
}

need_docker() {
  docker info > /dev/null 2>&1 || { echo "Docker is not running (needed for the $1 section)" >&2; exit 1; }
}

SHELL_FILES=$(ls scripts/*.sh infra/*.sh tests/*.sh)
PY_FILES=$(ls scripts/*.py tests/*.py)

# --- static -----------------------------------------------------------------
static_bash() { for f in $SHELL_FILES; do bash -n "$f"; done; }
static_bash5() {
  docker run --rm --label "$RUN_ID" -v "$PWD:/repo:ro" -w /repo bash:5.2 \
    bash -c 'for f in "$@"; do bash -n "$f" || exit 1; done' _ $SHELL_FILES
}
# 只擋 warning 以上；info（SC2015、SC2016 這類）是刻意的寫法
static_shellcheck() {
  docker run --rm --label "$RUN_ID" -e LANG=C.UTF-8 -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:v0.10.0 \
    -S warning -x -P scripts $SHELL_FILES
}
static_python() {
  python3 -I -c 'import ast, sys
for f in sys.argv[1:]:
    ast.parse(open(f, encoding="utf-8").read(), f)' $PY_FILES
}
static_js() {
  docker run --rm --label "$RUN_ID" -v "$PWD:/repo:ro" -w /repo node:20-alpine node --check scripts/copy-assets.js
}

# 在 $T 的副本裡跑，repo 裡不會留下 .terraform
tf() {
  local dir=$1
  shift
  if [ "${TERRAFORM:-}" != docker ] && command -v terraform > /dev/null; then
    (cd "$T/infra/$dir" && terraform "$@")
  else
    docker run --rm --label "$RUN_ID" --user "$(id -u):$(id -g)" -e HOME=/tmp -e TF_IN_AUTOMATION=1 \
      -v "$T/infra:/infra" -w "/infra/$dir" hashicorp/terraform:1.9.8 "$@"
  fi
}
static_terraform() {
  cp -R infra "$T/infra"
  find "$T/infra" -name .terraform -prune -exec rm -rf {} +
  tf . fmt -check -recursive
  for d in modules/compose-host envs/prod; do
    tf "$d" init -backend=false -input=false > /dev/null
    tf "$d" validate -no-color
  done
}

static_compose() {
  mkdir -p "$T/compose"
  cp templates/compose.example.yaml "$T/compose/compose.yaml"
  : > "$T/compose/app.env"
  cd "$T/compose"
  IMAGE_TAG=test POSTGRES_PASSWORD=x docker compose config -q
  # deploy.sh 與 restore-on-host.sh 用到的服務都要在
  IMAGE_TAG=test POSTGRES_PASSWORD=x docker compose --profile '*' config --services > "$T/last"
  for s in api admin web worker migrate postgres redis traefik socket-proxy; do line "$s"; done
}

# retire-zeabur-frontends.sh 從 Caddyfile 讀轉址碼：302，改成 301 後就是 301
# shellcheck disable=SC2034
static_redirect_code() {
  local REDIRECT_DIR CODE l
  l=$(code_line scripts/retire-zeabur-frontends.sh 'CODE=$(sed')
  REDIRECT_DIR=templates/zeabur-redirect
  eval "$l"
  [ "$CODE" = 302 ]
  mkdir -p "$T/redirect"
  sed 's/ 302$/ 301/' templates/zeabur-redirect/Caddyfile > "$T/redirect/Caddyfile"
  REDIRECT_DIR=$T/redirect
  eval "$l"
  [ "$CODE" = 301 ]
}

# --- unit：build-app-env.py ---------------------------------------------------
unit_setup() {
  local d=$T/bae
  mkdir -p "$d"
  cp scripts/build-app-env.py "$d/plain.py"
  sed "s/^HOLD = set()/HOLD = {'LINE_TOKEN'}/" scripts/build-app-env.py > "$d/held.py"
  grep -q "^HOLD = {'LINE_TOKEN'}" "$d/held.py" || { echo "build-app-env.py no longer has 'HOLD = set()'" >&2; exit 1; }
  printf 'POSTGRES_PASSWORD=pg\nS3_BUCKET=gcs-bucket\nLINE_TOKEN=test-token\n' > "$d/current"
  printf 'POSTGRES_PASSWORD=pg\n' > "$d/current-no-hold"
  printf 'S3_BUCKET=x\n' > "$d/current-no-pg"
  # 兩種 zeabur variable list --json 的格式；PORT 在兩個服務不一樣，但它被 DROP，不算衝突
  cat > "$d/api.json" << 'EOF'
[{"key": "JWT_ACCESS_SECRET", "value": "a"}, {"key": "PORT", "value": "8080"},
 {"key": "S3_BUCKET", "value": "zeabur-bucket"}, {"key": "LINE_TOKEN", "value": "REAL"},
 {"key": "MESSAGING_ENCRYPTION_KEY", "value": "k"}, {"key": "API_PUBLIC_URL", "value": "https://old"}]
EOF
  echo '{"variables": [{"Key": "JWT_ACCESS_SECRET", "Value": "a"}, {"Key": "PORT", "Value": "9090"}]}' > "$d/worker.json"
  echo '[{"key": "JWT_ACCESS_SECRET", "value": "aaa-one"}]' > "$d/one.json"
  echo '[{"key": "JWT_ACCESS_SECRET", "value": "bbb-two"}]' > "$d/two.json"
  echo '[{"key": "JWT_ACCESS_SECRET", "value": "secret$value"}]' > "$d/dollar.json"
  echo '[{"key": "JWT_ACCESS_SECRET", "value": "a"}]' > "$d/simple.json"
}
bae() { (cd "$T/bae" && ENCRYPTION_KEY_VAR=${KEYVAR-MESSAGING_ENCRYPTION_KEY} python3 -I "$@"); }

unit_standby() {
  succeeds bae held.py current api.json worker.json
  line 'LINE_TOKEN=test-token'
  line 'HELD_CREDENTIALS=standby'
  line 'S3_BUCKET=gcs-bucket'
  line 'POSTGRES_PASSWORD=pg'
  line 'JWT_ACCESS_SECRET=a'
  line 'API_PUBLIC_URL=https://api.example.com'
  lacks 'MESSAGING_ENCRYPTION_KEY'
  lacks 'PORT='
  lacks 'REAL'
}
unit_live() {
  succeeds bae held.py --live current api.json worker.json
  line 'LINE_TOKEN=REAL'
  line 'HELD_CREDENTIALS=live'
}
unit_held_without_test_value() {
  succeeds bae held.py current-no-hold api.json
  lacks 'LINE_TOKEN'
  line 'HELD_CREDENTIALS=standby'
}
unit_hold_list() {
  succeeds bae held.py --hold
  line 'LINE_TOKEN'
  succeeds bae plain.py --hold
  [ -z "$(tr -d '\n' < "$T/last")" ]
}
unit_no_hold_no_marker() {
  succeeds bae plain.py current-no-hold simple.json
  lacks 'HELD_CREDENTIALS'
}
unit_unclassified() {
  fails bae plain.py current api.json
  has 'unclassified variables'
  has 'LINE_TOKEN'
}
unit_key_name() {
  KEYVAR='' fails bae held.py current api.json
  has 'MESSAGING_ENCRYPTION_KEY'
}
unit_conflict() {
  fails bae held.py current one.json two.json
  has 'JWT_ACCESS_SECRET'
  lacks 'aaa-one'
  lacks 'bbb-two'
}
unit_env_file_value() {
  fails bae held.py current dollar.json
  has 'JWT_ACCESS_SECRET'
  lacks 'secret$value'
}
unit_missing_keep() {
  fails bae held.py current-no-pg api.json
  has 'POSTGRES_PASSWORD'
}

# --- layout：模擬的使用者專案 -------------------------------------------------
# 照 AGENTS.md「檔案放在使用者的專案裡」複製；minimal 是沒有 MinIO、volume、Access 的專案
make_layout() {
  local u=$1 f b
  mkdir -p "$u/infra" "$u/deploy/host" "$u/deploy/migrate" "$u/deploy/templates"
  cp -p docs/MIGRATION.template.md "$u/MIGRATION.md"
  cp -pR infra "$u/infra/gcp"
  cp -p scripts/release.sh "$u/deploy/"
  cp -p templates/cloudbuild.example.yaml "$u/deploy/cloudbuild.yaml"
  cp -p templates/compose.example.yaml "$u/deploy/host/compose.yaml"
  cp -p scripts/deploy.sh scripts/backup.sh templates/systemd/* "$u/deploy/host/"
  cp -pR templates/zeabur-redirect "$u/deploy/templates/"
  for f in scripts/*; do
    b=${f##*/}
    case $b in release.sh | deploy.sh | backup.sh | README.md) continue ;; esac
    if [ "$2" = minimal ]; then
      case $b in sync-assets.sh | fetch-minio-data.sh | copy-assets.js | sync-volume.sh | cloudflare-access.py | setup-tunnel.sh) continue ;; esac
    fi
    cp -p "$f" "$u/deploy/migrate/"
  done
}

# 改 shell 設定檔裡的一行：setvar <檔案> <變數> <值>
setvar() {
  python3 -I - "$@" << 'EOF'
import re, sys
path, key, value = sys.argv[1:]
text, n = re.subn(rf"^(export )?{key}=.*$", rf"\g<1>{key}='{value}'", open(path).read(), count=1, flags=re.M)
assert n == 1, f'{key} not found in {path}'
open(path, 'w').write(text)
EOF
}

layout_setup() {
  make_layout "$T/min" minimal
  make_layout "$T/full" full
  setvar "$T/min/deploy/migrate/zeabur-lib.sh" FILES_CHECK none
  setvar "$T/min/deploy/migrate/zeabur-lib.sh" FILES_KEY_QUERY ''
  mkdir -p "$T/stub"
  cat > "$T/stub/curl" << 'EOF'
#!/bin/sh
echo '{"status":"ok"}'
EOF
  cat > "$T/stub/gcloud" << 'EOF'
#!/bin/sh
echo "gcloud $*" >> "$STUB_LOG"
EOF
  cat > "$T/stub/npx" << 'EOF'
#!/bin/sh
echo "npx $*" >> "$STUB_LOG"
exit 97
EOF
  chmod +x "$T/stub/curl" "$T/stub/gcloud" "$T/stub/npx"
}
# 在假的 gcloud、npx、curl 之下跑；npx（也就是 Zeabur CLI）被叫到的話會記在 $T/calls.log
stubbed() { PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" MIGRATION_WORK="$T/work" "$@"; }
no_zeabur_calls() {
  if grep -s '^npx' "$T/calls.log"; then echo "the Zeabur CLI was called"; return 1; fi
}

layout_fill() {
  succeeds python3 -I tests/fill_placeholders.py "$1" deploy infra/gcp
  has 'final: no placeholders left 0'
  has 'deploy/migrate/zeabur-lib.sh:'
  # 第一輪列出的都要是真的佔位值：require 的比對樣式與印給人看的提示不算
  lacks 'case "${!v'
  if grep -E '^[^:]+:[0-9]+: (echo|printf) ' "$T/last"; then echo "a message line was flagged"; return 1; fi
}

layout_verify_none() {
  fails stubbed bash "$T/min/deploy/migrate/verify.sh"
  has 'skipped: FILES_CHECK=none'
  ends "error: add your project's own checks here, then remove this line"
}
layout_verify_gcs() {
  fails stubbed bash "$T/full/deploy/migrate/verify.sh"
  ends 'error: the database query returned no keys: check FILES_KEY_QUERY'
}
layout_cutover_needs_confirm() {
  fails stubbed bash "$T/min/deploy/migrate/cutover.sh"
  ends 'error: refusing to run without --confirm'
}
layout_cutover_bad_files_check() {
  local lib=$T/min/deploy/migrate/zeabur-lib.sh
  rm -f "$T/calls.log"
  setvar "$lib" FILES_CHECK bogus
  fails stubbed bash "$T/min/deploy/migrate/cutover.sh" --confirm
  setvar "$lib" FILES_CHECK none
  ends "error: FILES_CHECK must be 'gcs', 'vm:/absolute/dir' or 'none'"
  no_zeabur_calls
}
layout_cutover_stops_before_zeabur() {
  rm -f "$T/calls.log"
  fails stubbed bash "$T/min/deploy/migrate/cutover.sh" --confirm
  ends 'error: fill in step 3 of verify.sh first'
  no_zeabur_calls
}
layout_rollback_needs_confirm() {
  fails stubbed bash "$T/min/deploy/migrate/rollback.sh"
  ends 'error: refusing to run without --confirm'
}
# VM 上的目錄會先被清空：只能在 /srv/data 底下，不能是資料庫、Redis、Traefik 的目錄
layout_volume_destination() {
  local lib=$T/full/deploy/migrate/zeabur-lib.sh v
  for v in /srv/data /srv/data/ /srv/app /tmp/x; do
    setvar "$lib" VOLUMES "sid:/data:$v"
    fails stubbed bash "$T/full/deploy/migrate/sync-volume.sh"
    ends "error: VOLUMES item 'sid:/data:$v': the VM directory must be under /srv/data/"
  done
  for v in /srv/data/postgres /srv/data/postgres-replaced-1 /srv/data/redis /srv/data/traefik /srv/data/../app; do
    setvar "$lib" VOLUMES "sid:/data:$v"
    fails stubbed bash "$T/full/deploy/migrate/sync-volume.sh"
    ends "error: VOLUMES item 'sid:/data:$v': $v is not allowed"
  done
  setvar "$lib" VOLUMES 'sid:/data:/srv/data/media'
  fails stubbed bash "$T/full/deploy/migrate/sync-volume.sh"
  has '/data in service sid → /srv/data/media on the VM'
  ends 'error: could not pack /data in service sid (does the image have tar and stat?)'
  setvar "$lib" VOLUMES ''
}
layout_sync_env_empty_services() {
  local lib=$T/full/deploy/migrate/zeabur-lib.sh
  setvar "$lib" ENV_SERVICE_IDS ''
  fails stubbed bash "$T/full/deploy/migrate/sync-env.sh"
  ends 'error: ENV_SERVICE_IDS is empty in zeabur-lib.sh'
}

# --- container：在容器裡跑腳本實際的那幾行 ---------------------------------------
zexec() {
  local id=$1
  shift
  docker exec "$id" "$@" 2> /dev/null | tr -d '\r'
}
# 假的 VM：Debian，sudo 換成直接執行
gssh() { docker exec "$VM" bash -c "export PATH=/shim:\$PATH; $1"; }
sha256() { python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }

# sync-db.sh：容器內 dump（權限 600）、/tmp 不夠時拒絕且不留檔
# shellcheck disable=SC2034
container_pg() {
  local image=$1 mode=$2 c l re OUT ZEABUR_POSTGRES_ID opt=''
  [ "$mode" = small ] && opt=--tmpfs=/tmp:size=1m
  c=$(docker run -d --label "$RUN_ID" ${opt:+"$opt"} -e POSTGRES_USER=app -e POSTGRES_DB=app -e POSTGRES_PASSWORD=x "$image")
  for _ in $(seq 1 90); do
    if [ "$(docker logs "$c" 2>&1 | grep -c 'init process complete')" -ge 1 ] && docker exec "$c" pg_isready -U app -d app -q; then break; fi
    sleep 1
  done
  docker exec "$c" pg_isready -U app -d app -q
  ZEABUR_POSTGRES_ID=$c
  l=$(code_line scripts/sync-db.sh 'OUT=$(zexec "$ZEABUR_POSTGRES_ID" sh -c')
  eval "$l"
  if [ "$mode" = small ]; then
    [[ $OUT == nospace* ]] || { echo "expected nospace, got: $OUT"; return 1; }
    [ "$(docker exec "$c" sh -c 'ls /tmp/final.dump 2> /dev/null | wc -l')" -eq 0 ]
  else
    re='^size=[0-9]+ sha256=[0-9a-f]{64}$'
    [[ $OUT =~ $re ]] || { echo "unexpected: $OUT"; return 1; }
    [ "$(docker exec "$c" stat -c %a /tmp/final.dump)" = 600 ]
  fi
  docker rm -f "$c" > /dev/null
}

# sync-volume.sh 的打包：路徑有空白、symlink 也算檔案、記下擁有者；/tmp 不夠時拒絕
# shellcheck disable=SC2034
container_volume() {
  local image=$1 mode=$2 c l re OUT sid src opt=''
  [ "$mode" = small ] && opt=--tmpfs=/tmp:size=64k
  c=$(docker run -d --label "$RUN_ID" ${opt:+"$opt"} "$image" sleep 300)
  if [ "$mode" = small ]; then
    docker exec "$c" sh -c 'mkdir -p /data && head -c 2000000 /dev/urandom > /data/big'
    src=/data
  else
    docker exec "$c" sh -c 'mkdir -p "/data/my media/sub" && echo a > "/data/my media/a" && echo b > "/data/my media/sub/b" && ln -s a "/data/my media/link" && chown -R 1000:1000 /data'
    src="/data/my media"
  fi
  sid=$c
  l=$(code_line scripts/sync-volume.sh 'OUT=$(zexec "$sid" sh -c')
  eval "$l"
  if [ "$mode" = small ]; then
    [[ $OUT == nospace* ]] || { echo "expected nospace, got: $OUT"; return 1; }
  else
    re='^size=[0-9]+ sha256=[0-9a-f]{64} files=3 owner=1000:1000$'
    [[ $OUT =~ $re ]] || { echo "unexpected: $OUT"; return 1; }
    docker cp "$c:/tmp/volume.tgz" "$T/volume.tgz"
    [[ $OUT == *"sha256=$(sha256 "$T/volume.tgz") "* ]] || { echo "sha256 differs from the packed file"; return 1; }
  fi
  docker rm -f "$c" > /dev/null
}

# sync-volume.sh 在 VM 上解開：先清空目錄、保留數字 uid／gid、計數和容器一致；
# verify.sh 列出 VM 目錄裡的檔案：相對路徑，和資料庫裡的 key 同一種寫法
# shellcheck disable=SC2034
container_vm() {
  local VM l dst OWNER vm_files dir TMP
  [ -s "$T/volume.tgz" ] || { echo "run container_volume first"; return 1; }
  mkdir -p "$T/shim"
  printf '#!/bin/sh\nexec "$@"\n' > "$T/shim/sudo"
  chmod +x "$T/shim/sudo"
  VM=$(docker run -d --label "$RUN_ID" -v "$T/shim:/shim:ro" debian:12-slim sleep 300)
  docker cp "$T/volume.tgz" "$VM:/tmp/volume.tgz"
  docker exec "$VM" sh -c 'mkdir -p /srv/data/media && echo old > /srv/data/media/old.txt'
  dst=/srv/data/media
  OWNER=1000:1000
  l=$(code_line scripts/sync-volume.sh 'vm_files=$(gssh')
  eval "$l"
  [ "$vm_files" = 3 ] || { echo "vm_files=$vm_files, want 3"; return 1; }
  [ "$(docker exec "$VM" stat -c %u:%g /srv/data/media)" = 1000:1000 ]
  [ "$(docker exec "$VM" sh -c 'ls /srv/data/media/old.txt 2> /dev/null | wc -l')" -eq 0 ]
  dir=/srv/data/media
  TMP=$T
  l=$(code_line scripts/verify.sh "sudo find '\$dir'")
  eval "$l"
  [ "$(tr '\n' ' ' < "$T/present.txt")" = 'a sub/b ' ] || { echo "listed: $(cat "$T/present.txt")"; return 1; }
  docker rm -f "$VM" > /dev/null
}

# --- 執行 -------------------------------------------------------------------
sections=${*:-static unit layout container docs}
for s in $sections; do
  case $s in
    static | container) need_docker "$s" ;;
    unit | layout | docs) ;;
    *) echo "unknown section: $s (static, unit, layout, container, docs)" >&2; exit 2 ;;
  esac
done

for s in $sections; do
  echo "== $s"
  case $s in
    static)
      t 'bash -n (local bash)' static_bash
      t 'bash -n (bash 5.2)' static_bash5
      t 'shellcheck' static_shellcheck
      t 'python syntax' static_python
      t 'copy-assets.js syntax' static_js
      t 'terraform fmt and validate' static_terraform
      t 'compose template' static_compose
      t 'redirect code from the Caddyfile' static_redirect_code
      ;;
    unit)
      unit_setup
      t 'standby keeps HOLD test values' unit_standby
      t '--live uses the Zeabur values' unit_live
      t 'HOLD without a test value is left out' unit_held_without_test_value
      t '--hold lists HOLD' unit_hold_list
      t 'no HOLD, no marker' unit_no_hold_no_marker
      t 'unclassified variables stop' unit_unclassified
      t 'ENCRYPTION_KEY_VAR is dropped' unit_key_name
      t 'conflicts stop without printing values' unit_conflict
      t 'env_file-unsafe values stop without printing them' unit_env_file_value
      t 'missing KEEP values stop' unit_missing_keep
      ;;
    layout)
      layout_setup
      t 'placeholders: project without MinIO, volume or Access' layout_fill "$T/min"
      t 'placeholders: project with everything' layout_fill "$T/full"
      t 'verify.sh skips files with FILES_CHECK=none' layout_verify_none
      t 'verify.sh asks the database with FILES_CHECK=gcs' layout_verify_gcs
      t 'cutover.sh needs --confirm' layout_cutover_needs_confirm
      t 'cutover.sh rejects a bad FILES_CHECK before Zeabur' layout_cutover_bad_files_check
      t 'cutover.sh stops before Zeabur while verify.sh is unfinished' layout_cutover_stops_before_zeabur
      t 'rollback.sh needs --confirm' layout_rollback_needs_confirm
      t 'sync-volume.sh destination guard' layout_volume_destination
      t 'sync-env.sh with no services' layout_sync_env_empty_services
      ;;
    container)
      t 'pg_dump in postgres:16' container_pg postgres:16 normal
      t 'pg_dump refuses a full /tmp (postgres:16)' container_pg postgres:16 small
      t 'pg_dump in postgres:16-alpine' container_pg postgres:16-alpine normal
      t 'pg_dump refuses a full /tmp (postgres:16-alpine)' container_pg postgres:16-alpine small
      t 'volume pack in alpine' container_volume alpine:3.20 normal
      t 'volume pack refuses a full /tmp (alpine)' container_volume alpine:3.20 small
      t 'volume pack refuses a full /tmp (debian)' container_volume debian:12-slim small
      t 'volume pack in debian' container_volume debian:12-slim normal
      t 'volume unpack and count on the VM' container_vm
      ;;
    docs)
      t 'links and anchors' python3 -I tests/check_links.py
      t 'no public identifiers' python3 -I tests/check_identifiers.py
      ;;
  esac
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
