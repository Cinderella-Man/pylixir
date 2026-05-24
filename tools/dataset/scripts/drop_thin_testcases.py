#!/usr/bin/env python3
"""Drop dataset rows with fewer than MIN_TESTS testcases.

Streams a curated `data.jsonl` line by line and writes a filtered copy
(never overwrites the input). Rows are kept iff `num_testcases >= MIN_TESTS`.

    python3 scripts/drop_thin_testcases.py [IN.jsonl] [OUT.jsonl] [MIN_TESTS]

Defaults: out/v3/data.jsonl -> out/v3/data.min3.jsonl, MIN_TESTS=3.
"""
import json
import sys

IN = sys.argv[1] if len(sys.argv) > 1 else "out/v3/data.jsonl"
OUT = sys.argv[2] if len(sys.argv) > 2 else "out/v3/data.min3.jsonl"
MIN_TESTS = int(sys.argv[3]) if len(sys.argv) > 3 else 3

kept = dropped = 0
with open(IN) as fin, open(OUT, "w") as fout:
    for line in fin:
        if line.strip() and json.loads(line)["num_testcases"] >= MIN_TESTS:
            fout.write(line)
            kept += 1
        else:
            dropped += 1

print(f"kept {kept}, dropped {dropped} (num_testcases < {MIN_TESTS}) -> {OUT}")
