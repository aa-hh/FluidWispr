import json, os, re, glob, datetime, sys
root = os.path.expanduser('~/.claude/projects')
THIS = os.environ.get('SAR_SKIP_SESSION', 'none')
pat = re.compile(r'<command-name>/?(scope-and-run[23]?)</command-name>|"skill"\s*:\s*"(?:scope-and-run:)?(scope-and-run[23]?)"')
rows = []
SINCE = os.environ.get('SAR_SINCE', '')  # YYYY-MM-DD: only runs on or after this date
WORK = os.environ.get('SAR_WORK', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'work')); os.makedirs(WORK, exist_ok=True)
for f in glob.glob(root + '/*/*.jsonl'):
    if THIS in f: continue
    try: txt = open(f, encoding='utf-8', errors='ignore').read()
    except: continue
    m = pat.findall(txt)
    if not m: continue
    vers = sorted({a or b for a, b in m})
    # first user request text after invocation
    args = re.findall(r'<command-args>(.*?)</command-args>', txt)
    args = [a for a in args if a.strip()]
    first_ts = re.search(r'"timestamp":"([^"]+)"', txt)
    sub = os.path.join(f[:-6], 'subagents')
    nsub = len(glob.glob(sub + '/*.jsonl')) if os.path.isdir(sub) else 0
    rows.append(dict(file=f.replace(root + '/', ''), vers=vers, ts=first_ts.group(1)[:10] if first_ts else '', size=len(txt), nsub=nsub, req=(args[0][:140] if args else '')))
rows = [r for r in rows if r['ts'] >= SINCE]
rows.sort(key=lambda r: r['ts'])
json.dump(rows, open(os.path.join(os.environ.get('SAR_WORK', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'work')), 'runs.json', 'w'), indent=1)
from collections import Counter
print(len(rows), 'sessions'); print(Counter(v for r in rows for v in r['vers']))
print('dates', rows[0]['ts'], '->', rows[-1]['ts'])
print('with subagent dirs', sum(1 for r in rows if r['nsub']))
for r in rows[:5]+rows[-5:]: print(r['ts'], r['vers'], r['nsub'], r['size']//1000, 'KB', r['req'][:90])
