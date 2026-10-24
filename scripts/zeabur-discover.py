"""唯讀盤點：把一個 Zeabur 專案整理成盤點表與適用性檢查（Markdown），並列出建議的 zeabur-lib.sh 設定。

    python3 -I zeabur-discover.py                     # 列出帳號下的專案
    python3 -I zeabur-discover.py <專案名稱或 ID>      # 印出盤點表
    python3 -I zeabur-discover.py <專案> > inventory.md

只讀 metadata：服務、image、volume 與用量、網域、Git 自動部署、環境變數的「名稱」。
環境變數的值一律不讀、不印。登入 token 從 ~/.config/zeabur/cli.yaml 讀
（過期就執行 `npx zeabur@0.24.0 auth login`）。

適用性檢查的依據是這份指南涵蓋的架構：Node／Next.js 類的 app 服務、Postgres、Redis、
MinIO（或其他 S3 相容儲存）。其他組合會標成「要調整」或「不在涵蓋範圍」，並說明原因。
"""
import json
import os
import re
import sys
import urllib.request

TOKEN = next(line.split(':', 1)[1].strip().strip("'").strip('"')
             for line in open(os.path.expanduser('~/.config/zeabur/cli.yaml'))
             if line.strip().startswith('token:'))


def gql(query, variables=None):
    req = urllib.request.Request(
        'https://api.zeabur.com/graphql',
        data=json.dumps({'query': query, 'variables': variables or {}}).encode(),
        headers={'Authorization': f'Bearer {TOKEN}', 'Content-Type': 'application/json',
                 'User-Agent': 'zeabur-to-gcp-guide/1.0'},
    )
    res = json.load(urllib.request.urlopen(req, timeout=30))
    if res.get('errors'):
        sys.exit('Zeabur API error: ' + res['errors'][0].get('message', ''))
    return res['data']


PROJECTS = '{ projects { edges { node { _id name environments { _id name } services { _id name } } } } }'
SERVICE = '''query($id: ObjectID!, $env: ObjectID!) { service(_id: $id) {
  name template marketItemCode marketplaceItem { code name }
  status(environmentID: $env) suspendedAt scheduledDeleteAt
  image(environmentID: $env) { reference name tag }
  volumes(environmentID: $env) { dir usage }
  domains(environmentID: $env) { domain }
  gitTrigger(environmentID: $env) { branchName repoID }
  variables(environmentID: $env, exposed: false) { key readonly }
} }'''

# 哪些環境變數幾乎一定要改或拿掉（其他的先當「照抄」，再由人確認）
CHANGE = re.compile(r'(_URL|_URI|_HOST|_DOMAIN|_ORIGINS?|_ENDPOINT|_PORT|CONNECTION_STRING)$|^(DATABASE_URL|REDIS_URL|PORT|HOSTNAME)$')
DROP = re.compile(r'^(ZBPACK_|ZEABUR_)')
KEY = re.compile(r'(ENCRYPT|CIPHER|CRYPTO).*KEY|KEY.*(ENCRYPT|CIPHER)')


def mb(n):
    return f'{(n or 0) / 1048576:.1f} MB'


def classify(svc):
    """回傳 (類型, 說明)。依 image 判斷；Zeabur 自己建置的 image 是 app。"""
    ref = ((svc['image'] or {}).get('reference') or '').lower()
    name = svc['name'].lower()
    keys = {v['key'] for v in svc['variables'] or [] if not v['readonly']}
    if 'registry-oci.zeabur.cloud' in ref or not ref:
        if any(k.startswith('WORDPRESS_') for k in keys) or 'wordpress' in name:
            return 'app-wordpress', 'WordPress（PHP）'
        role = 'web' if svc['domains'] else 'worker'
        return 'app', f'由原始碼建置的 app（{"有網域" if role == "web" else "沒有網域：可能是 worker"}）'
    for pat, kind, label in [
        (r'pgvector|postgres|postgis|timescale', 'postgres', 'Postgres'),
        (r'redis|valkey|keydb|dragonfly', 'redis', 'Redis'),
        (r'minio', 'minio', 'MinIO（S3 相容）'),
        (r'mariadb|mysql', 'mysql', 'MySQL／MariaDB'),
        (r'mongo', 'mongo', 'MongoDB'),
        (r'clickhouse|elasticsearch|opensearch|meilisearch|typesense|qdrant|rabbitmq|kafka|nats', 'other-data', '其他資料服務'),
    ]:
        if re.search(pat, ref):
            return kind, label
    return 'image', '直接部署的 image'


def pg_major(ref):
    m = re.search(r'(?:pg|postgres(?:ql)?:)(\d+)', ref or '')
    return m.group(1) if m else None


def main():
    projects = [e['node'] for e in gql(PROJECTS)['projects']['edges']]
    if len(sys.argv) < 2:
        print('帳號下的專案（用名稱或 ID 指定一個）：')
        for p in projects:
            print(f"  {p['name']:<24} {p['_id']}  {len(p['services'] or [])} service(s)")
        return
    want = sys.argv[1]
    matches = [p for p in projects if want in (p['name'], p['_id'])]
    if len(matches) != 1:
        sys.exit(f'no single project named or with ID {want!r}')
    p = matches[0]
    if len(p['environments']) != 1:
        print(f"> 注意：這個專案有 {len(p['environments'])} 個 environment，以下只看第一個（{p['environments'][0]['name']}）。\n")
    env = p['environments'][0]['_id']
    services = [dict(gql(SERVICE, {'id': s['_id'], 'env': env})['service'], _id=s['_id']) for s in p['services'] or []]
    for s in services:
        s['kind'], s['label'] = classify(s)

    print(f"# Zeabur 盤點：{p['name']}\n")
    print(f"專案 ID `{p['_id']}`，environment `{env}`。只讀 metadata，不含任何環境變數的值。\n")

    print('## 服務\n')
    print('| 服務 | 類型 | image | 狀態 | 網域 | volume（用量） | Git 自動部署 |')
    print('| --- | --- | --- | --- | --- | --- | --- |')
    for s in services:
        img = (s['image'] or {}).get('reference') or '-'
        if 'registry-oci.zeabur.cloud' in img:
            img = '（Zeabur 建置）'
        vols = ', '.join(f"`{v['dir']}`（{mb(v['usage'])}）" for v in s['volumes'] or []) or '-'
        doms = ', '.join(d['domain'] for d in s['domains'] or []) or '-'
        git = (s['gitTrigger'] or {}).get('branchName') or '-'
        status = s['status'] + ('，排定刪除' if s['scheduledDeleteAt'] else '')
        print(f"| {s['name']} | {s['label']} | {img} | {status} | {doms} | {vols} | {git} |")

    print('\n## 適用性檢查\n')
    ok, adapt, out = [], [], []
    kinds = [s['kind'] for s in services]
    for s in services:
        k, n = s['kind'], s['name']
        if k == 'postgres':
            major = pg_major((s['image'] or {}).get('reference'))
            ok.append(f"{n}：Postgres{' ' + major if major else ''}，用 sync-db.sh 搬；GCP 用同一個 major 版本"
                      + ('（含 pgvector：image 用 pgvector/pgvector）' if 'pgvector' in (s['image'] or {}).get('reference', '') else ''))
        elif k == 'redis':
            ref = (s['image'] or {}).get('reference', '')
            ok.append(f'{n}：Redis 不搬資料，排空後在 GCP 重建')
            if 'stack' in ref:
                adapt.append(f'{n}：image 是 `{ref}`（含 RedisJSON、Search 等模組）。GCP 用同一個 image；它的 entrypoint 不吃 command，'
                             '要用 REDIS_ARGS 環境變數設 --appendonly yes --maxmemory-policy noeviction（見 compose 範本的 redis）')
            elif 'valkey' in ref or 'keydb' in ref or 'dragonfly' in ref:
                adapt.append(f'{n}：image 是 `{ref}`，GCP 用同一個 image，確認啟動參數與 noeviction 設定')
        elif k == 'minio':
            ok.append(f'{n}：MinIO 的物件用 sync-assets.sh 複製到 GCS（key 不變）')
        elif k == 'app':
            ok.append(f"{n}：app 服務，由 Cloud Build 建 image、compose 執行（{'對外' if s['domains'] else 'worker／背景'}）")
            if s['volumes']:
                adapt.append(f"{n}：app 服務有 volume（{', '.join(v['dir'] for v in s['volumes'])}），檔案存在 volume 上而不是 MinIO。"
                             '用 sync-volume.sh 搬到 VM 的資料碟、compose 掛回同一個路徑（填 zeabur-lib.sh 的 VOLUMES，'
                             'verify 用 FILES_CHECK=vm:<目錄>）；最後封存也要包含它')
        elif k == 'app-wordpress':
            out.append(f'{n}：WordPress（PHP）。compose 範本、healthcheck 與部署流程是給 Node 服務的，要另外改寫')
        elif k == 'mysql':
            out.append(f'{n}：MySQL／MariaDB。資料庫腳本只支援 Postgres：要改用 mysqldump／mariadb-dump，逐表筆數也要換寫法')
        elif k == 'mongo':
            out.append(f'{n}：MongoDB。不在涵蓋範圍：要改用 mongodump／mongorestore')
        elif k == 'other-data':
            out.append(f"{n}：{(s['image'] or {}).get('reference')}。不在涵蓋範圍：要自己設計搬移方式")
        else:
            adapt.append(f"{n}：直接部署的 image `{(s['image'] or {}).get('reference')}`：放進 compose，確認它有沒有要搬的資料")
        if s['status'] != 'RUNNING':
            adapt.append(f"{n}：目前狀態是 {s['status']}，確認它還要不要搬")
    custom = [d['domain'] for s in services for d in s['domains'] or [] if not d['domain'].endswith('.zeabur.app')]
    if custom:
        adapt.append(f"Zeabur 上已綁自有網域（{', '.join(custom)}）。沿用它們、切換當晚只改 DNS 的話，GCP 要在那之前就有憑證："
                     'Traefik 改用 DNS-01（compose 範本 traefik 的註解），切換前用另一個測試網域驗證；這條路還沒有完整實跑過。'
                     'GCP 改用新網域的話，這些網域在切換後轉址過去')
    triggers = {(t['repoID'], t['branchName']) for t in (s['gitTrigger'] for s in services) if t}
    if len(triggers) > 1:
        adapt.append('Git 自動部署來自不同的 repo 或分支（' + '、'.join(f'repo {r} 的 {b}' for r, b in sorted(triggers, key=str)) + '）：'
                     'zeabur-lib.sh 只有一組 GITHUB_REPO_ID／ZEABUR_GIT_BRANCH，切換與 rollback 時要依 repo 分開跑 zeabur-git-trigger.py')
    if 'postgres' not in kinds and 'mysql' not in kinds and 'mongo' not in kinds:
        adapt.append('沒有找到資料庫服務：如果資料庫在 Zeabur 以外（例如外部的託管資料庫），資料搬移步驟要跳過或改寫')
    if not any(k.startswith('app') for k in kinds):
        adapt.append('沒有找到 app 服務：這份指南的部署流程假設有自己建置的 app')
    for title, items in [('照指南就能做', ok), ('要調整', adapt), ('不在涵蓋範圍', out)]:
        print(f'**{title}**\n')
        print('\n'.join(f'- {i}' for i in items) if items else '- （無）')
        print()
    verdict = '不適用：有不在涵蓋範圍的服務，先決定怎麼處理再開始' if out else (
        '大致適用：先處理「要調整」的項目' if adapt else '適用：可以照指南進行')
    print(f'**結論：{verdict}。**\n')

    print('## 環境變數（只有名稱）\n')
    print('分類是依名稱猜的起點，每一個都要人確認；加密金鑰之類的值一個 byte 都不能改。\n')
    for s in services:
        own = sorted(v['key'] for v in s['variables'] or [] if not v['readonly'])
        if not own:
            continue
        print(f"**{s['name']}**（{len(own)} 個）\n")
        print('| 變數 | 建議 |')
        print('| --- | --- |')
        for k in own:
            hint = ('一個 byte 都不能改：另存一個 secret，比對指紋' if KEY.search(k) else
                    '拿掉（Zeabur 專用）' if DROP.search(k) else
                    '要改：指向 GCP 的服務或新網域' if CHANGE.search(k) else '照抄？')
            print(f'| `{k}` | {hint} |')
        print()

    print('## 進站網址（切換當晚要處理）\n')
    doms = [(s['name'], d['domain']) for s in services for d in s['domains'] or []]
    print('\n'.join(f'- `{d}`（{n}）：DNS 或轉址；外部系統裡用到這個網址的 webhook、callback、寄出去的連結都要列進盤點表' for n, d in doms) or '- （無）')

    print('\n## 建議的 zeabur-lib.sh 設定\n')
    print('依類型猜的對應，請確認後再填；沒有對應的就保留 `<...>`。\n')
    def pick(kind, pred=lambda s: True):
        return next((s['_id'] for s in services if s['kind'] == kind and pred(s)), None)

    rows = [
        ('ZEABUR_PROJECT_ID', p['_id']),
        ('ZEABUR_ENV_ID', env),
        ('ZEABUR_POSTGRES_ID', pick('postgres')),
        ('ZEABUR_WORKER_ID', pick('app', lambda s: not s['domains'])),
    ]
    def slug(t):
        return re.sub(r'[^a-z0-9]+', '-', t.lower()).strip('-')

    vols = ' '.join(f"{s['_id']}:{v['dir']}:/srv/data/{slug(s['name'])}-{slug(v['dir'])}"
                    for s in services if s['kind'] == 'app' for v in s['volumes'] or [])
    minio = pick('minio')
    trigger = next((s['gitTrigger'] for s in services if s['kind'] == 'app' and s['gitTrigger']), {})
    rows += [('GITHUB_REPO_ID', trigger.get('repoID', '')), ('ZEABUR_GIT_BRANCH', trigger.get('branchName', ''))]
    print('```bash')
    for k, v in rows:
        export = '' if k == 'ZEABUR_GIT_BRANCH' else 'export '
        empty = '' if k in ('GITHUB_REPO_ID', 'ZEABUR_GIT_BRANCH') else '<' + k.lower().replace('_', '-') + '>'
        print(f"{export}{k}='{v if v is not None and v != '' else empty}'")
    if not trigger:
        print('# 沒有服務設定 Git 自動部署（用上傳部署）：GITHUB_REPO_ID 與 ZEABUR_GIT_BRANCH 留空，切換時跳過')
    keys = sorted({v['key'] for s in services if s['kind'] == 'app' for v in s['variables'] or [] if KEY.search(v['key'])})
    print(f"ENCRYPTION_KEY_VAR='{keys[0] if len(keys) == 1 else ''}'")
    if not keys:
        print('# 沒找到像加密金鑰的變數名稱：確認 app 真的沒有加密金鑰才留空')
    elif len(keys) > 1:
        print(f"# 像加密金鑰的變數有好幾個（{', '.join(keys)}）：sync-env.sh 只處理一個，其他的放進 build-app-env.py 的 COPY 並逐一比對指紋")
    print(f"ZEABUR_MINIO_ID='{minio or ''}'")
    print(f"VOLUMES='{vols}'")
    if vols:
        print("FILES_CHECK='vm:<上面其中一個 VM 目錄>'")
    elif not minio:
        print("# 沒有 MinIO 也沒有 volume：沒有要搬的檔案（app 的檔案若存在外部服務，切換時不動）")
        print("FILES_CHECK='none'")
        print("FILES_KEY_QUERY=''")
    for s in services:
        if s['kind'] == 'app' and s['domains']:
            print(f"# app 服務 {s['name']}（{', '.join(d['domain'] for d in s['domains'])}）：ID {s['_id']}"
                  ' → 依角色填進 ZEABUR_API_ID／ZEABUR_WEB_ID／ZEABUR_ADMIN_ID')
    print("# ENV_SERVICE_IDS：環境變數要合併進 app-env 的 app 服務（通常是上面全部的 app）")
    print("# OLD_WEB_URL／OLD_ADMIN_URL：前台與後台在 Zeabur 上目前的網址（上面列的網域）")
    print("# GCP_*、ASSETS_*、NEW_*_URL：來自 infra/gcp/tf.sh output 與你選定的網域")
    print('```')


if __name__ == '__main__':
    main()
