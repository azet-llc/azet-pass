#!/usr/bin/env python3
"""What moving this computer's key stores into AZET Pass would carry: names and counts only, never a value.
Reads the names in a .env file (default ~/.secrets/master.env) and in the tkt vault (`tkt list`), and reports how many
keys each holds, how many names they share, and what an import would have to decide (a name twice in the file with
different values). Values in the two stores are not compared: the vault opens one key per call, minutes for thousands.
usage: keystore-inventory.py [.env path]"""
import hashlib, os, re, subprocess, sys

path = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else '~/.secrets/master.env')
digest = lambda v: hashlib.sha256(v.encode()).hexdigest()
env, twice = {}, set()
for line in open(path, encoding='utf-8', errors='replace'):
    m = re.match(r'\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$', line.rstrip('\n'))
    if not m:
        continue
    name, value = m.group(1), m.group(2).strip().strip('"\'')
    if name in env and env[name] != digest(value):
        twice.add(name)
    env[name] = digest(value)  # the last line wins, as a shell that sources the file sees it
vault = [n for n in subprocess.run(['tkt', 'list'], capture_output=True, text=True).stdout.split() if re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', n)]
shared = [n for n in vault if n in env]
print(f'{os.path.basename(path)}: {len(env)} names ({sum(1 for v in env.values() if v == digest(""))} empty), {len(twice)} given twice with different values')
print(f'tkt vault: {len(vault)} names · in both: {len(shared)} · only in the vault: {len(vault) - len(shared)} · only in the file: {len(env) - len(shared)}')
print(f'one AZET Pass vault would hold {len(set(env) | set(vault))} keys')
