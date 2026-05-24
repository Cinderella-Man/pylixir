#!/usr/bin/env python3
"""Canonical-source hasher for dataset dedup (Dataset.SourceNorm).

Reads one JSON-encoded Python source string per stdin line; writes one
sha256 hex per line (or "ERR" if the source doesn't parse), in order.

Only *parses* the source (ast.parse) — never executes it — so it is safe
to run on untrusted solutions without the code sandbox.

argv[1] = mode:
  reformat  ast.unparse(ast.parse(s))  -> ignores comments/whitespace/quotes
  struct    + rename all identifiers   -> also ignores variable names,
            keeping operators & constants (so behaviour-equivalent
            variations collide; different ops/constants do not)
"""
import sys, json, ast, hashlib

MODE = sys.argv[1] if len(sys.argv) > 1 else "struct"
sys.setrecursionlimit(20000)


class Rename(ast.NodeTransformer):
    def visit_Name(self, node):
        return ast.copy_location(ast.Name(id="_v", ctx=node.ctx), node)

    def visit_arg(self, node):
        node.arg = "_a"
        node.annotation = None
        return node

    def visit_FunctionDef(self, node):
        node.name = "_f"
        self.generic_visit(node)
        return node

    def visit_AsyncFunctionDef(self, node):
        node.name = "_f"
        self.generic_visit(node)
        return node

    def visit_ClassDef(self, node):
        node.name = "_c"
        self.generic_visit(node)
        return node

    def visit_Attribute(self, node):
        self.generic_visit(node)
        node.attr = "_at"
        return node


def normalize(src):
    tree = ast.parse(src)
    if MODE == "struct":
        tree = ast.fix_missing_locations(Rename().visit(tree))
    return ast.unparse(tree)


def main():
    out = sys.stdout
    for line in sys.stdin:
        line = line.rstrip("\n")
        try:
            src = json.loads(line)
            digest = hashlib.sha256(normalize(src).encode("utf-8")).hexdigest()
            out.write(digest + "\n")
        except Exception:
            out.write("ERR\n")


if __name__ == "__main__":
    main()
