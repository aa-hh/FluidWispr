import json, os, re, sys, glob
root = os.path.expanduser('~/.claude/projects')
out = os.path.join(os.environ.get('SAR_WORK', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'work')), 'digests'; os.makedirs(out, exist_ok=True)
runs = json.load(open(os.path.join(os.environ.get('SAR_WORK', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'work')), 'runs.json'))
def text_of(content):
    if isinstance(content, str): return content
    parts = []
    for c in content or []:
        if not isinstance(c, dict): continue
        t = c.get('type')
        if t == 'text': parts.append(c.get('text', ''))
        elif t == 'tool_result':
            cc = c.get('content')
            parts.append('[TOOL_RESULT] ' + (text_of(cc) if not isinstance(cc, str) else cc))
        elif t == 'tool_use':
            inp = c.get('input', {})
            if c.get('name') in ('Agent', 'Task'):
                parts.append(f"[LAUNCH AGENT {inp.get('subagent_type')} name={inp.get('name')} model={inp.get('model')}] " + str(inp.get('prompt', ''))[:600])
            elif c.get('name') == 'Skill':
                parts.append(f"[SKILL {inp.get('skill')}] {str(inp.get('args',''))[:300]}")
            elif c.get('name') in ('Edit', 'Write'):
                parts.append(f"[{c.get('name')} {inp.get('file_path')}]")
            elif c.get('name') == 'Bash':
                parts.append(f"[BASH] {str(inp.get('command',''))[:200]}")
    return '\n'.join(parts)
KEY = re.compile(r'APPROVED|CHANGES REQUESTED|REJECT|verdict|discrepanc|Skipped review|STOP|drift|failed|FAIL|regress|reverted|out of scope|out-of-scope', re.I)
for i, r in enumerate(runs):
    f = os.path.join(root, r['file']); lines = []
    for ln in open(f, encoding='utf-8', errors='ignore'):
        try: e = json.loads(ln)
        except: continue
        if e.get('type') not in ('user', 'assistant'): continue
        m = e.get('message') or {}
        t = text_of(m.get('content')).strip()
        if not t: continue
        role = e['type']
        is_tool = t.startswith('[TOOL_RESULT]')
        if role == 'user' and not is_tool and t.startswith('Base directory for this skill'):
            lines.append('\n[skill body loaded: ' + t.split('\n')[0][30:120] + ']'); continue
        if role == 'user' and not is_tool:
            if '<system-reminder>' in t and len(t) > 3000: t = re.sub(r'<system-reminder>.*?</system-reminder>', '', t, flags=re.S)
            lines.append(f"\n### USER ({e.get('timestamp','')[:16]})\n{t[:2500]}")
        elif role == 'user' and is_tool:
            # keep agent results / notifications, trimmed; keep keyword-bearing ones longer
            if 'agentId' in t or 'task-notification' in t or KEY.search(t[:4000]):
                lines.append(f"\n[tool/agent result] {t[:1800]}")
        else:
            lines.append(f"\n### ASSISTANT\n{t[:1500]}")
    body = '\n'.join(lines)
    # cap: keep head and tail if huge
    if len(body) > 90000: body = body[:30000] + '\n\n[... middle trimmed ...]\n\n' + body[-60000:]
    name = f"{i:03d}.md"; r['digest'] = name
    open(os.path.join(out, name), 'w').write(f"# Session {i:03d} | {r['ts']} | {r['vers']} | {r['file']}\n{body}")
json.dump(runs, open(os.path.join(os.environ.get('SAR_WORK', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'work')), 'runs.json', 'w'), indent=1)
sizes = sorted(os.path.getsize(os.path.join(out, x)) for x in os.listdir(out))
print(len(sizes), 'digests; KB min/median/max', sizes[0]//1000, sizes[len(sizes)//2]//1000, sizes[-1]//1000, 'total MB', sum(sizes)//1_000_000)
