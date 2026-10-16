#!/usr/bin/env python3
"""Server time per session from a log written with log_min_duration_statement = 0.

Usage: qtime.py n1.log [n2.log ...]
Per backend: first/last timestamp, number of statements, total and max
statement duration, and the head of the longest statement."""
import re, sys
from collections import OrderedDict

HEAD = re.compile(r"^(\S+ \S+) \S+ \[(\d+)\] LOG:  duration: ([\d.]+) ms  (\w+)(?: \S+)?:\s*(.*)$")
for path in sys.argv[1:]:
    print(f"== {path}")
    s = OrderedDict()
    cur = None
    for line in open(path, errors="replace"):
        m = HEAD.match(line)
        if m:
            ts, pid, ms, kind, text = m.groups()
            e = s.setdefault(pid, dict(first=ts, last=ts, n=0, total=0.0, max=0.0, top=""))
            e["last"] = ts
            if kind in ("execute", "statement"):
                e["n"] += 1
                e["total"] += float(ms)
                if float(ms) > e["max"]:
                    e["max"], e["top"] = float(ms), text
                    cur = e
                else:
                    cur = None
            continue
        if cur is not None and line.startswith(("\t", " ")) and len(cur["top"]) < 160:
            cur["top"] += " " + line.strip()
    for pid, e in s.items():
        if e["total"] < 100:
            continue
        print(f"pid {pid} {e['first'][11:]}..{e['last'][11:]} stmts={e['n']:4} "
              f"total={e['total'] / 1000:7.2f}s max={e['max'] / 1000:6.2f}s  {e['top'][:160]}")
