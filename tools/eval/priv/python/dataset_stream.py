#!/usr/bin/env python3
"""
Stream a Hugging Face dataset and emit one JSON line per sample on stdout.

Used by the Pylixir eval harness (sibling tools/eval/ Mix project). Defaults
to `microsoft/rStar-Coder` but can target any HF dataset whose samples carry
a column containing Python source.

Output (one JSON object per line):

    {"id": "<sample-id>", "source": "<python source code>"}

A trailing `{"_done": true}` line marks clean EOF so the Elixir side can
distinguish completion from a Port crash.

A `{"_skip": "<reason>", "id": ...}` line is emitted for samples where no
Python source could be extracted; the Elixir side counts these but does
not feed them to the transpiler.

Requirements:

    pip install datasets

Usage:

    python3 dataset_stream.py [--dataset NAME] [--split SPLIT] [--limit N]
                              [--offset N] [--field FIELD]
"""

import argparse
import json
import re
import sys


DEFAULT_DATASET = "microsoft/rStar-Coder"
DEFAULT_SPLIT = "train"

# Likely column names that carry Python source in SFT-style datasets.
# Checked in order; first present non-empty value wins.
CANDIDATE_FIELDS = (
    "source",
    "code",
    "solution",
    "response",
    "output",
    "completion",
    "answer",
    "content",
)

# Match a fenced code block; prefer ```python, fall back to plain ```.
PYTHON_FENCE = re.compile(
    r"```(?:python|py)\s*\n(.*?)```",
    re.DOTALL | re.IGNORECASE,
)
ANY_FENCE = re.compile(r"```[a-zA-Z0-9_+\-]*\s*\n(.*?)```", re.DOTALL)


def extract_python(raw, explicit_field):
    """Return a Python source string from a sample value, or None."""
    if raw is None:
        return None
    if not isinstance(raw, str):
        return None

    # If the caller passed an explicit field, trust whatever's in it.
    if explicit_field:
        return raw if raw.strip() else None

    # Prefer a ```python fence if one exists.
    match = PYTHON_FENCE.search(raw)
    if match:
        return match.group(1)

    # If the value is *entirely* code (no prose, no fences), use as-is.
    if "```" not in raw and looks_like_python(raw):
        return raw

    # Fall back to any fenced block — many datasets omit the language tag.
    match = ANY_FENCE.search(raw)
    if match and looks_like_python(match.group(1)):
        return match.group(1)

    return None


def looks_like_python(text):
    """Heuristic: does this string plausibly contain Python source?"""
    if not text or not text.strip():
        return False
    # Cheap signals: any of these tokens at the start of a line.
    keywords = ("def ", "class ", "import ", "from ", "if ", "for ", "while ",
                "print(", "return ", "    ", "#")
    return any(text.lstrip().startswith(k) for k in keywords)


def pick_source(sample, explicit_field):
    if explicit_field:
        return extract_python(sample.get(explicit_field), explicit_field)

    for field in CANDIDATE_FIELDS:
        if field in sample:
            extracted = extract_python(sample[field], None)
            if extracted:
                return extracted
    return None


def sample_id(sample, fallback):
    for key in ("id", "uuid", "example_id", "task_id", "problem_id"):
        if key in sample and sample[key] is not None:
            return str(sample[key])
    return str(fallback)


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False))
    sys.stdout.write("\n")
    sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", default=DEFAULT_DATASET)
    parser.add_argument("--split", default=DEFAULT_SPLIT)
    parser.add_argument("--limit", type=int, default=None,
                        help="Stop after N samples successfully emitted.")
    parser.add_argument("--offset", type=int, default=0,
                        help="Skip the first N samples before emitting.")
    parser.add_argument("--field", default=None,
                        help="Column to read source from; overrides auto-detect.")
    parser.add_argument("--name", default=None,
                        help="Optional dataset config name (HF `name=` kwarg).")
    args = parser.parse_args()

    try:
        from datasets import load_dataset
    except ImportError:
        emit({"_fatal": "missing dependency: pip install datasets"})
        sys.exit(2)

    load_kwargs = {"split": args.split, "streaming": True}
    if args.name:
        load_kwargs["name"] = args.name

    try:
        stream = load_dataset(args.dataset, **load_kwargs)
    except Exception as exc:  # pylint: disable=broad-except
        emit({"_fatal": f"{type(exc).__name__}: {exc}"})
        sys.exit(3)

    emitted = 0
    for idx, sample in enumerate(stream):
        if idx < args.offset:
            continue
        sid = sample_id(sample, idx)
        source = pick_source(sample, args.field)
        if source is None:
            emit({"_skip": "no python source extractable", "id": sid})
            continue
        emit({"id": sid, "source": source})
        emitted += 1
        if args.limit is not None and emitted >= args.limit:
            break

    emit({"_done": True, "emitted": emitted})


if __name__ == "__main__":
    main()
