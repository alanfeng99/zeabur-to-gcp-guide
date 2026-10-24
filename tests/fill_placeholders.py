"""模擬使用者填設定：只改 check-placeholders.py 列出的那幾行，重跑到沒有剩下為止。

    python3 -I tests/fill_placeholders.py <模擬的使用者專案> <要檢查的目錄>...

先印出第一輪被列出的行（run.sh 用來檢查有沒有誤報），最後一行是 `final: <結果> <結束碼>`。
只改被列出的行很重要：整份檔案一起取代會連誤報也一起蓋掉，等於沒測。
"""
import re
import subprocess
import sys

root, tops = sys.argv[1], sys.argv[2:]
PLACEHOLDER = re.compile(r'<[a-z][a-z0-9_./-]*(?: [a-z0-9_./-]+)*>')
HIT = re.compile(r'^([^:]+):(\d+): ')

first = None
for _ in range(5):
    r = subprocess.run([sys.executable, '-I', 'deploy/migrate/check-placeholders.py', *tops],
                       cwd=root, capture_output=True, text=True)
    if first is None:
        first = r.stdout
    hits = [m for m in map(HIT.match, r.stdout.splitlines()) if m]
    if not hits:
        break
    for m in hits:
        path, n = f'{root}/{m.group(1)}', int(m.group(2))
        lines = open(path, encoding='utf-8').read().split('\n')
        lines[n - 1] = PLACEHOLDER.sub('filled', lines[n - 1]).replace('example.com', 'filled.test')
        open(path, 'w', encoding='utf-8').write('\n'.join(lines))
sys.stdout.write(first)
print('final:', r.stdout.strip().splitlines()[-1], r.returncode)
