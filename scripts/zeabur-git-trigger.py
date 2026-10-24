"""把 Zeabur 服務的 Git 自動部署指向某個分支（透過 Zeabur GraphQL API）。

    python3 -I zeabur-git-trigger.py <branch> <service-id> [<service-id> ...]

Zeabur CLI 沒有停用自動部署的指令。把 Git trigger 指向一個不存在的分支
（例如 zeabur-decommissioned）就等於停用，改回 main 就恢復。不停用的話，
下次合併會把切換時暫停的服務重新部署、叫醒，變成兩套 worker 同時跑。

ZEABUR_ENV_ID 與 GITHUB_REPO_ID 從環境變數讀（zeabur-lib.sh 會 export），
登入 token 從 ~/.config/zeabur/cli.yaml 讀。token 過期時執行
`npx zeabur@0.24.0 auth login`：在網站上登入不會更新它。
"""
import json
import os
import sys
import urllib.request

ENV_ID = os.environ['ZEABUR_ENV_ID']
REPO_ID = int(os.environ['GITHUB_REPO_ID'])

TOKEN = next(line.split(':', 1)[1].strip().strip("'").strip('"')
             for line in open(os.path.expanduser('~/.config/zeabur/cli.yaml'))
             if line.strip().startswith('token:'))


def gql(query, variables):
    req = urllib.request.Request(
        'https://api.zeabur.com/graphql',
        data=json.dumps({'query': query, 'variables': variables}).encode(),
        # 預設的 Python User-Agent 會被擋（403）
        headers={'Authorization': f'Bearer {TOKEN}', 'Content-Type': 'application/json',
                 'User-Agent': 'zeabur-to-gcp-guide/1.0'},
    )
    res = json.load(urllib.request.urlopen(req, timeout=30))
    if res.get('errors'):
        sys.exit('Zeabur API error: ' + res['errors'][0].get('message', ''))
    return res['data']


READ = 'query($id: ObjectID!, $env: ObjectID!) { service(_id: $id) { name gitTrigger(environmentID: $env) { branchName } } }'
UPDATE = 'mutation($s: ObjectID!, $e: ObjectID!, $t: TriggerInput!) { updateGitTrigger(serviceID: $s, environmentID: $e, trigger: $t) }'

if __name__ == '__main__':
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    branch, ids = sys.argv[1], sys.argv[2:]
    for sid in ids:
        before = gql(READ, {'id': sid, 'env': ENV_ID})['service']
        gql(UPDATE, {'s': sid, 'e': ENV_ID, 't': {'repoID': REPO_ID, 'branchName': branch}})
        after = gql(READ, {'id': sid, 'env': ENV_ID})['service']
        old = (before['gitTrigger'] or {}).get('branchName')
        print(before['name'] + ': ' + str(old) + ' -> ' + after['gitTrigger']['branchName'])
        # 切換流程靠這一步：沒改成功就必須停下來
        if after['gitTrigger']['branchName'] != branch:
            sys.exit(before['name'] + ': branch was not changed')
