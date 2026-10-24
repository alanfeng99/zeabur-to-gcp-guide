"""唯讀：印出服務的狀態；全部是 RUNNING 才以 0 結束（rollback.sh 等服務恢復時用）。

    python3 -I zeabur-status.py <service-id> [<service-id> ...]

ZEABUR_ENV_ID 從環境變數讀（zeabur-lib.sh 會 export），登入 token 從 ~/.config/zeabur/cli.yaml 讀。
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request

ENV_ID = os.environ['ZEABUR_ENV_ID']


def zeabur_token():
    path = os.path.expanduser('~/.config/zeabur/cli.yaml')
    try:
        for line in open(path):
            if line.strip().startswith('token:'):
                return line.split(':', 1)[1].strip().strip("'").strip('"')
    except FileNotFoundError:
        pass
    sys.exit(f'no Zeabur login in {path}: run npx zeabur@0.24.0 auth login')


TOKEN = zeabur_token()
STATUS = 'query($id: ObjectID!, $env: ObjectID!) { service(_id: $id) { name status(environmentID: $env) } }'


def gql(query, variables=None):
    req = urllib.request.Request(
        'https://api.zeabur.com/graphql',
        data=json.dumps({'query': query, 'variables': variables or {}}).encode(),
        # 預設的 Python User-Agent 會被擋（403）
        headers={'Authorization': f'Bearer {TOKEN}', 'Content-Type': 'application/json',
                 'User-Agent': 'zeabur-to-gcp-guide/1.0'},
    )
    try:
        res = json.load(urllib.request.urlopen(req, timeout=30))
    except urllib.error.HTTPError as e:
        # 查詢對不上 schema（欄位、參數、型別不見了）時回 422，原因在 body 的 errors 裡
        res = json.load(e) if e.code == 422 else {}
        if not res.get('errors'):
            sys.exit(f'Zeabur API: HTTP {e.code}' + (' (token expired: run npx zeabur@0.24.0 auth login)' if e.code == 401 else ''))
    if res.get('errors'):
        message = res['errors'][0].get('message', '')
        # 欄位或參數不見了：Zeabur 改版，zeabur-api-check.py 會列出所有受影響的地方
        changed = re.search(r'Cannot query field|Unknown argument|Unknown type', message)
        sys.exit('Zeabur API error: ' + message + (' (the API changed: run zeabur-api-check.py)' if changed else ''))
    return res['data']


if len(sys.argv) < 2:
    sys.exit(__doc__)
running = True
for sid in sys.argv[1:]:
    s = gql(STATUS, {'id': sid, 'env': ENV_ID})['service']
    print(f"{s['name']}: {s['status']}")
    running = running and s['status'] == 'RUNNING'
sys.exit(0 if running else 1)
