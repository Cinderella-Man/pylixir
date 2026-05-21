#!/usr/bin/env python3.14
"""
Execute a Python source file under controlled input and capture runtime
type observations of locals via ``sys.settrace``, writing them as JSON to
a file. Used by Pylixir's example-driven type inference (docs/09).

Argv (positional):

    trace.py SOURCE_PATH STDIN_PATH OUT_PATH

  * SOURCE_PATH — Python source file to execute.
  * STDIN_PATH  — file whose contents are wired to ``sys.stdin``.
  * OUT_PATH    — destination for the JSON trace envelope.

The program's own ``stdout`` is left untouched (callers may redirect it
to capture the program's output independently). The tracer never writes
to stdout/stderr itself; all structured output goes to ``OUT_PATH``.

JSON shape (LOCKED):

    {
      "events": [
        {
          "event": "call" | "line" | "return" | "module_end",
          "scope": "module" | "<top-level def name>",
          "lineno": int | null,
          "locals": { "name": <type_repr> }     # for "return" of a fn:
                                                # {"__return__": <type_repr>}
        },
        ...
      ],
      "uncaught": null | {"type": "ExcName", "lineno": int | null},
      "truncated": bool
    }

Scope rules (Q6 A):

  * ``"module"`` — the top-level exec frame (module-level code).
  * ``"<name>"`` — a top-level user def called from module code (i.e.,
    frame.f_back is the module frame).
  * Everything else (nested defs, lambdas, comprehensions, methods,
    library code) is silently skipped.

``type_repr`` values:

  * Scalars by short name string: "int", "float", "bool", "str", "none".
  * Lists/tuples: {"kind": "list"|"tuple", "elems": [<repr>, ...]}
    (sample first 8 elements; nested up to depth 3; deeper levels → "any").
  * Dicts: {"kind": "dict", "items": [[<key>, <value>], ...]}.
  * Sets/frozensets: {"kind": "set"} — opaque.
  * Everything else: "any".

Size cap: if the JSON serialisation would exceed ~1MB, further events
are dropped and ``"truncated": true`` is set. On uncaught exception in
the user program: the tracer catches it, populates ``"uncaught"``,
emits whatever events it has, and exits 0 (partial trace is usable).
"""

from __future__ import annotations

import json
import sys
import traceback
from typing import Any


SCALAR_TYPES: dict[type, str] = {
    int: "int",
    float: "float",
    bool: "bool",
    str: "str",
}

MAX_DEPTH = 3
MAX_ELEMS = 8
MAX_BYTES = 1_000_000


def type_repr(value: Any, depth: int = 0) -> Any:
    if value is None:
        return "none"
    t = type(value)
    if t is bool:
        return "bool"
    if t in SCALAR_TYPES:
        return SCALAR_TYPES[t]
    if depth >= MAX_DEPTH:
        return "any"
    if t is list:
        return {"kind": "list", "elems": [type_repr(v, depth + 1) for v in value[:MAX_ELEMS]]}
    if t is tuple:
        return {"kind": "tuple", "elems": [type_repr(v, depth + 1) for v in value[:MAX_ELEMS]]}
    if t is dict:
        items = []
        for k, v in list(value.items())[:MAX_ELEMS]:
            items.append([type_repr(k, depth + 1), type_repr(v, depth + 1)])
        return {"kind": "dict", "items": items}
    if t is set or t is frozenset:
        return {"kind": "set"}
    return "any"


def build_locals_repr(namespace: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for name, value in namespace.items():
        if name.startswith("__") and name.endswith("__"):
            continue
        result[name] = type_repr(value)
    return result


class TraceState:
    """Single-instance state holder threaded into the trace callback."""

    def __init__(self, source_path: str):
        self.source_path = source_path
        self.module_frame = None
        self.events: list[dict] = []
        self.truncated = False
        self.byte_estimate = 2  # for the surrounding "[]"

    def scope_for(self, frame) -> str | None:
        # Same file check protects against stdlib / generator helpers
        # whose frames also trigger trace events.
        if frame.f_code.co_filename != self.source_path:
            return None
        if self.module_frame is None or frame is self.module_frame:
            return "module"
        if frame.f_back is self.module_frame:
            name = frame.f_code.co_name
            # Q6 (A): comprehensions, lambdas, genexprs out of scope.
            # CPython names them "<listcomp>", "<setcomp>", "<dictcomp>",
            # "<genexpr>", "<lambda>" — all start with "<".
            if name.startswith("<"):
                return None
            return name
        return None

    def record(self, event: dict) -> None:
        if self.truncated:
            return
        encoded = json.dumps(event)
        if self.byte_estimate + len(encoded) + 2 > MAX_BYTES:
            self.truncated = True
            return
        self.events.append(event)
        self.byte_estimate += len(encoded) + 2


def make_tracer(state: TraceState):
    def trace(frame, event, arg):
        if state.module_frame is None and event == "call":
            state.module_frame = frame

        scope = state.scope_for(frame)
        if scope is None:
            return None

        if event == "call":
            co = frame.f_code
            params = list(co.co_varnames[: co.co_argcount])
            state.record(
                {
                    "event": "call",
                    "scope": scope,
                    "lineno": frame.f_lineno,
                    "locals": build_locals_repr(frame.f_locals),
                    "params": params,
                }
            )
            return trace

        if event == "line":
            state.record(
                {
                    "event": "line",
                    "scope": scope,
                    "lineno": frame.f_lineno,
                    "locals": build_locals_repr(frame.f_locals),
                }
            )
            return trace

        if event == "return":
            if scope == "module":
                state.record(
                    {
                        "event": "return",
                        "scope": "module",
                        "lineno": frame.f_lineno,
                        "locals": build_locals_repr(frame.f_locals),
                    }
                )
            else:
                state.record(
                    {
                        "event": "return",
                        "scope": scope,
                        "lineno": frame.f_lineno,
                        "locals": {"__return__": type_repr(arg)},
                    }
                )
            return trace

        return trace

    return trace


def write_envelope(out_path: str, envelope: dict[str, Any]) -> None:
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(envelope))


def main(argv: list[str]) -> int:
    source_path, stdin_path, out_path = argv[1], argv[2], argv[3]

    try:
        with open(source_path, "r", encoding="utf-8") as fh:
            source = fh.read()
    except FileNotFoundError:
        # Source file vanished — typically the parent timed out and cleaned
        # up before this child was reaped. Exit quietly to avoid leaking a
        # traceback to the parent's stderr.
        return 1

    try:
        code = compile(source, source_path, "exec")
    except SyntaxError as exc:
        # Surface a one-line diagnostic on stdout (which the Elixir caller
        # captures as `output` in `{:tracer_exit, code, output}`) without
        # printing the full traceback to stderr.
        print(f"SyntaxError: {exc.msg} (line {exc.lineno})")
        return 1

    state = TraceState(source_path)
    tracer = make_tracer(state)

    uncaught: dict[str, Any] | None = None

    with open(stdin_path, "r", encoding="utf-8") as fh:
        sys.stdin = fh

        namespace: dict[str, Any] = {"__name__": "__main__"}
        sys.settrace(tracer)
        try:
            exec(code, namespace)
        except BaseException as exc:  # pylint: disable=broad-except
            tb = traceback.extract_tb(sys.exc_info()[2])
            user_frame = next(
                (f for f in reversed(tb) if f.filename == source_path),
                None,
            )
            uncaught = {
                "type": type(exc).__name__,
                "lineno": user_frame.lineno if user_frame else None,
            }
        finally:
            sys.settrace(None)

    # Append a synthetic module_end event with the final namespace so
    # consumers always have an end-of-program snapshot regardless of
    # whether sys.settrace fired a "return" on the module frame.
    state.record(
        {
            "event": "module_end",
            "scope": "module",
            "lineno": None,
            "locals": build_locals_repr(namespace),
        }
    )

    envelope = {"events": state.events, "uncaught": uncaught, "truncated": state.truncated}
    write_envelope(out_path, envelope)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
