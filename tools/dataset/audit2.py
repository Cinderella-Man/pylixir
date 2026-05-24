import pyarrow.parquet as pq
import json, hashlib, ast, re, difflib
from collections import defaultdict

t = pq.read_table("out/v1/data.parquet")
ids = t.column("id").to_pylist()
src = t.column("source").to_pylist()
sol = t.column("solution_sha256").to_pylist()
tcs = [json.loads(x) for x in t.column("testcases").to_pylist()]
meta = [json.loads(x) for x in t.column("meta").to_pylist()]
n = len(ids)
print(f"rows: {n}")

def h(b): return hashlib.sha1(b.encode("utf-8","surrogatepass")).digest()
io = [{h(c["stdin"]): h(c["expected"]) for c in r} for r in tcs]

def struct(s):
    try: tree = ast.parse(s)
    except: return None
    class R(ast.NodeTransformer):
        def visit_Name(self,x): return ast.copy_location(ast.Name(id="_v",ctx=x.ctx),x)
        def visit_arg(self,x): x.arg="_a"; x.annotation=None; return x
        def visit_FunctionDef(self,x): x.name="_f"; self.generic_visit(x); return x
        def visit_Attribute(self,x): self.generic_visit(x); x.attr="_at"; return x
    try: return ast.unparse(ast.fix_missing_locations(R().visit(tree)))
    except: return None
st = [struct(s) for s in src]

# ---- invariants (should be 0) ----
def red(key):
    g=defaultdict(list)
    for i,v in enumerate(key):
        if v is not None: g[v].append(i)
    return sum(len(v)-1 for v in g.values() if len(v)>1)
inv=defaultdict(list)
for i,m in enumerate(io):
    for s in m: inv[s].append(i)
sh=defaultdict(int); dis=set()
for s,rows in inv.items():
    for a in range(len(rows)):
        for b in range(a+1,len(rows)):
            i,j=rows[a],rows[b]; k=(i,j); sh[k]+=1
            if io[i][s]!=io[j][s]: dis.add(k)
print("\n[pipeline invariants — expect 0]")
print("  identical source       :", red(sol))
print("  identical struct source :", red([h(x) if x else None for x in st]))
print("  >=2 shared, agree pairs  :", len([1 for p,c in sh.items() if c>=2 and p not in dis]))
print("  single-shared (L3) pairs :", len([1 for p,c in sh.items() if c==1 and p not in dis]))

# ---- seed-adjacency: distinct rows holding consecutive seed numbers ----
num2row = {}
for i,m in enumerate(meta):
    for q in m.get("member_qids", [ids[i].split("--")[0]]):
        mm = re.match(r"seed_(\d+)$", q)
        if mm: num2row[int(mm.group(1))] = i

cand = set()
for num, i in num2row.items():
    for d in (1,-1):
        j = num2row.get(num+d)
        if j is not None and j != i:
            cand.add((min(i,j), max(i,j)))
print(f"\n[seed-adjacency] {len(cand)} candidate pairs (adjacent seed IDs in different rows)")

# classify each candidate
rows=[]
for i,j in cand:
    shared = len(io[i].keys() & io[j].keys())
    ratio = difflib.SequenceMatcher(None, src[i], src[j]).ratio()
    sratio = difflib.SequenceMatcher(None, st[i] or "", st[j] or "").ratio()
    rows.append((sratio, ratio, shared, i, j))
rows.sort(reverse=True)

hi = [r for r in rows if r[0] >= 0.9]
print(f"  of those, {len(hi)} have >=0.90 structural-source similarity (likely same problem)")
print(f"\n  top suspects (struct_sim, raw_sim, shared_tcs, ids):")
for sr,ra,shd,i,j in rows[:12]:
    print(f"    {sr:.2f} {ra:.2f} sh={shd:<2} {ids[i]}  vs  {ids[j]}")
