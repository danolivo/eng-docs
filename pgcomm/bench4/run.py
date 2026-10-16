#!/usr/bin/env python3
"""Cold, single-thread trial on the local stand (setup.sh): pgcmp vs ACE 2.1.1.

Usage: run.py [--tables t_nb,t_bn] [--tools pgcmp,ace] [--reps 3]

Before every run both instances are restarted (shared_buffers is empty and
clamped to 16MB, the table is ~1 GB), then the heap and the PK are read into
the OS page cache with pg_prewarm(..., 'read'), which bypasses shared_buffers.
So a shared_buffers miss is always served from memory: without that step the
page cache was partially cold and run times varied 2x between repetitions.

Per run: wall, tool CPU and max RSS (/usr/bin/time -l), heap/PK-index
blks_hit/blks_read on both nodes (pg_statio_user_tables deltas), and the ids
the tool flagged checked against gt.csv. Appends to OUT/results.csv.
"""
import argparse, csv, decimal, glob, json, os, re, shutil, subprocess, time

R = os.path.expanduser("~/pgcmp-local")
BIN = f"{R}/bin"
OUT = f"{R}/out"
PORTS = {"n1": 5611, "n2": 5612}
ID_POS = {"t_nb": 1, "t_bn": 0, "t_b": 0}  # position of id in the PK (t_b: merge, bare integer)
ACE_CF = "0.05"                           # round(14 CPU x 0.05) = 1 worker
ACE_BLOCK = "100000"


def log(m):
    print(f"{time.strftime('%F %T')} {m}", flush=True)


def psql(port, sql):
    r = subprocess.run(["psql", "-X", "-At", "-h", "localhost", "-p", str(port), "-d", "bench", "-c", sql],
                       capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr)
    return r.stdout.strip()


def restart():
    for n in PORTS:
        subprocess.run(["pg_ctl", "-D", f"{R}/{n}", "-m", "fast", "-w", "-l", f"{R}/{n}.log", "restart"],
                       check=True, capture_output=True)
    for p in PORTS.values():
        assert psql(p, "SHOW shared_buffers") == "16MB"


def os_cache_warm(t):
    """pg_prewarm 'read' mode: pull the heap and the PK into the OS page cache
    without touching shared_buffers, so every run sees the same picture:
    a shared_buffers miss is served from memory, never from the SSD."""
    for p in PORTS.values():
        psql(p, f"SELECT pg_prewarm('{t}', 'read'), pg_prewarm('{t}_pkey', 'read')")


def io(port, t):
    v = psql(port, f"SELECT heap_blks_hit, heap_blks_read, idx_blks_hit, idx_blks_read "
                   f"FROM pg_statio_user_tables WHERE relname = '{t}'")
    return [int(x) for x in v.split("|")]


def to_id(x):
    return int(decimal.Decimal(str(x).strip().strip('"\'')))


def cmd_pgcmp(t, d, extra=()):
    return [f"{BIN}/pgcmp", "-dsn1", f"host=localhost port={PORTS['n1']} dbname=bench",
            "-dsn2", f"host=localhost port={PORTS['n2']} dbname=bench",
            "-table", t, "-j", "1", "-out", f"{d}/out.diff", *extra], None


def resolve_tool(name):
    """pgcmp_r<N>: hash blocks of at most N reference rows; -mem is lifted
    to 4GB so that only the row limit closes a block."""
    if name.startswith("pgcmp_r"):
        n = name[len("pgcmp_r"):]
        return (lambda t, d: cmd_pgcmp(t, d, ("-rows", n, "-mem", "4GB"))), flagged_pgcmp
    return TOOLS[name]


def flagged_pgcmp(t, d, _):
    ids = set()
    for line in open(f"{d}/out.diff"):
        tok = line.split(" ", 1)[0]
        if tok.strip() != "match":
            ids.add(to_id(tok.strip("()").split(",")[ID_POS[t]]))
    return ids


def cmd_ace(t, d):
    with open(f"{d}/pg_service.conf", "w") as f:
        f.write(f"[bench]\ndbname=bench\nhost=localhost\nuser={os.environ['USER']}\n\n"
                f"[bench.n1]\nhost=localhost\nport={PORTS['n1']}\n\n"
                f"[bench.n2]\nhost=localhost\nport={PORTS['n2']}\n")
    shutil.copy(f"{R}/ace-src/ace.yaml", f"{d}/ace.yaml")
    env = dict(os.environ, ACE_CONFIG=f"{d}/ace.yaml", PGSERVICEFILE=f"{d}/pg_service.conf",
               ACE_PGSERVICEFILE=f"{d}/pg_service.conf", ACE_TASKS_DB=f"{d}/ace_tasks.db")
    return [f"{BIN}/ace", "table-diff", "bench", f"public.{t}", "--nodes", "n1,n2", "-d", "bench",
            "-c", ACE_CF, "-b", ACE_BLOCK, "-o", "json", "-q"], env


def flagged_ace(t, d, _):
    files = sorted(glob.glob(f"{d}/*_diffs-*.json"))
    ids = set()
    if not files:
        return ids

    def walk(o):
        if isinstance(o, dict):
            if "id" in o and not isinstance(o["id"], (dict, list)):
                ids.add(to_id(o["id"]))
                return
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(json.load(open(files[-1])).get("diffs", {}))
    return ids


TOOLS = {"pgcmp": (cmd_pgcmp, flagged_pgcmp), "ace": (cmd_ace, flagged_ace)}
FIELDS = ["table", "rep", "tool", "rc", "wall_s", "user_s", "sys_s", "maxrss_mb",
          "n1_heap_hit", "n1_heap_read", "n1_idx_hit", "n1_idx_read",
          "n2_heap_hit", "n2_heap_read", "n2_idx_hit", "n2_idx_read",
          "flagged", "false_pos", "detected", "blocks", "started"]


def run_one(t, rep, tool, gt):
    d = f"{OUT}/{tool}_{t}_{rep}"
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    mk, flag = resolve_tool(tool)
    restart()
    os_cache_warm(t)
    cmd, env = mk(t, d)
    b1, b2 = io(PORTS["n1"], t), io(PORTS["n2"], t)
    started = time.strftime("%F %T")
    t0 = time.time()
    with open(f"{d}/log", "w") as lf:
        rc = subprocess.run(["/usr/bin/time", "-l", "-o", f"{d}/time"] + cmd,
                            stdout=lf, stderr=subprocess.STDOUT, env=env, cwd=d).returncode
    wall = time.time() - t0
    time.sleep(1.5)                                     # let backends flush their stats
    e1, e2 = io(PORTS["n1"], t), io(PORTS["n2"], t)
    tm = open(f"{d}/time").read()
    user = re.search(r"([\d.]+) user", tm).group(1)
    sys_ = re.search(r"([\d.]+) sys", tm).group(1)
    rss = int(re.search(r"(\d+)\s+maximum resident set size", tm).group(1)) / 2**20
    out = open(f"{d}/log", errors="replace").read()
    if tool == "ace" and " ERRO " in out:
        rc = 99                                        # ACE exits 0 on failure, too
    ids = flag(t, d, out) if rc in (0, 1) else set()
    truth = gt.get(t, {})
    det = {}
    for i, c in truth.items():
        det.setdefault(c, [0, 0])[1] += 1
        det[c][0] += i in ids
    row = dict(table=t, rep=rep, tool=tool, rc=rc, wall_s=f"{wall:.2f}", user_s=user, sys_s=sys_,
               maxrss_mb=f"{rss:.0f}", flagged=len(ids), false_pos=len(ids - truth.keys()),
               detected=";".join(f"{c}={a}/{b}" for c, (a, b) in sorted(det.items())), started=started,
               blocks=(re.findall(r"blocks: (\d+)", out) or [""])[-1])
    for n, b, e in (("n1", b1, e1), ("n2", b2, e2)):
        for k, x, y in zip(("heap_hit", "heap_read", "idx_hit", "idx_read"), b, e):
            row[f"{n}_{k}"] = y - x
    new = not os.path.exists(f"{OUT}/results.csv")
    with open(f"{OUT}/results.csv", "a", newline="") as f:
        w = csv.DictWriter(f, FIELDS)
        if new:
            w.writeheader()
        w.writerow(row)
    log(f"{t} r{rep} {tool:5} rc={rc} wall={wall:6.1f}s user={user}s blocks={row['blocks']} rss={row['maxrss_mb']}MB "
        f"n1 heap hit/read={row['n1_heap_hit']}/{row['n1_heap_read']} "
        f"idx={row['n1_idx_hit']}/{row['n1_idx_read']} flagged={len(ids)} fp={row['false_pos']} {row['detected']}")


def main():
    global OUT
    ap = argparse.ArgumentParser()
    ap.add_argument("--tables", default="t_nb,t_bn,t_b")
    ap.add_argument("--tools", default="pgcmp,ace")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args()
    OUT = a.out
    os.makedirs(OUT, exist_ok=True)
    gt = {}
    for tbl, i, cat in csv.reader(open(f"{R}/gt.csv")):
        gt.setdefault(tbl, {})[int(i)] = cat
    tools = a.tools.split(",")
    for t in a.tables.split(","):
        for rep in range(1, a.reps + 1):
            k = (rep - 1) % len(tools)
            for tool in tools[k:] + tools[:k]:
                run_one(t, rep, tool, gt)
    log("BENCH-DONE")


if __name__ == "__main__":
    main()
