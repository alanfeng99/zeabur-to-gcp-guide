"""列出還沒換掉的佔位值：`<...>` 與 example.com。要印出 no placeholders left（結束碼 0）才能往下走。

    python3 -I check-placeholders.py <目錄>...

    python3 -I deploy/migrate/check-placeholders.py infra/gcp          # Phase 1 apply 前
    python3 -I deploy/migrate/check-placeholders.py deploy infra/gcp   # 第一次 release 前、切換前

只看會被執行或部署的內容：註解行與 Python 的模組說明（用法範例裡的 <...> 是給人看的）不算。
"""
import ast
import os
import re
import sys

PLACEHOLDER = re.compile(r'<[a-z][a-z0-9_./-]*(?: [a-z0-9_./-]+)*>|example\.com')
# 給人看的說明與比對用的樣式不算：用法訊息 ${1:?usage: …}、die "…"、Terraform 的 description、
# zeabur-lib.sh 的 require 用來擋佔位值的 *example.com*
PROSE = re.compile(r'\$\{\d:\?[^}]*\}|\bdie "[^"]*"|^description\s*=\s*"[^"]*"|\*example\.com\*')
# 行尾註解裡的範例也不算（`VOLUMES=''   # 例如 '<api-service-id>:…'`）
COMMENT = re.compile(r'\s(?:#|//)\s')
SUFFIXES = ('.sh', '.py', '.js', '.ts', '.yaml', '.yml', '.tf', '.tfvars')
NAMES = ('Caddyfile', 'Dockerfile')


def docstring_lines(path):
    try:
        tree = ast.parse(open(path, encoding='utf-8').read())
    except SyntaxError:
        return set()
    if ast.get_docstring(tree, clean=False) is None:
        return set()
    first = tree.body[0]
    return set(range(first.lineno, first.end_lineno + 1))


tops = sys.argv[1:] or sys.exit(__doc__)
hits = 0
for top in tops:
    if not os.path.isdir(top):
        sys.exit(f'not a directory: {top}')
    for dp, dn, fn in os.walk(top):
        dn[:] = [d for d in dn if d not in ('.terraform', 'node_modules', '.git')]
        for f in sorted(fn):
            if not (f.endswith(SUFFIXES) or f in NAMES):
                continue
            path = os.path.join(dp, f)
            skip = docstring_lines(path) if f.endswith('.py') else set()
            for n, line in enumerate(open(path, encoding='utf-8', errors='replace'), 1):
                text = line.strip()
                code = PROSE.sub('', COMMENT.split(text, maxsplit=1)[0])
                if n in skip or text.startswith(('#', '//')) or not PLACEHOLDER.search(code):
                    continue
                print(f'{path}:{n}: {text[:120]}')
                hits += 1
print(f'{hits} placeholder(s) left' if hits else 'no placeholders left')
sys.exit(1 if hits else 0)
