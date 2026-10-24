"""找出不該進公開 repo 的識別資訊：公開 IP、Zeabur 風格的 24 碼 ID、example.com 以外的 email。

    python3 -I tests/check_identifiers.py   # 在 repo 根目錄執行；檢查 git 追蹤中與未忽略的檔案

範例只能用 example.com 與 <...>。這支只抓得到有固定格式的東西：專案名稱、網域這類字串
發 PR 前還是要自己 grep 一次。
"""
import ipaddress
import re
import subprocess
import sys

# 文件與設定裡合法出現的公開網段：Google 的 IAP 與健康檢查來源
ALLOWED_NETWORKS = [ipaddress.ip_network(n) for n in ('35.235.240.0/20', '130.211.0.0/22', '35.191.0.0/16')]
IPV4 = re.compile(r'(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?![\d.])')
HEX_ID = re.compile(r'(?<![0-9a-f])[0-9a-f]{24}(?![0-9a-f])')
EMAIL = re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')
EMAIL_OK = re.compile(r'@(?:[a-z0-9-]+\.)*example\.com$|@users\.noreply\.github\.com$|^noreply@')

files = subprocess.run(['git', 'ls-files', '-co', '--exclude-standard'], capture_output=True, text=True, check=True).stdout.split()
hits = 0
for path in files:
    try:
        text = open(path, encoding='utf-8').read()
    except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
        continue
    for n, line in enumerate(text.splitlines(), 1):
        found = []
        for ip in IPV4.findall(line):
            try:
                addr = ipaddress.ip_address(ip)
            except ValueError:
                continue
            if addr.is_global and not any(addr in net for net in ALLOWED_NETWORKS):
                found.append(ip)
        found += HEX_ID.findall(line)
        found += [e for e in EMAIL.findall(line) if not EMAIL_OK.search(e)]
        if found:
            print(f'{path}:{n}: {", ".join(found)}')
            hits += 1
print(f'{len(files)} files, {hits} line(s) with identifiers')
sys.exit(1 if hits else 0)
