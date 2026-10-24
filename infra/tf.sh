#!/usr/bin/env bash
# 以目前登入 gcloud 的「使用者帳號」執行某個環境的 terraform：
#
#   ./tf.sh init | plan | apply | output ...     （環境預設是 envs/prod）
#   TF_ENV=staging ./tf.sh plan
#
# 刻意不用 Application Default Credentials：本機的 ADC 常常是別的專案的服務帳號金鑰，
# Terraform 會悄悄用它，把資源建到錯的地方或權限不足。
set -euo pipefail
cd "$(dirname "$0")/envs/${TF_ENV:-prod}"
GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token)"
export GOOGLE_OAUTH_ACCESS_TOKEN
exec terraform "$@"
