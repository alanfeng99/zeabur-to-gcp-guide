#!/usr/bin/env bash
# Phase 2：替 app-env 補上 app 開機就要的變數（JWT secret、第三方的測試金鑰等），用 staging 的值。
# 在你自己的終端機執行：值用隱藏輸入，不顯示、不進 shell 歷史。
#
#   ./set-env.sh KEY...            每個 KEY 問一次值
#   ./set-env.sh --random KEY...   每個 KEY 填 48 個隨機的十六進位字元（staging 的 JWT secret 之類）
#
# 已有的 KEY 會被換掉，其他的保留，新增一個 app-env 版本；之後 release.sh --deploy-only 才生效。
# Phase 3 的 sync-env.sh 會依 build-app-env.py 的對照表換成 Zeabur 上的正式值；
# HOLD 的變數在 sync-env.sh --live 之前沿用這裡給的值。
set -euo pipefail
cd "$(dirname "$0")"
source ./zeabur-lib.sh
require GCP_PROJECT
random=
if [ "${1:-}" = --random ]; then
  random=1
  shift
fi
[ $# -gt 0 ] || die "usage: set-env.sh [--random] KEY..."
umask 077
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

gcloud secrets versions access latest --secret app-env --project "$GCP_PROJECT" > "$TMP/current" \
  || die "app-env has no version yet: run init-secrets.sh first"
: > "$TMP/new"
for key in "$@"; do
  [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "not a variable name: $key"
  if [ -n "$random" ]; then
    value=$(openssl rand -hex 24)
  else
    read -rsp "$key (hidden): " value
    echo
  fi
  printf '%s=%s\n' "$key" "$value" >> "$TMP/new"
done

# 合併；docker compose 的 env_file 會改掉的值（$、行尾 #、引號、前後空白）直接拒絕
python3 -I - "$TMP/current" "$TMP/new" > "$TMP/app-env" << 'PY'
import sys
def read(path):
    env = {}
    for line in open(path):
        line = line.rstrip('\n')
        if line and not line.startswith('#') and '=' in line:
            k, v = line.split('=', 1)
            env[k] = v
    return env
env = read(sys.argv[1])
for k, v in read(sys.argv[2]).items():
    if not v or '$' in v or ' #' in v or v != v.strip() or v.startswith(('"', "'")):
        sys.exit(f'{k}: empty, or docker compose env_file would alter it ($, " #", quotes, edge spaces)')
    env[k] = v
for k in sorted(env):
    print(f'{k}={env[k]}')
PY
gcloud secrets versions add app-env --project "$GCP_PROJECT" --data-file="$TMP/app-env" --format='value(name)' \
  | sed 's#.*/versions/#app-env: added version #'
echo "set: $*  (next: release.sh --deploy-only with the deployed tag)"
