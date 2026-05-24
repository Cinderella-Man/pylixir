#!/usr/bin/env python3
"""Cross-check the v3 output against the build's verdict cache — no execution.

For every shipped testcase, recompute the cache key sha256(source \\0 stdin),
look it up in cache/verify.jsonl, and confirm the recorded verdict is
`reproducible` with `canonical == expected`. This is the build's own record of
"this solution deterministically produces this output on this input", so a
full hit set means every shipped testcase passed verification.

    python3 scripts/verify_against_cache.py [out/v3/data.parquet] [cache/verify.jsonl]
"""
import sys, json, hashlib
import pyarrow.parquet as pq

PARQUET = sys.argv[1] if len(sys.argv) > 1 else "out/v3/data.parquet"
CACHE = sys.argv[2] if len(sys.argv) > 2 else "cache/verify.jsonl"

print(f"loading cache {CACHE} ...", flush=True)
verdict = {}   # sha256 -> (status, canonical|None)
n = 0
with open(CACHE) as f:
    for line in f:
        if not line.strip():
            continue
        e = json.loads(line)
        verdict[e["sha256"]] = (e.get("status"), e.get("canonical"))
        n += 1
        if n % 100000 == 0:
            print(f"  {n} cache entries", flush=True)
print(f"cache entries: {len(verdict)}", flush=True)

t = pq.read_table(PARQUET, columns=["id", "source", "testcases"])
ids = t.column("id").to_pylist()
srcs = t.column("source").to_pylist()
tcs = [json.loads(x) for x in t.column("testcases").to_pylist()]
N = len(ids)

rows_ok = 0
tot_tc = 0
problems = []   # (id, tc_idx, kind)
for rid, src, row_tcs in zip(ids, srcs, tcs):
    row_ok = True
    for i, tc in enumerate(row_tcs):
        tot_tc += 1
        key = hashlib.sha256(src.encode() + b"\x00" + tc["stdin"].encode()).hexdigest()
        v = verdict.get(key)
        if v is None:
            problems.append((rid, i, "no_cache_entry")); row_ok = False
        elif v[0] != "reproducible":
            problems.append((rid, i, f"status={v[0]}")); row_ok = False
        elif v[1] != tc["expected"]:
            problems.append((rid, i, "canonical!=expected")); row_ok = False
    if row_ok:
        rows_ok += 1

print(f"\nrows: {N}, testcases: {tot_tc}")
print(f"rows where every testcase is a verified-reproducible hit: {rows_ok}/{N}")
print(f"testcase-level problems: {len(problems)}")
from collections import Counter
print("problem kinds:", dict(Counter(k for _, _, k in problems)))
for rid, i, k in problems[:40]:
    print(f"  {rid} tc#{i}: {k}")
if len(problems) > 40:
    print(f"  ... and {len(problems)-40} more")
