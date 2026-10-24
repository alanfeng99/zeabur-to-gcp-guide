"""唯讀：列出 Zeabur 帳號下所有專案、服務、狀態、網域與預定刪除時間。

    python3 -I zeabur-inventory.py

關帳號前跑一次（同一個帳號常常還有別的正式網站），刪除服務後也跑一次：
`zeabur service delete` 只是先暫停，2 小時後才真的刪除，這段期間
`service list` 仍看得到。反悔可用 GraphQL mutation
`cancelDeleteService(_id: "<service-id>")` 撤銷。
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request


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


PROJECTS = '{ projects { edges { node { _id name environments { _id } services { _id name domains { domain } } } } } }'
STATUS = 'query($id: ObjectID!, $env: ObjectID!) { service(_id: $id) { status(environmentID: $env) scheduledDeleteAt } }'

for edge in gql(PROJECTS, {})['projects']['edges']:
    p = edge['node']
    print(p['name'] + ': ' + str(len(p['services'] or [])) + ' service(s)')
    for s in p['services'] or []:
        domains = ', '.join(d['domain'] for d in s['domains'] or []) or '-'
        for env in p['environments']:
            st = gql(STATUS, {'id': s['_id'], 'env': env['_id']})['service']
            print(f"  {s['name']:<20} {st['status']:<10} delete at {st['scheduledDeleteAt'] or '-'}  {domains}")
