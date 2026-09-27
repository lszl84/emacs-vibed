#!/usr/bin/env python3
# Summarise eu-stack samples: inclusive and self counts per function (main thread).
import sys, re, collections
data = open(sys.argv[1]).read().split("=====SAMPLE")
incl = collections.Counter(); selfc = collections.Counter(); n = 0
for s in data:
    frames = []
    for line in s.splitlines():
        m = re.match(r'#\d+\s+0x[0-9a-f]+\s+(\S+)', line)
        if m: frames.append(m.group(1))
        elif frames and line.startswith('TID'): break
    if not frames: continue
    n += 1
    selfc[frames[0]] += 1
    for f in set(frames): incl[f] += 1
top = int(sys.argv[2]) if len(sys.argv) > 2 else 40
print(f"samples: {n}")
print("-- self --")
for f, c in selfc.most_common(top): print(f"{100*c/n:5.1f}% {f}")
print("-- inclusive --")
for f, c in incl.most_common(top): print(f"{100*c/n:5.1f}% {f}")
