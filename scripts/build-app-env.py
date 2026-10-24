"""依對照表把 Zeabur 匯出的環境變數（JSON）轉成 GCP 用的 app.env，印到 stdout。

    python3 -I build-app-env.py [--live] current-app-env zeabur-api.json [zeabur-worker.json ...]
    python3 -I build-app-env.py --hold        # 只印 HOLD 的變數名稱（cutover.sh 檢查用）

current-app-env 是 Secret Manager 裡 app-env 目前的版本（init-secrets.sh 寫的第一版）：
KEEP 的值只存在 GCP 這邊，從那裡沿用。之後的每個 JSON 是一個 Zeabur 服務的
`zeabur variable list --json`，會合併成一份；同一個變數在不同服務的值不一樣就停
（只印名稱），請決定要哪一個。

遇到沒分類的變數就停，避免漏搬；COPY／DROP／SET／KEEP／HOLD 換成自己專案的變數
（Phase 0 和使用者確認過的分類）。HOLD 是會對外發訊息的憑證（通訊軟體、寄信、簡訊、金流）：
standby 期間 GCP 的 API 已經在跑正式資料，不給它正式憑證，避免通知到真實客戶。沒加 --live
時沿用 current-app-env 裡的值（set-env.sh 給的測試值，或沒有），加 --live 才換成 Zeabur 上的值。
值會被 docker compose 的 env_file 解析：含 $、行尾 # 註解、前後空白或引號的值會被悄悄
改掉（例如 JWT secret 變了，所有使用者都被登出），所以遇到就停，請換掉那個值。
"""
import json
import os
import sys

COPY = {'JWT_ACCESS_SECRET', 'JWT_REFRESH_SECRET', 'OPENAI_API_KEY'}  # 照抄
DROP = {'PORT', 'HOSTNAME', 'ZBPACK_DOCKERFILE_PATH', 'DATABASE_URL', 'REDIS_URL',  # 拿掉，或由 compose 提供
        'ENCRYPTION_KEY', os.environ.get('ENCRYPTION_KEY_VAR') or 'ENCRYPTION_KEY',  # 加密金鑰另存一個 secret（sync-env.sh 傳名稱進來）
        'S3_ENDPOINT', 'S3_PORT', 'S3_USE_SSL', 'S3_ACCESS_KEY', 'S3_SECRET_KEY', 'S3_BUCKET'}  # Zeabur 的 MinIO
HOLD = set()                                                                      # 例如 {'LINE_CHANNEL_ACCESS_TOKEN', 'SMTP_PASSWORD'}
KEEP_REQUIRED = {'POSTGRES_PASSWORD'}                                             # 沿用 GCP 這邊的值
KEEP_OPTIONAL = {'S3_ENDPOINT', 'S3_PORT', 'S3_USE_SSL', 'S3_ACCESS_KEY', 'S3_SECRET_KEY', 'S3_BUCKET'}
SET = {                                                                           # 換成 GCP 的值
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


args = sys.argv[1:]
if args == ['--hold']:
    print('\n'.join(sorted(HOLD)))
    sys.exit(0)
live = args[:1] == ['--live']
args = args[1:] if live else args
if len(args) < 2:
    sys.exit(__doc__)
current = parse_env_file(args[0])
zeabur, conflicts = {}, set()
for path in args[1:]:
    src = json.load(open(path))
    rows = src['variables'] if isinstance(src, dict) else src
    for r in rows:
        key = r.get('key') or r.get('Key')
        value = (r.get('value') if 'value' in r else r.get('Value')) or ''
        if key in zeabur and zeabur[key] != value and key not in DROP:
            conflicts.add(key)
        zeabur.setdefault(key, value)
if conflicts:
    sys.exit('same variable, different values across services (decide which one, or rename): ' + ', '.join(sorted(conflicts)))

keep = KEEP_REQUIRED | (KEEP_OPTIONAL & set(current))
unknown = sorted(set(zeabur) - COPY - DROP - set(SET) - keep - HOLD)
if unknown:
    sys.exit('unclassified variables (add them to COPY, DROP, SET, KEEP or HOLD): ' + ', '.join(unknown))
missing = sorted(KEEP_REQUIRED - set(current))
if missing:
    sys.exit('not in the current app-env yet (run init-secrets.sh first): ' + ', '.join(missing))

out = {key: zeabur[key] for key in COPY & set(zeabur)}
held = zeabur if live else current
out.update({key: held[key] for key in HOLD & set(held)})
if HOLD:
    out['HELD_CREDENTIALS'] = 'live' if live else 'standby'  # cutover.sh 檢查這一行
out.update(SET)
out.update({key: current[key] for key in keep})
for key in out:
    check(key, out[key])  # 全部檢查過才輸出，失敗時不留半份檔案
for key in sorted(out):
    print(f'{key}={out[key]}')
