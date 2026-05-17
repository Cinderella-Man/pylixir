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
import os
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


def emit_from_cache(cache_path, offset, limit):
    """Stream pre-extracted samples from a local JSONL cache.

    Each line is one already-extracted `{"id", "source"}` (skip lines
    are NOT cached). Returns `(emitted, cache_records)` so the caller
    can decide whether to top up from HF.
    """
    emitted = 0
    served = 0
    cache_records = 0
    with open(cache_path, "r", encoding="utf-8") as fh:
        for line in fh:
            stripped = line.strip()
            if not stripped:
                continue
            cache_records += 1
            if served < offset:
                served += 1
                continue
            served += 1
            if limit is not None and emitted >= limit:
                # Keep counting the rest of the file so cache_records
                # reflects the true cache size — needed for the
                # cache-extension decision in main().
                continue
            sys.stdout.write(stripped)
            sys.stdout.write("\n")
            emitted += 1
    sys.stdout.flush()
    return emitted, cache_records


def stream_from_hf(args, cache_fh, hf_skip, served_start, emitted_start):
    """Stream from HF, optionally tee-ing extracted samples to `cache_fh`.

    `hf_skip` skips the first N records from HF (used when extending
    an existing cache — those records are already on disk). `served_start`
    is how many records have already been served toward `args.offset`
    by the cache-read pass; `emitted_start` is how many have already
    been emitted toward `args.limit`. Returns the new emitted total.
    Skip lines (no extractable Python) are NOT cached.
    """
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

    emitted = emitted_start
    served = served_start
    skipped = 0
    for idx, sample in enumerate(stream):
        # Skip records that were already served by the cache pass.
        if skipped < hf_skip:
            # Still account for the record toward `skipped` even if
            # it didn't have Python source — the cache only stores
            # successful extractions, but HF iteration index is total.
            sid = sample_id(sample, idx)
            source = pick_source(sample, args.field)
            if source is not None:
                skipped += 1
            continue

        sid = sample_id(sample, idx)
        source = pick_source(sample, args.field)

        if source is None:
            if served >= args.offset:
                emit({"_skip": "no python source extractable", "id": sid})
            continue

        record = {"id": sid, "source": source}
        if cache_fh is not None:
            cache_fh.write(json.dumps(record, ensure_ascii=False))
            cache_fh.write("\n")
            cache_fh.flush()

        if served < args.offset:
            served += 1
            continue
        served += 1
        emit(record)
        emitted += 1
        if args.limit is not None and emitted >= args.limit:
            break

    return emitted


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
    parser.add_argument("--cache", default=None,
                        help="Path to a local JSONL cache. When the file "
                             "exists, samples are served from it (no HF "
                             "download). When absent, the script streams "
                             "from HF and writes the cache as it goes. "
                             "Skip lines are not cached.")
    args = parser.parse_args()

    cache_path = args.cache

    # No cache configured — pure HF stream.
    if not cache_path:
        emitted = stream_from_hf(args, None, 0, 0, 0)
        emit({"_done": True, "emitted": emitted, "source": "hf"})
        return

    cache_exists = os.path.exists(cache_path)
    served_from_cache = 0
    cache_records = 0
    emitted_from_cache = 0

    if cache_exists:
        emitted_from_cache, cache_records = emit_from_cache(
            cache_path, args.offset, args.limit
        )
        served_from_cache = min(cache_records, args.offset + emitted_from_cache)

    # Decide whether to extend the cache from HF. We need more iff the
    # caller asked for `limit` records (or unlimited) and the cache
    # couldn't fully satisfy the request.
    needs_more = (
        args.limit is None
        or emitted_from_cache < args.limit
    ) and (
        args.limit is None
        or cache_records < args.offset + args.limit
    )

    if not cache_exists or needs_more:
        os.makedirs(os.path.dirname(cache_path) or ".", exist_ok=True)
        # Append mode when extending; write mode when first creating.
        mode = "a" if cache_exists else "w"
        cache_fh = open(cache_path, mode, encoding="utf-8")

        try:
            emitted = stream_from_hf(
                args, cache_fh,
                hf_skip=cache_records,
                served_start=served_from_cache,
                emitted_start=emitted_from_cache,
            )
        finally:
            cache_fh.close()

        source = "cache+hf" if cache_exists else "hf"
    else:
        emitted = emitted_from_cache
        source = "cache"

    emit({"_done": True, "emitted": emitted, "source": source})


if __name__ == "__main__":
    main()
