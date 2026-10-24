"""唯讀：列出 Zeabur 帳號下所有專案、服務、狀態、網域與預定刪除時間。

    python3 -I zeabur-inventory.py

關帳號前跑一次（同一個帳號常常還有別的正式網站），刪除服務後也跑一次：
`zeabur service delete` 只是先暫停，2 小時後才真的刪除，這段期間
`service list` 仍看得到。反悔可用 GraphQL mutation
`cancelDeleteService(_id: "<service-id>")` 撤銷。
"""
import json
import os
import sys
import urllib.request

TOKEN = next(line.split(':', 1)[1].strip().strip("'").strip('"')
             for line in open(os.path.expanduser('~/.config/zeabur/cli.yaml'))
             if line.strip().startswith('token:'))


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
