# RFC-001: pylixir — Python AST to Elixir Transpiler Implementation Plan

**Status:** Draft → Implementation Plan (v7)
**Created:** 2026-05-09
**Revised:** 2026-05-11 (v7 — restructured: merged implementation files, deduplicated version tables and helper definitions, added boolean comparison edge case, added float('inf')/str.split("") edge cases, fixed stale truthy? call-site references, consolidated helper canonical definitions into single file)

---

## Document Index

| File | Sections | Description |
|------|----------|-------------|
| [00-overview.md](00-overview.md) | §1, §3, §4, §5 | Executive summary, motivation, scope boundaries, Python version compatibility |
| [01-python-concepts.md](01-python-concepts.md) | §2 | Python language concepts explained for Elixir developers |
| [02-architecture.md](02-architecture.md) | §6, §7, §8 | Pipeline design, Python AST reference, Elixir AST reference |
| [03-implementation.md](03-implementation.md) | §9, §10, §13 | Mutation strategy, context struct, all implementation notes and canonical helpers |
| [04-edge-cases.md](04-edge-cases.md) | §11 | Correctness traps and semantic gaps between Python and Elixir |
| [05-node-reference.md](05-node-reference.md) | §12 | Supported AST nodes, builtins mapping table |
| [06-testing-and-development.md](06-testing-and-development.md) | §14, §15, §16 | Testing strategy, development steps, project structure |
| [07-future-and-reference.md](07-future-and-reference.md) | §17, §18, §19, §20, §21, Appendices | Future enhancements, worked examples, references, glossary, AST JSON examples, edge case quick reference card |

### Conventions

- **Canonical helper definitions** live in §13.20 (inside `03-implementation.md`). Other sections reference helpers but do not redefine them.
- **Version compatibility** is defined once in §5 (inside `00-overview.md`). Other files reference §5 rather than duplicating the table.
- **Builtins mapping tables** live in §12.8 (inside `05-node-reference.md`). Implementation notes reference §12.8 for the authoritative table.
