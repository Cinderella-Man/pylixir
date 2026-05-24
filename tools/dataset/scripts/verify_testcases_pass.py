#!/usr/bin/env python3
"""Re-run every v3 solution against its shipped testcases and confirm the
output matches the stored `expected` under the dataset normalizer.

Read-only integrity check on the OUTPUT. Reports how many rows have ALL
testcases passing, and lists any row that doesn't.

    python3 scripts/verify_testcases_pass.py [out/v3/data.parquet]
"""
import sys, os, json, re, resource, subprocess, tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
import pyarrow.parquet as pq

PARQUET = sys.argv[1] if len(sys.argv) > 1 else "out/v3/data.parquet"
PYTHON = "python3.14"
TIMEOUT = 20          # matches build per-run wall-clock budget
MAX_OUT = 8 << 20     # cap captured stdout (bytes)
WORKERS = 32

def normalize(b: bytes) -> str:
    try:
        s = b.decode("utf-8")
    except UnicodeDecodeError:
        s = b.decode("latin-1")
    s = s.replace("\r\n", "\n")
    s = "\n".join(re.sub(r"[ \t]+$", "", ln) for ln in s.split("\n"))
    return s.rstrip("\n")

def _limits():
    resource.setrlimit(resource.RLIMIT_AS, (2 << 30, 2 << 30))   # 2 GB addr space
    resource.setrlimit(resource.RLIMIT_CPU, (TIMEOUT, TIMEOUT + 2))

def run_one(script_path, stdin, expected, cwd):
    try:
        p = subprocess.run(
            [PYTHON, script_path], input=stdin.encode(), cwd=cwd,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=TIMEOUT, preexec_fn=_limits, start_new_session=True,
        )
    except subprocess.TimeoutExpired:
        return ("timeout", "")
    if p.returncode != 0:
        return ("exit_%d" % p.returncode, "")
    out = p.stdout[:MAX_OUT]
    got = normalize(out)
    return (None, got) if got == expected else ("mismatch", got)

def check_row(rid, source, testcases):
    """Run testcases until the first failure; return (rid, ntc, fail or None)."""
    with tempfile.TemporaryDirectory(prefix="vt_") as d:
        sp = os.path.join(d, "main.py")
        with open(sp, "w") as f:
            f.write(source)
        for i, tc in enumerate(testcases):
            reason, _ = run_one(sp, tc["stdin"], tc["expected"], d)
            if reason:
                return (rid, len(testcases), (i, reason))
    return (rid, len(testcases), None)

def main():
    t = pq.read_table(PARQUET, columns=["id", "source", "testcases"])
    ids = t.column("id").to_pylist()
    srcs = t.column("source").to_pylist()
    tcs = [json.loads(x) for x in t.column("testcases").to_pylist()]
    N = len(ids)
    print(f"verifying {N} rows / {sum(len(x) for x in tcs)} testcases "
          f"({PYTHON}, timeout {TIMEOUT}s, {WORKERS} workers)", flush=True)

    full_pass = 0
    failures = []
    done = 0
    # as_completed (not submission order) so progress reflects real throughput
    # and a few slow rows can't hide the thousands already finished.
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        futs = [ex.submit(check_row, ids[i], srcs[i], tcs[i]) for i in range(N)]
        for fut in as_completed(futs):
            rid, ntc, fail = fut.result()
            done += 1
            if fail is None:
                full_pass += 1
            else:
                failures.append((rid, ntc, fail))
                print(f"  FAIL {rid}: testcase {fail[0]}/{ntc} -> {fail[1]}", flush=True)
            if done % 500 == 0:
                print(f"  {done}/{N} rows checked, {len(failures)} failing so far", flush=True)

    print(f"\nrows fully passing: {full_pass}/{N}")
    print(f"rows with >=1 failing testcase: {len(failures)}")
    for rid, ntc, (idx, reason) in failures[:60]:
        print(f"  FAIL {rid}: testcase {idx}/{ntc} -> {reason}")
    if len(failures) > 60:
        print(f"  ... and {len(failures)-60} more")

if __name__ == "__main__":
    main()
