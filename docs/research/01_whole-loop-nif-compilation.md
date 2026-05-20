# Whole-loop NIF compilation for Pylixir: a research note

*A future-work design sketch for getting past the last few `:elixir_timeout`
samples in the eval corpus by compiling tight Python loops to native code.*

## Quick glossary

The doc uses a few jargon words. One line each:

- **NIF** ("Native Implemented Function") — a function written in C
  or Rust that the BEAM (Erlang/Elixir VM) can call as if it were
  Elixir. Lets you escape into hand-written native code.
- **AOT** ("ahead-of-time") — compile during the build, before the
  program runs. What `mix compile` does. Predictable, slow at build,
  fast at runtime.
- **JIT** ("just-in-time") — compile while the program is running, on
  the fly. What V8 does for JavaScript. Adapts to actual runtime
  behavior but adds runtime complexity.
- **Rust** — a compiled systems language with very clean tooling for
  writing BEAM NIFs (via the [Rustler](https://github.com/rusterlium/rustler)
  library). We could use C instead, but Rust is the easier on-ramp.
- **Marshalling** — converting data between two languages' in-memory
  formats when you cross a boundary (e.g. BEAM array → Rust `Vec`).
  Costs CPU time and memory.

## Why "drop in a Rust NIF" doesn't work the obvious way

The naive idea: rewrite `py_getitem/2` in Rust, ship it as a NIF, get
"C speed" for every array read. This makes things **slower**.

Reason: every time you cross from BEAM into native code, the VM has
to package up the arguments, switch CPU contexts, and (after) repackage
the return value. That overhead is ~300 ns per crossing. A pure-Elixir
`:array.get/2` is ~150 ns. So:

| Read style                       | Per-op cost               |
|----------------------------------|---------------------------|
| Pure Elixir `:array.get/2`       | ~150 ns                   |
| Per-op Rust NIF wrapping a `Vec` | ~300 ns (mostly overhead) |
| Native `Vec[i]` inside Rust      | ~1 ns                     |

The Qqwy/RRBVector experiment ([elixir-arrays_rrb_vector](https://github.com/Qqwy/elixir-arrays_rrb_vector))
already proved this empirically: Rust's best-in-class persistent
vector lost to BEAM's `:array` for per-op use, purely because of NIF
crossing overhead.

The win is only possible if **one NIF call does a lot of work**. That
points us at whole-loop compilation.

## The core idea, by example

Take this Python (a hot loop from eval sample 003):

```python
n = int(input())                              # length of L
L = list(map(int, input().split()))           # the input array we read from
xs_sum = [0] * n                              # the output array we fill in
running = 0
for i in range(n):
    running += L[i]
    xs_sum[i] = running
```

(`L` is just an input array — typically read from stdin in the
competitive-programming samples — that the loop reads from. `xs_sum`
is the output array the loop fills in.)

### What Pylixir emits today

```elixir
xs_sum = py_pvec_new(n, 0)
running = 0

{running, xs_sum} =
  Enum.reduce(0..(n - 1), {running, xs_sum}, fn i, {running, xs_sum} ->
    running = py_add(running, py_getitem(L, i))
    xs_sum  = py_setitem(xs_sum, i, running)
    {running, xs_sum}
  end)
```

Each iteration calls three helpers (`py_add`, `py_getitem`,
`py_setitem`); each helper walks a small `:array` tree. For N=100K
that's ~300K helper calls. Runtime: hundreds of milliseconds.

### What whole-loop compilation would emit (per-program-source flavor)

```elixir
{running, xs_sum} = Pylixir.Native.cumsum_kernel_47(L, n)
```

ONE call. Inside the NIF, generated Rust runs the loop directly:

```rust
#[rustler::nif]
fn cumsum_kernel_47(l: Vec<i64>, n: usize) -> (i64, Vec<i64>) {
    let mut xs_sum: Vec<i64> = vec![0; n];
    let mut running: i64 = 0;
    for i in 0..n {
        running += l[i];
        xs_sum[i] = running;
    }
    (running, xs_sum)
}
```

The 300 ns overhead is paid **once** instead of 300,000 times. The
actual loop runs at native speed (~1 ns per iteration). For N=100K
the kernel completes in ~100 µs. ~1000× faster than the BEAM version.

### What the generic-IR flavor would emit

The hardcoded-Rust version above works, but it requires generating
a new `.rs` file and rebuilding the .so for every transpiled program.
The cleaner alternative is to emit a **portable IR** (e.g. WebAssembly
bytes) at transpile time and let one shared NIF execute it. Same loop,
different shape:

```elixir
# Pylixir emits the IR as data (not source code). A single shared
# `Pylixir.Native` NIF knows how to load + run any WASM kernel.
@cumsum_kernel_47 <<0, 97, 115, 109, 1, 0, 0, 0, ...>>  # ~200 bytes

{running, xs_sum} = Pylixir.Native.run(@cumsum_kernel_47, [L, n])
```

No `cargo build` step, no per-program .so file. The NIF is a small
wrapper around an embedded WASM runtime (wasmtime); the bytecode is
just data that the compiler hands off. We unpack this in
["What to emit"](#what-to-emit-per-program-source-vs-portable-ir)
below.

## What counts as a "compilable kernel"

A loop is compilable only if every operation has a clean native
mapping. The gate has to be conservative — when in doubt, fall back
to today's emission.

### ✅ Compiles (these are exactly what we want)

```python
# Cumulative sum
for i in range(n):
    out[i] = out[i-1] + L[i]

# Element-wise transform
for i in range(n):
    result[i] = L[i] * 2 - 1

# Conditional pointer-walk (eval sample 005)
for j in range(n-1, -1, -1):
    current = min(current, R[j])
    min_R[j] = current
```

All three:
- Iteration variable is an integer over a known range.
- All variables are int (or float) or arrays of int/float.
- Operations are arithmetic, comparison, `min`/`max`, subscript.
- No function calls, no I/O, no resizing.

### ❌ Doesn't compile (and shouldn't)

```python
# I/O — has to stay in BEAM
for i in range(n):
    print(L[i])

# Resizes a container — pvec/native arrays are fixed-size
for i in range(n):
    xs.append(L[i] * 2)

# Calls a user-defined function — we'd need to inline it
for i in range(n):
    xs[i] = transform(L[i])

# Indexes with a slice — fancy indexing isn't scalar
for i in range(n):
    out[i:i+3] = L[i:i+3]

# String operations — not yet in scope for native lowering
for i in range(n):
    if "foo" in names[i]:
        flags[i] = 1
```

The gate's job is to bail cleanly on these — emit today's Elixir
version, no harm done.

## Two questions: WHEN to compile + WHAT to compile to

There are actually two orthogonal axes here. Mixing them up is what
makes "should we use Rust or WASM or a JIT" feel like one question.

| Axis | Choice A | Choice B |
|---|---|---|
| **WHEN** | **AOT** — at Pylixir build time | **JIT** — while program runs |
| **WHAT** | **Source** — per-program Rust/C, compiled by `rustc`/`cc` | **IR** — portable bytecode (WASM/Cranelift/LLVM), compiled by a fast embedded engine |

The two choices combine in four ways. Three of them are real:

|  | Source | IR |
|---|---|---|
| **AOT** | Generate Rust per program; `cargo build` → .so. The "obvious" path. | Generate WASM bytes per program; ship as data. No build step. |
| **JIT** | ❌ Don't — `rustc` is 1000× too slow to embed at runtime. | Build IR at runtime from the Python AST; embedded compiler turns it into machine code in ms. |

The "JIT + Source" cell is the option that *sounds* attractive ("just
hand Rust source to a NIF that compiles it") but doesn't work because
`rustc` is a multi-second per-call cost and isn't designed to be
embedded. The other three are all viable; the choice depends on
priorities.

### AOT vs JIT — when to compile

- **AOT** is predictable and debuggable. Compilation happens at
  `mix compile` time; runtime is just "call the compiled thing".
- **JIT** is more flexible (handles programs you didn't see at build
  time, can specialize on runtime types) but adds a runtime
  compiler dependency.

For Pylixir the choice mostly doesn't matter, because we always
transpile a known Python program — there's no "new code at runtime"
scenario the way there is in a Phoenix request handler. Pick whichever
combines better with the **What** choice.

### Source vs IR — what to compile to

This is the more interesting axis. Source-text generation feels
natural ("emit Rust, run `cargo build`") but ships a heavy toolchain
dependency and produces per-program .so files. Portable IR is a
better fit for what Pylixir actually needs:

- **Source (Rust/C):** humans can read the generated code, debugging
  is straightforward, you get full optimization. But: the user needs
  `cargo` / a C compiler installed (or you ship per-OS precompiled
  binaries via [rustler_precompiled](https://hexdocs.pm/rustler_precompiled)),
  build times go from seconds to minutes, and every transpiled
  program produces its own .so.
- **IR (WASM / Cranelift / LLVM):** Pylixir emits a structured data
  blob. A *single* shared NIF (linked once, e.g. via
  [wasmex](https://github.com/tessi/wasmex)) loads and runs any
  kernel. No external toolchain, no per-program .so, sandboxed,
  cross-platform.

**Recommendation: AOT + IR (WASM via wasmex) is the sweet spot.**
You get build-time predictability AND the simplicity of "kernels are
just data". The "AOT + Source" path is easier to prototype and
debug, so it's the natural first step.

## What to emit: per-program source vs portable IR

Expanding the **WHAT** axis with concrete options:

### Option 1: per-program Rust source ("AOT + Source")

```
   .py source  →  Pylixir (Elixir)  →  Generates kernels.rs
                                    →  Invokes cargo build --release
                                    →  Produces kernels.so
                                    →  Loaded by BEAM via Rustler
```

**Trade-offs:** simplest to understand and debug; user-readable
generated code. But ships ~1GB of Rust toolchain dependency, build
times of seconds-to-minutes per program, per-program .so artifacts.

### Option 2: WebAssembly via [wasmex](https://github.com/tessi/wasmex) ⭐ recommended

```
   .py source  →  Pylixir (Elixir)  →  Generates WASM bytes (a
                                       portable binary IR)
                                    →  Stored as a module attribute
                                    ↓
   Wasmex.start_link(%{bytes: kernel_wasm})   ← runs in a sandbox,
                                                compile = ~1-5 ms
   Wasmex.call_function(:kernel_47, [L, n])
```

[wasmex](https://hexdocs.pm/wasmex) already exists on hex.pm. It's a
Rust NIF wrapping [wasmtime](https://wasmtime.dev), the industry-
standard WASM runtime. Pylixir would need a Python-AST → WASM-bytecode
lowering pass, but WASM is a small, well-specified IR designed for
exactly this use case.

**Trade-offs:** no external build toolchain, kernels are
cross-platform data, compile-on-load is fast (single-digit ms).
Sandbox prevents miscompiled kernels from corrupting BEAM. Loses
~10-20% peak performance vs hand-rolled Rust (WASM has some
overhead) but typically still 100-1000× faster than the all-Elixir
version.

### Option 3: [Cranelift](https://cranelift.dev) directly

The code generator that wasmtime uses internally. Compiles functions
in single-digit ms. You build Cranelift IR programmatically (rather
than emit bytecode):

```rust
let mut builder = FunctionBuilder::new(...);
let l = builder.block_params(entry)[0];
let n = builder.block_params(entry)[1];
// ... emit IR operations for the loop ...
let code = builder.finalize();   // returns a callable function ptr
```

**Trade-offs:** Slightly lower-level than WASM (you build IR data
structures, not bytecode). No sandboxing — a bug in your IR
generator can corrupt BEAM. Used by Firefox/SpiderMonkey, wasmtime,
and others; mature.

### Option 4: [LLVM](https://llvm.org) via [Inkwell](https://github.com/TheDan64/inkwell) or [llvm-sys](https://crates.io/crates/llvm-sys)

What [Julia](https://julialang.org), [Numba](https://numba.pydata.org),
and [EXLA](https://github.com/elixir-nx/nx/tree/main/exla) use. Slower
compile than Cranelift (~50-100 ms per function) but produces highly
optimized code with the world's best optimizer.

**Trade-offs:** maximum runtime performance; significant linking
complexity (LLVM is a huge dependency); compile time matters less
for long-running kernels.

### Comparison

| Option | Compile time per kernel | Per-program build artifact | Runtime perf | Complexity to set up |
|---|---|---|---|---|
| Per-program Rust source | seconds | yes, one .so | ★★★★★ | low (familiar) |
| WASM via wasmex | ~1-5 ms | no — kernels are data | ★★★★ | low (lib exists) |
| Cranelift | ~1-5 ms | no | ★★★★ | medium |
| LLVM | ~50-100 ms | no | ★★★★★ | high |

For Pylixir's use case (translate-once, run-many-times, output stays
near-real-time), **WASM via wasmex hits the right Pareto point**.
Cranelift is a close second if WASM's overhead turns out to matter.
LLVM only if you find a kernel that runs for seconds.

## The marshalling problem (and how to dodge it)

The catch in the example above: `cumsum_kernel_47(L, n)` takes `L` as
a `Vec<i64>`. But on the BEAM side, `L` is a pvec (an `:array` tree
of small tuples). To hand it to Rust, every element has to be copied
into a flat Rust `Vec`. For N=100K elements:

- Copy out (BEAM → Rust `Vec`): ~50–100 µs
- Run the loop in Rust: ~100 µs
- Copy back (Rust `Vec` → BEAM): ~50–100 µs

**Marshalling now dominates the kernel runtime.** For small N you
might lose to the all-Elixir version.

### Dodge: keep the data in Rust between calls

NIFs support **resources**: opaque chunks of memory that Rust owns
and the BEAM holds a reference to (and frees when the reference
is GC'd). The Pylixir compiler can recognize when a pvec is going to
be consumed by several compiled kernels in sequence, "lift" it into
Rust once at the start of the region, and only convert back to a
BEAM pvec on exit. Code-shape sketch:

```elixir
# Compiled region — data stays Rust-side throughout.
l_handle      = Pylixir.Native.lift_to_native(L)
xs_sum_handle = Pylixir.Native.cumsum_kernel_47(l_handle, n)
min_handle    = Pylixir.Native.suffix_min_kernel_48(xs_sum_handle, n)
result        = Pylixir.Native.materialize(min_handle)  # back to pvec
```

Pay the boundary crossing twice instead of six times. This is the
same pattern Nx uses for its tensor pipelines — operations chain
inside the backend (XLA/EXLA) and only materialize at the end.

## The five hard parts (in order of pain)

1. **Type proofs.** The kernel emitter has to *prove* every variable
   in the loop has a concrete machine type (i64, f64, vec of those).
   "Probably an int" isn't enough — if it's wrong, the Rust code
   crashes. Pylixir's existing monomorphic-type pass is the starting
   point but needs a stricter mode that bails on any uncertainty.
   Numba calls this `nopython=True`; it's the right model.

2. **Marshalling and resource lifetimes.** The "lift to native, do
   work, materialize" pattern above means Pylixir has to reason about
   *which* values cross the boundary, *when*, and *how long* the
   native resource lives. Get it wrong and you either pay marshalling
   too often (slow) or leak memory (bad).

3. **Build integration.** Today Pylixir is pure Elixir — `mix deps.get`
   and you're done. AOT NIF emission means: invoking `cargo` from
   `mix`, shipping per-OS precompiled binaries for users without
   Rust, handling failed compilations gracefully. Real work.

4. **Conservative gate.** Compiling a loop that turns out to need a
   runtime helper we missed (because of a corner case in the type
   analysis) is either a crash or a silent miscompile. The gate has
   to refuse anything it isn't 100% sure about, and there has to be
   a test harness that diffs `with_native` vs `without_native`
   output on every fixture.

5. **Debuggability.** When a kernel produces wrong output, the user is
   debugging generated Rust they didn't write. A `--debug-kernels`
   mode that keeps the Elixir version alongside, runs both, and
   asserts identical output is probably non-optional.

## Prior art worth studying

| Project | One-line summary | Why it matters |
|---|---|---|
| **[Cython](https://cython.org)** | Python annotated with C types → C → compiled per module | 20 years of experience picking the "compilable subset of Python" gate. |
| **[Numba](https://numba.pydata.org)** | Decorator `@jit` compiles a Python function via LLVM | The `nopython=True` strictness model is exactly what our gate needs. |
| **[mypyc](https://mypyc.readthedocs.io)** | mypy-typed Python → C | Whole-program AOT; near-identical architecture to what we'd build. |
| **[Codon](https://github.com/exaloop/codon)** | Static Python-syntax compiler to LLVM | Proves a Python *subset* compiles cleanly and runs near-C speed. |
| **[Nx.Defn](https://hexdocs.pm/nx/Nx.Defn.html) / [EXLA](https://github.com/elixir-nx/nx/tree/main/exla)** | Restricted-Elixir captured at macro time, compiled to XLA | **The most relevant in-ecosystem precedent.** Read `Nx.Defn.Expr` and `EXLA.Defn` to see how they capture an AST, walk it, and emit native. |
| **[wasmex](https://github.com/tessi/wasmex)** | Elixir wrapper around wasmtime — runs WASM modules in a NIF | **The integration we'd build on for the IR path.** Ships today on hex.pm. |
| **[wasmtime](https://wasmtime.dev)** | Production-grade WASM runtime (Rust); embeddable | The underlying engine wasmex wraps. Hot-path performance is well-characterized. |
| **[Cranelift](https://cranelift.dev)** | Fast code generator used inside wasmtime; usable standalone | Lower-level than WASM but compiles in single-digit ms. The alternative IR target. |
| **[Inkwell](https://github.com/TheDan64/inkwell) / [llvm-sys](https://crates.io/crates/llvm-sys)** | Rust bindings for LLVM | Heaviest-weight IR option; what Julia / Numba / EXLA use under the hood. |
| **[Rustler](https://github.com/rusterlium/rustler)** | Rust ↔ BEAM glue, supports resources | The integration plumbing; well-documented, low friction. |
| **[BeamAsm](https://blog.erlang.org/a-first-look-at-the-jit/)** | BEAM bytecode → x86_64 JIT (Erlang/OTP 24+) | Proves you can run a JIT inside BEAM. Doesn't help directly. |
| **[Julia](https://julialang.org)** | Whole language designed around type-stable JIT | Read its "type stability" docs — they describe the exact discipline our gate needs. |

The single most useful thing to read first is the source of
`Nx.Defn`. It solves a structurally identical problem (capture
restricted-Elixir, compile to a foreign backend, manage the
data-lifecycle across the boundary) and Sean Moriarity has written
extensively about the design choices.

## A realistic first prototype (1–2 weeks of focused work)

Scope ruthlessly. Don't try to handle every Python loop — just the
narrowest profitable case.

**Compile only loops that satisfy ALL of:**

- [ ] Loop is `for i in range(<expr>)` at function top-level.
- [ ] Loop body contains only: int arithmetic, comparison,
      `if`/`else`, `min`/`max`, subscript reads, subscript writes.
- [ ] All loop-touched variables are int scalars or pvecs of int
      (Pylixir already knows this from `pvec_names` and `types`).
- [ ] No nested loops, no function calls, no `break`/`continue`/`return`.

The gate is the same regardless of backend. What differs is the
emission target.

### Prototype path A: Rust source (easier to debug, heavier to set up)

1. Add `Pylixir.NativeKernelAnalysis` (sibling of `PvecAnalysis`).
2. In `Pylixir.Nodes.Loop`, when a `For` matches the gate, emit
   `{:., [], [Pylixir.Native, :kernel_<n>]}` instead of an
   `Enum.reduce`.
3. Accumulate generated Rust source into `priv/native/kernels.rs`
   at transpile time.
4. Add a `mix pylixir.compile_kernels` task that runs `cargo build`.
5. Ship one `Pylixir.Native` module with rustler bindings.
6. Diff-test: run every fixture with kernels on AND off, assert
   identical output.
7. Benchmark the eval corpus with `--limit 100`. Win = ≥ 1 more
   sample out of timeout, no regressions.

**Pros for prototyping:** generated code is human-readable; you can
literally open `kernels.rs` and step through it; if something breaks,
the diff against handwritten Rust is obvious.

**Cons:** requires Rust toolchain locally; build step adds tens of
seconds; per-program .so artifact.

### Prototype path B: WASM via wasmex (lighter integration, opaque debugging)

1. Add `Pylixir.NativeKernelAnalysis` (same as above).
2. Add a Pylixir → WASM lowering pass (`Pylixir.WasmEmit`). For the
   narrow gate this is ~300 LOC: each Python AST node maps to a few
   WASM instructions.
3. At transpile time, emit `@kernel_47 <<...wasm bytes...>>` as a
   module attribute, plus a wrapper that calls
   `Wasmex.call_function(instance, :kernel_47, [...])`.
4. Add `{:wasmex, "~> 0.10"}` to deps.
5. Diff-test + benchmark as above.

**Pros for prototyping:** no Rust toolchain, no per-program build,
kernels are just data. wasmex handles all NIF glue. Cross-platform
out of the box.

**Cons:** if a kernel is wrong, you're debugging WASM bytecode — much
harder than reading Rust source. Initial WASM-emission pass is more
work than concatenating Rust strings.

### Which to try first?

**If you want to learn whether the speedup is real:** start with Path
A (Rust source). The emission is half a page of string concatenation;
you'll know in days whether the win exists.

**If you want a path to production:** start with Path B (WASM). The
WASM emitter is more work up front but everything downstream — the
build pipeline, the precompiled-binary problem, the per-program .so
management — disappears.

A reasonable middle: build Path A first to validate the perf
hypothesis (1 week), then port the emitter to Path B for production
(2-3 weeks). The gate analysis (`Pylixir.NativeKernelAnalysis`) is
shared between them.

## Scope estimates (rough)

| Goal | Effort |
|---|---|
| Prototype path A (Rust source), narrow gate | 1–2 weeks |
| Prototype path B (WASM via wasmex), narrow gate | 2–3 weeks |
| Production-quality WASM path (expanded coverage, resource handles for marshalling, debug mode, error mapping) | 3–6 months |
| Production-quality Rust path (above + build pipeline, precompiled binaries per OS/arch) | 5–9 months |
| General-purpose Python-loop JIT for *arbitrary* code | Don't. Use Numba / Codon and call Python from Elixir via [Ports](https://hexdocs.pm/elixir/Port.html) instead. |

## Open questions to investigate first

1. **What fraction of our eval corpus would the narrow gate catch?**
   If only 2-3 samples qualify, the prototype isn't worth the
   complexity — keep the timeouts. If 30+ qualify (likely true for
   competitive-programming-style benchmarks where most code IS tight
   numerical loops), it pays off easily.

2. **Could we lower to `Nx.Defn` instead of Rust?** Nx already has
   the "restricted-Elixir AST → native" infrastructure built. We'd
   inherit all of it. Risk: Nx is *tensor*-shaped — it loves
   batched-array operations and dislikes scalar pointer-walks. A
   one-day spike: try to lower one of our eval kernels (e.g. the
   sample 005 suffix-min loop) into a `defn` and see whether EXLA
   produces sensible code for it.

3. **How small can the marshalling cost go?** Concrete benchmark:
   measure pvec → `Vec<i64>` conversion for N ∈ {1K, 10K, 100K, 1M}.
   If conversion takes longer than today's whole-Elixir loop for
   N=10K, the resource-handle dodge isn't optional, it's the entire
   feature.

4. **Hybrid emission?** Pylixir keeps emitting Elixir for everything
   *except* the innermost hot loops, which become NIF calls. The
   control flow stays BEAM-native, only the leaves go native. This
   minimizes marshalling — most state lives BEAM-side and only the
   loop-local arrays are lifted. Worth a design sketch before
   committing to the full resource-handle infrastructure.

## TL;DR

To get past the last few timeouts you'd need to **compile the entire
hot loop to native code in one go**, not call NIFs per operation
(which is slower than what we have).

There are two orthogonal questions:
- **When** to compile: AOT (at Pylixir build time) or JIT (at runtime).
  Pylixir mostly doesn't need JIT — pick AOT.
- **What** to compile to: per-program Rust source, or a portable IR
  (WASM / Cranelift / LLVM) consumed by a single shared NIF.

The naive "ship Rust source, compile at runtime" idea fails because
`rustc` is far too slow to embed. But the same intuition — *generic
backend, kernels as data* — works perfectly with a portable IR.
**WASM via [wasmex](https://github.com/tessi/wasmex) is the
recommended target**: no external toolchain, no per-program .so, ~1-5
ms compile, sandboxed, cross-platform. The closest in-ecosystem
precedent is `Nx.Defn`/`EXLA`; the closest out-of-ecosystem precedent
is Cython for the source-based path, Numba for the IR-based path.

Quickest perf-validation prototype: 1-2 weeks (Rust source).
Production-quality WASM path: ~3-6 months. Don't build a real JIT.
