#!/usr/bin/env python3
"""Create out/v4 from out/v3 by dropping every row with <= 5 testcases.

v4 is a pure post-export filter of v3 (no re-verification): keep rows with
num_testcases >= MIN. Always writes data.parquet (canonical, same schema),
provenance.json, dataset_card.md. The (large) data.jsonl is opt-in via --jsonl.

    python3 scripts/make_v4.py [--jsonl]
"""
import sys, json, shutil, os
from datetime import datetime, timezone
import pyarrow as pa
import pyarrow.parquet as pq
import pyarrow.compute as pc

SRC, DST, MIN = "out/v3", "out/v4", 6
WRITE_JSONL = "--jsonl" in sys.argv[1:]
os.makedirs(DST, exist_ok=True)

# --- parquet: filter, preserve schema + compression codec ---------------
pf = pq.ParquetFile(f"{SRC}/data.parquet")
codec = pf.metadata.row_group(0).column(0).compression.lower()  # e.g. 'zstd'
table = pf.read()
kept = table.filter(pc.greater(table.column("num_testcases"), MIN - 1))
pq.write_table(kept, f"{DST}/data.parquet", compression=codec)
n_keep = kept.num_rows
n_drop = table.num_rows - n_keep
print(f"parquet: kept {n_keep}, dropped {n_drop} (codec={codec})")

# --- jsonl: byte-identical surviving lines (opt-in via --jsonl) ---------
if WRITE_JSONL:
    jk = jd = 0
    with open(f"{SRC}/data.jsonl") as fin, open(f"{DST}/data.jsonl", "w") as fout:
        for line in fin:
            if line.strip() and json.loads(line)["num_testcases"] >= MIN:
                fout.write(line); jk += 1
            else:
                jd += 1
    print(f"jsonl:   kept {jk}, dropped {jd}")
    assert jk == n_keep, (jk, n_keep)
else:
    print("jsonl:   skipped (pass --jsonl to write data.jsonl)")

# --- provenance ----------------------------------------------------------
prov = json.load(open(f"{SRC}/provenance.json"))
prov["version"] = "v4"
prov["num_rows"] = n_keep
prov["generated_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
prov["derived_from"] = "v3"
prov["post_export_filter"] = {
    "rule": "drop rows with <= 5 testcases",
    "min_testcases": MIN,
    "dropped_rows": n_drop,
}
json.dump(prov, open(f"{DST}/provenance.json", "w"), indent=2, sort_keys=True)
print(f"provenance: version=v4 num_rows={n_keep}")

# --- dataset card (copy v3 + add the filter note) -----------------------
card = open(f"{SRC}/dataset_card.md").read()
note = ("* **rows with fewer than 6 testcases dropped** (v4, derived from v3): "
        "every shipped task has >= 6 verified testcases;\n")
marker = "* **problem statements removed**"
card = card.replace(marker, note + marker, 1)
open(f"{DST}/dataset_card.md", "w").write(card)
print("dataset_card.md written")
