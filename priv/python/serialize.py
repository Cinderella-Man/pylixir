#!/usr/bin/env python3.14
"""
Serialize a Python AST (parsed by ast.parse) to JSON.

This is the bridge consumed by Pylixir.transpile/1. Reads source from a file
path (argv[1]) or stdin if argv[1] is "-". Always exits 0; errors are surfaced
inside a structured JSON envelope so the Elixir side can read stdout
deterministically.

Output shapes:

  * Success: the AST as JSON, each node tagged with "_type" plus its fields
    plus lineno/col_offset (when present). Unsupported Constant values
    (complex, bytes, Ellipsis) emit as tagged shapes that the converter
    detects and raises on.
  * Syntax error: {"error": "syntax", "message": ..., "lineno": ...,
    "col_offset": ..., "text": ...}.
  * Internal error: {"error": "internal", "message": ...}.

Coordinated with RFC §4 / T33 in docs/plan.md.
"""

import ast
import json
import sys


class PylixirEncoder(json.JSONEncoder):
    """Encode Python literals that don't have native JSON shapes."""

    def default(self, obj):
        if isinstance(obj, complex):
            return {"_unsupported_literal": "complex", "repr": str(obj)}
        if isinstance(obj, bytes):
            # Pylixir doesn't model bytes vs str separately — most uses of
            # `b"..."` in competitive code are ASCII text passed to a
            # function that accepts either. Decode as UTF-8; fall back to
            # the repr-tagged shape if the bytes aren't valid UTF-8.
            try:
                return obj.decode("utf-8")
            except UnicodeDecodeError:
                return {"_unsupported_literal": "bytes", "repr": repr(obj)}
        if obj is ...:
            return {"_unsupported_literal": "ellipsis"}
        return super().default(obj)


def node_to_dict(node):
    if isinstance(node, ast.AST):
        result = {"_type": type(node).__name__}
        for field, value in ast.iter_fields(node):
            result[field] = node_to_dict(value)
        # Preserve source location for error messages and tooling.
        if hasattr(node, "lineno") and node.lineno is not None:
            result["lineno"] = node.lineno
        if hasattr(node, "col_offset") and node.col_offset is not None:
            result["col_offset"] = node.col_offset
        return result
    if isinstance(node, list):
        return [node_to_dict(item) for item in node]
    return node


def read_source(argv):
    if len(argv) > 1 and argv[1] != "-":
        with open(argv[1], "r", encoding="utf-8") as handle:
            return handle.read()
    return sys.stdin.read()


def main():
    try:
        source = read_source(sys.argv)
        tree = ast.parse(source)
        result = node_to_dict(tree)
        sys.stdout.write(json.dumps(result, cls=PylixirEncoder))
    except SyntaxError as exc:
        sys.stdout.write(json.dumps({
            "error": "syntax",
            "message": str(exc),
            "lineno": exc.lineno,
            "col_offset": exc.offset,
            "text": exc.text,
        }))
    except Exception as exc:  # pylint: disable=broad-except
        sys.stdout.write(json.dumps({
            "error": "internal",
            "message": f"{type(exc).__name__}: {exc}",
        }))


if __name__ == "__main__":
    main()
