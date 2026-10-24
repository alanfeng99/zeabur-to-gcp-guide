"""唯讀：印出服務的狀態；全部是 RUNNING 才以 0 結束（rollback.sh 等服務恢復時用）。

    python3 -I zeabur-status.py <service-id> [<service-id> ...]

ZEABUR_ENV_ID 從環境變數讀（zeabur-lib.sh 會 export），登入 token 從 ~/.config/zeabur/cli.yaml 讀。
"""
import json
import os
import sys
import urllib.request

ENV_ID = os.environ['ZEABUR_ENV_ID']
TOKEN = next(line.split(':', 1)[1].strip().strip("'").strip('"')
             for line in open(os.path.expanduser('~/.config/zeabur/cli.yaml'))
             if line.strip().startswith('token:'))
STATUS = 'query($id: ObjectID!, $env: ObjectID!) { service(_id: $id) { name status(environmentID: $env) } }'


def gql(query, variables):
    req = urllib.request.Request(
        'https://api.zeabur.com/graphql',
        data=json.dumps({'query': query, 'variables': variables}).encode(),
        headers={'Authorization': f'Bearer {TOKEN}', 'Content-Type': 'application/json',
                 'User-Agent': 'zeabur-to-gcp-guide/1.0'},
    )
    res = json.load(urllib.request.urlopen(req, timeout=30))
    if res.get('errors'):
        sys.exit('Zeabur API error: ' + res['errors'][0].get('message', ''))
    return res['data']


if len(sys.argv) < 2:
    sys.exit(__doc__)
running = True
for sid in sys.argv[1:]:
    s = gql(STATUS, {'id': sid, 'env': ENV_ID})['service']
    print(f"{s['name']}: {s['status']}")
    running = running and s['status'] == 'RUNNING'
sys.exit(0 if running else 1)
