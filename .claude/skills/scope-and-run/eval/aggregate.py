# Merge grader output (work/grades/batch*.json), drop copies of the same run, print rates.
import json, glob, re, os, collections
WORK = os.environ.get('SAR_WORK', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'work'))
R = []
for f in sorted(glob.glob(os.path.join(WORK, 'grades', 'batch*.json'))): R += json.load(open(f))
conf = {'high': 3, 'medium': 2, 'low': 1}
best = {}
for r in R:
    if r.get('grade') == 'X': continue
    k = (r.get('date'), ' '.join(re.sub(r'[^a-z0-9 ]', '', r.get('request', '').lower()).split()[:5]))
    if k not in best or conf.get(r.get('confidence'), 0) > conf.get(best[k].get('confidence'), 0): best[k] = r
U = list(best.values()); json.dump(U, open(os.path.join(WORK, 'unique.json'), 'w'), indent=1)
n = len(U); g = collections.Counter(r['grade'] for r in U)
print(f'{n} runs', {k: f'{v} ({v/n:.0%})' for k, v in sorted(g.items())})
for field in ('skill_version', 'task_size'):
    for val in sorted({r.get(field) for r in U}, key=str):
        s = [r for r in U if r.get(field) == val]; c = collections.Counter(r['grade'] for r in s)
        print(f'{field}={val}: {len(s)} runs, A {c["A"]/len(s):.0%}, C+D {(c["C"]+c["D"])/len(s):.0%}')
bad = [r for r in U if r['grade'] in 'CD']
print('causes in C/D:', collections.Counter(c.split(':')[0] for r in bad for c in r.get('failure_causes', [])).most_common())
