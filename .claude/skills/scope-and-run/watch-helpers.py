#!/usr/bin/env python3
"""Exit (waking the main session) when a background helper stalls or all have finished.

Usage: watch-helpers.py <output_file> [<output_file> ...]
The output_file paths are the ones the Agent tool returns for each background launch.
"""
import json, os, sys, time

STALE_MIN = 20   # longer than the 10-minute Bash timeout, so a running build never counts
POLL_S = 60
MAX_HOURS = 6    # razor: fixed ceiling; make it an argument if runs ever legitimately go longer

def finished(path):
    try:
        with open(path, 'rb') as f:
            f.seek(0, 2); f.seek(max(0, f.tell() - 65536))
            last = f.read().splitlines()[-1]
        e = json.loads(last)
        return e.get('type') == 'assistant' and e.get('message', {}).get('stop_reason') == 'end_turn'
    except Exception:
        return False

start = time.time()
files = sys.argv[1:]
while True:
    running = [p for p in files if not finished(p)]
    if not running:
        print('ALL FINISHED'); sys.exit(0)
    for p in running:
        idle = (time.time() - os.path.getmtime(p)) / 60 if os.path.exists(p) else 0
        if idle >= STALE_MIN:
            print(f'STALE {idle:.0f} min: {p}'); sys.exit(0)
    if time.time() - start > MAX_HOURS * 3600:
        print('WATCHER TIMED OUT; still running: ' + ' '.join(running)); sys.exit(0)
    time.sleep(POLL_S)
