"""檢查 Markdown 裡的相對連結：檔案要存在，#錨點要對得上標題（照 GitHub 產生錨點的規則）。

    python3 -I tests/check_links.py        # 在 repo 根目錄執行
"""
import glob
import os
import re
import sys
import unicodedata


def slug(heading):
    text = re.sub(r'`|\*\*|\*|_(?=\W)|\[([^\]]*)\]\([^)]*\)', lambda m: m.group(1) or '', heading.strip()).lower()
    return ''.join(c for c in text if unicodedata.category(c)[0] in 'LMN' or c in ' -_').replace(' ', '-')


def anchors(path):
    found, seen, fence = set(), {}, False
    for line in open(path, encoding='utf-8'):
        if line.startswith('```'):
            fence = not fence
        m = None if fence else re.match(r'#{1,6}\s+(.*?)\s*#*\s*$', line)
        if m:
            s = slug(m.group(1))
            n = seen.get(s, 0)
            seen[s] = n + 1
            found.add(s if n == 0 else f'{s}-{n}')
    return found


broken = total = 0
for md in sorted(glob.glob('**/*.md', recursive=True)):
    if '.terraform' in md or 'node_modules' in md:
        continue
    text = re.sub(r'```.*?```', '', open(md, encoding='utf-8').read(), flags=re.S)
    for m in re.finditer(r'\]\(([^)\s]+)\)', text):
        url = m.group(1)
        if url.startswith(('http://', 'https://', 'mailto:')):
            continue
        total += 1
        path, _, frag = url.partition('#')
        target = os.path.normpath(os.path.join(os.path.dirname(md), path)) if path else md
        if not os.path.exists(target):
            print(f'{md}: missing {url}')
            broken += 1
        elif frag and target.endswith('.md') and frag not in anchors(target):
            print(f'{md}: no heading for {url}')
            broken += 1
print(f'{total} local links, {broken} broken')
sys.exit(1 if broken else 0)
