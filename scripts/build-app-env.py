"""依對照表把 Zeabur 匯出的環境變數（JSON）轉成 GCP 用的 app.env，印到 stdout。

    python3 -I build-app-env.py zeabur-env.json current-app-env > app.env

current-app-env 是 Secret Manager 裡 app-env 目前的版本：KEEP 的值（資料庫密碼、GCS 的
S3 相容金鑰）只存在 GCP 這邊，從那裡沿用。所以 app-env 要先有一個版本，至少含 KEEP 的
每一個變數（例如由 Terraform 或手動寫入）。

遇到沒分類的變數就停，避免漏搬；COPY／DROP／SET／KEEP 換成自己專案的變數。
值會被 docker compose 的 env_file 解析：含 $、行尾 # 註解、前後空白或引號的值會被悄悄
改掉（例如 JWT secret 變了，所有使用者都被登出），所以遇到就停，請換掉那個值。
"""
import json
import sys

COPY = {'JWT_ACCESS_SECRET', 'JWT_REFRESH_SECRET', 'OPENAI_API_KEY'}  # 照抄
DROP = {'PORT', 'ZBPACK_DOCKERFILE_PATH', 'DATABASE_URL', 'REDIS_URL',  # 拿掉，或由 compose 提供
        'ENCRYPTION_KEY',                                               # 加密金鑰另存一個 secret
        'S3_ENDPOINT', 'S3_PORT', 'S3_USE_SSL', 'S3_ACCESS_KEY', 'S3_SECRET_KEY', 'S3_BUCKET'}  # Zeabur 的 MinIO
KEEP = {'POSTGRES_PASSWORD',                                            # 沿用 GCP 這邊的值
        'S3_ENDPOINT', 'S3_PORT', 'S3_USE_SSL', 'S3_ACCESS_KEY', 'S3_SECRET_KEY', 'S3_BUCKET'}
SET = {                                                                 # 換成 GCP 的值
    'API_PUBLIC_URL': 'https://api.example.com',
    'CORS_ORIGINS': 'https://www.example.com,https://admin.example.com',
    'TRUST_PROXY_HOPS': '1',
}


def parse_env_file(path):
    env = {}
    for line in open(path):
        line = line.rstrip('\n')
        if line and not line.startswith('#') and '=' in line:
            key, value = line.split('=', 1)
            env[key] = value
    return env


def check(key, value):
    if '\n' in value or '$' in value or ' #' in value or value != value.strip() or value.startswith(('"', "'")):
        sys.exit(f'{key}: docker compose env_file would alter this value; choose one without $, " #", quotes or edge spaces')


src = json.load(open(sys.argv[1]))
rows = src['variables'] if isinstance(src, dict) else src
zeabur = {(r.get('key') or r.get('Key')): (r.get('value') if 'value' in r else r.get('Value')) for r in rows}
current = parse_env_file(sys.argv[2])

unknown = sorted(set(zeabur) - COPY - DROP - set(SET) - KEEP)
if unknown:
    sys.exit('unclassified variables (add them to COPY, DROP, SET or KEEP): ' + ', '.join(unknown))
missing = sorted(KEEP - set(current))
if missing:
    sys.exit('not in the current app-env yet (write them there first): ' + ', '.join(missing))

out = {key: zeabur[key] for key in COPY & set(zeabur)}
out.update(SET)
out.update({key: current[key] for key in KEEP})
for key in out:
    check(key, out[key])  # 全部檢查過才輸出，失敗時不留半份檔案
for key in sorted(out):
    print(f'{key}={out[key]}')
