"""在 Cloudflare 建立 email 一次性密碼登入（沒有的話）、後台的允許名單 policy 與 Access 應用。

    python3 -I cloudflare-access.py

先決條件：
1. 帳號擁有者已在 Cloudflare dashboard 開通 Zero Trust（取 team 名稱、選 Free 方案並完成
   結帳；0 元也要按最後確認，可能要先綁信用卡）。這一步 API 做不到，沒開通時 API 回
   access.api.error.not_enabled。
2. 有一個 API token：Access: Apps and Policies → Edit、Access: Organizations, Identity
   Providers, and Groups → Edit，Account Resources 只選這個帳號，設幾天後過期。
   `cloudflared tunnel login` 產生的憑證管不到 Access。
3. token 用隱藏輸入存進 macOS Keychain（會問兩次）：
   security add-generic-password -U -a "$USER" -s cloudflare-access-token -w

token 從 Keychain 讀，不印出來。跑完用無痕視窗確認：未登入會被導到
<team>.cloudflareaccess.com，允許名單外的 email 收不到驗證碼。

Access 只擋住「這個網域」。後台呼叫的 API 若在另一個公開網域，要把它收到後台網域底下
（templates/compose.example.yaml 的 admin-api 路由），並讓公開網域拒絕後台路徑。
"""
import json
import subprocess
import sys
import urllib.error
import urllib.request

ACCOUNT = '<cloudflare-account-id>'
DOMAIN = 'admin.example.com'
ALLOW = ['you@example.com']  # 要能收信：.local 之類的假信箱收不到一次性密碼

TOKEN = subprocess.run(['security', 'find-generic-password', '-s', 'cloudflare-access-token', '-w'],
                       capture_output=True, text=True, check=True).stdout.strip()


def call(method, path, body=None):
    req = urllib.request.Request(
        f'https://api.cloudflare.com/client/v4/accounts/{ACCOUNT}{path}', method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={'Authorization': f'Bearer {TOKEN}', 'Content-Type': 'application/json'})
    try:
        res = json.load(urllib.request.urlopen(req, timeout=30))
    except urllib.error.HTTPError as e:
        res = json.load(e)
    if not res.get('success'):
        sys.exit(method + ' ' + path + ': ' + json.dumps(res.get('errors'), ensure_ascii=False))
    return res['result']


call('GET', '/access/organizations')  # 沒開通 Zero Trust 會在這裡停
idps = call('GET', '/access/identity_providers')
otp = next((i for i in idps if i['type'] == 'onetimepin'), None) or call(
    'POST', '/access/identity_providers', {'name': 'One-time PIN', 'type': 'onetimepin', 'config': {}})
if any(a.get('domain') == DOMAIN for a in call('GET', '/access/apps')):
    sys.exit('an Access app for this domain already exists')
policy = call('POST', '/access/policies', {
    'name': 'Admin allow list', 'decision': 'allow', 'session_duration': '24h',
    'include': [{'email': {'email': e}} for e in ALLOW]})
app = call('POST', '/access/apps', {
    'name': 'Admin', 'type': 'self_hosted', 'domain': DOMAIN, 'session_duration': '24h',
    'allowed_idps': [otp['id']], 'auto_redirect_to_identity': True, 'app_launcher_visible': False,
    'policies': [{'id': policy['id'], 'precedence': 1}]})
print('created', app['name'], app['domain'])
