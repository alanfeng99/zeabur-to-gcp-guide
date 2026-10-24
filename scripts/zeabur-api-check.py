"""唯讀：確認這些腳本用到的 Zeabur API 欄位都還在。Zeabur 改版時要在盤點或切換之前就知道，不是切換到一半才壞。

    python3 -I zeabur-api-check.py                   # 問 Zeabur 的 API（introspection：只讀 schema，不讀任何專案資料）
    python3 -I zeabur-api-check.py --schema <file>   # 改用存下來的 introspection 結果（測試用）
    python3 -I zeabur-api-check.py --required        # 印出要檢查的查詢（JSON）

要檢查的欄位直接從同一個目錄的 zeabur-discover.py、zeabur-status.py、zeabur-git-trigger.py、
zeabur-inventory.py 的查詢字串讀出來，所以腳本改了查詢，這裡不用跟著改。另外加上 Zeabur CLI
（固定 0.24.0）的 service restart／redeploy／suspend 用的 mutation：cutover.sh 與 rollback.sh 靠它們。
CLI 的其他指令（exec、variable、deploy）沒辦法這樣檢查。登入 token 從 ~/.config/zeabur/cli.yaml 讀。
"""
import ast
import json
import os
import re
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = ('zeabur-discover.py', 'zeabur-status.py', 'zeabur-git-trigger.py', 'zeabur-inventory.py')
# CLI 指令背後的 mutation，以及 zeabur-inventory.py 說明裡反悔刪除用的那一個
CLI = '''mutation {
  restartService(serviceID: x, environmentID: x) redeployService(serviceID: x, environmentID: x)
  suspendService(serviceID: x, environmentID: x) cancelDeleteService(_id: x)
}'''
# 用變數傳進去的 input object 的欄位，查詢字串裡看不到
INPUTS = {'TriggerInput': ['repoID', 'branchName']}
# 標成 deprecated 的欄位還能用，預設卻不會列出來，不加 includeDeprecated 會誤報成不見了
INTROSPECTION = '''{ __schema { queryType { name } mutationType { name }
  types { name fields(includeDeprecated: true) { name args { name } type { ...T } } inputFields { name } } } }
fragment T on __Type { name ofType { name ofType { name ofType { name } } } }'''
LEXER = re.compile(r'[{}():]|[$\w]+|"[^"]*"')


def queries():
    """各腳本模組層級、內容是 GraphQL 的字串常數。"""
    found = []
    for name in SOURCES:
        tree = ast.parse(open(os.path.join(HERE, name), encoding='utf-8').read())
        for node in tree.body:
            if (isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name)
                    and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str)
                    and re.match(r'\s*(query\b|mutation\b|\{)', node.value.value) and node.targets[0].id.isupper()):
                found.append((f'{name}:{node.targets[0].id}', node.value.value))
    return found + [('Zeabur CLI', CLI)]


def parse(text):
    """GraphQL 文件 → (query|mutation, [(欄位, [參數名稱], 子欄位)], [變數的型別])。只支援這些腳本用到的寫法。"""
    toks = LEXER.findall(text)
    op = toks[0] if toks[0] in ('query', 'mutation') else 'query'
    start = toks.index('{')
    # 第一個 { 之前的 `$id: ObjectID!`：冒號後面就是型別（! 和 [ ] 不會被切出來）
    return op, selection(toks, start)[0], list(dict.fromkeys(toks[k + 1] for k in range(start) if toks[k] == ':'))


def selection(toks, i):
    """從 { 開始：回傳 (欄位, } 之後的位置)。GraphQL 的 ( ) 不會巢狀。"""
    i += 1
    fields = []
    while toks[i] != '}':
        name, args, children = toks[i], [], []
        i += 1
        if toks[i] == '(':
            j = toks.index(')', i)
            args = [a for a, nxt in zip(toks[i + 1:j], toks[i + 2:j]) if nxt == ':']
            i = j + 1
        if toks[i] == '{':
            children, i = selection(toks, i)
        fields.append((name, args, children))
    return fields, i + 1


def zeabur_token():
    path = os.path.expanduser('~/.config/zeabur/cli.yaml')
    try:
        for line in open(path):
            if line.strip().startswith('token:'):
                return line.split(':', 1)[1].strip().strip("'").strip('"')
    except FileNotFoundError:
        pass
    sys.exit(f'no Zeabur login in {path}: run npx zeabur@0.24.0 auth login')


def fetch_schema():
    req = urllib.request.Request(
        'https://api.zeabur.com/graphql',
        data=json.dumps({'query': INTROSPECTION}).encode(),
        # 預設的 Python User-Agent 會被擋（403）
        headers={'Authorization': f'Bearer {zeabur_token()}', 'Content-Type': 'application/json',
                 'User-Agent': 'zeabur-to-gcp-guide/1.0'},
    )
    try:
        res = json.load(urllib.request.urlopen(req, timeout=30))
    except urllib.error.HTTPError as e:
        sys.exit(f'Zeabur API: HTTP {e.code}' + (' (token expired: run npx zeabur@0.24.0 auth login)' if e.code == 401 else ''))
    if res.get('errors'):
        sys.exit('Zeabur API error: ' + res['errors'][0].get('message', ''))
    return res


def named(t):
    while t and not t.get('name'):
        t = t.get('ofType')
    return t and t['name']


def check(fields_of, type_name, fields, path):
    have = fields_of.get(type_name, {})
    for name, args, children in fields:
        here = f'{path}.{name}'
        if name not in have:
            yield f'{here}: field is gone'
            continue
        known, returns = have[name]
        yield from (f'{here}: argument {a} is gone' for a in args if a not in known)
        if children:
            yield from check(fields_of, returns, children, here)


def main():
    args = sys.argv[1:]
    ops = [(where, *parse(text)) for where, text in queries()]
    if args == ['--required']:
        print(json.dumps({'operations': ops, 'inputs': INPUTS}, ensure_ascii=False, indent=1))
        return
    if args[:1] == ['--schema'] and len(args) == 2:
        res = json.load(open(args[1]))
    elif not args:
        res = fetch_schema()
    else:
        sys.exit(__doc__)
    schema = res.get('data', res)['__schema']
    fields_of = {t['name']: {f['name']: ({a['name'] for a in f['args']}, named(f['type'])) for f in t.get('fields') or []}
                 for t in schema['types']}
    inputs_of = {t['name']: {f['name'] for f in t['inputFields']} for t in schema['types'] if t.get('inputFields') is not None}
    problems = []
    for where, op, fields, var_types in ops:
        # 整個 mutation type 不見時，每一個 mutation 照樣列成 Mutation.x: field is gone
        root = (schema.get(f'{op}Type') or {}).get('name') or op.title()
        problems += [f'{t}: type is gone  ({where})' for t in var_types if t not in fields_of]
        problems += [f'{p}  ({where})' for p in check(fields_of, root, fields, root)]
    for name, wanted in INPUTS.items():
        have = inputs_of.get(name)
        if have is None:
            problems.append(f'{name}: input type is gone')
        else:
            problems.extend(f'{name}.{f}: input field is gone' for f in wanted if f not in have)
    if problems:
        print('\n'.join(problems))
        sys.exit(f'{len(problems)} problem(s): the Zeabur API no longer matches these scripts. '
                 'Fix the queries (or the CLI steps) before going on; see "最後驗證" in the README')
    print(f'ok: all {len(ops)} queries and their fields still match the Zeabur API')


if __name__ == '__main__':
    main()
