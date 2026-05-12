# RFC-001: pylixir — Python AST to Elixir Transpiler Implementation Plan

**Status:** Draft → Implementation Plan (v9)
**Created:** 2026-05-09
**Revised:** 2026-05-12 (v9 — restructured files for implementer ergonomics, consolidated duplicated explanations to single canonical locations, added new edge cases: `isinstance(True, int)` silent correctness trap §11.31, list out-of-bounds `nil` vs `IndexError` §11.32, `List.replace_at` silent no-op on out-of-bounds §11.33, `min`/`max` with 3+ args §12.8, `Set` literal vs `set()` constructor clarification §7.2, `dict()` keyword constructor form §12.8)

---

## Document Index

| File | Sections | Description |
|------|----------|-------------|
| [00-overview.md](00-overview.md) | §1, §3, §4, §5 | Executive summary, motivation, scope boundaries, Python version compatibility |
| [01-python-concepts.md](01-python-concepts.md) | §2 | Python language concepts explained for Elixir developers |
| [02-ast-reference.md](02-ast-reference.md) | §6, §7 | Pipeline design, Python AST node reference, supported node summary |
| [03-elixir-ast.md](03-elixir-ast.md) | §8 | Elixir AST reference — standalone reference for implementers |
| [04-mutation-and-context.md](04-mutation-and-context.md) | §9, §10 | Mutation strategy, method tables, context struct |
| [05-edge-cases.md](05-edge-cases.md) | §11 | Correctness traps and semantic gaps between Python and Elixir |
| [06-implementation.md](06-implementation.md) | §13 | All implementation notes and canonical helper definitions |
| [07-builtins.md](07-builtins.md) | §12 | Supported AST nodes detail, builtins mapping table |
| [08-testing.md](08-testing.md) | §14, §15, §16 | Testing strategy, development steps, project structure |
| [09-examples-and-appendices.md](09-examples-and-appendices.md) | §18, §19, Appendices A, B | Worked examples, AST JSON examples, edge case quick reference card |
| [10-future.md](10-future.md) | §17, §20, §21 | Future enhancements, references, glossary |

### Conventions

- **Canonical helper definitions** live in §13.20 (inside `06-implementation.md`). Other sections reference helpers but do not redefine them.
- **Python AST version notes** are in §5 (inside `00-overview.md`). Key rule: treat all version-dependent fields as optional.
- **Builtins mapping tables** live in §12.8 (inside `07-builtins.md`). Implementation notes reference §12.8 for the authoritative table.
- **String/dict/mutation method tables** live in §9.4, §9.5, and §9.5.1 (inside `04-mutation-and-context.md`). §12.8 references these for the authoritative tables.
- **Truthiness semantics** are defined canonically in §11.3 (inside `05-edge-cases.md`). The `truthy?/1` helper code is in §13.20. All other references are brief pointers.
- **`&&`/`||`/`!` vs `and`/`or`/`not`** rationale is canonically in §9.7 (inside `04-mutation-and-context.md`). All other mentions are one-line pointers.
- **`iodata` gotcha** for `Code.format_string!/1` is canonically in §6.1.1 (inside `02-ast-reference.md`). All other mentions are one-line pointers.
- **`MapSet` before `is_map` clause ordering** is canonically in §13.20 (inside `06-implementation.md`). All other mentions are one-line pointers.
