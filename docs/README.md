# RFC-001: py2ex — Python AST to Elixir Transpiler Implementation Plan

**Status:** Draft → Implementation Plan (v5)
**Created:** 2026-05-09
**Revised:** 2026-05-10 (v5 — self-contained rewrite with deep research, edge cases, and Elixir-developer-oriented guidance)

---

## Document Index

| File | Sections | Description |
|------|----------|-------------|
| [00-overview.md](00-overview.md) | §1, §3, §4, §5 | Executive summary, motivation, scope boundaries, Python version compatibility |
| [01-python-concepts.md](01-python-concepts.md) | §2 | Python language concepts explained for Elixir developers |
| [02-architecture.md](02-architecture.md) | §6, §7, §8 | Pipeline design, Python AST reference, Elixir AST reference |
| [03-mutation-and-context.md](03-mutation-and-context.md) | §9, §10 | Mutation strategy, context struct design |
| [04-edge-cases.md](04-edge-cases.md) | §11 | Correctness traps and semantic gaps between Python and Elixir |
| [05-node-reference.md](05-node-reference.md) | §12 | Supported AST nodes, builtins mapping table |
| [06-implementation.md](06-implementation.md) | §13 | Detailed implementation notes per pattern |
| [07-testing-and-development.md](07-testing-and-development.md) | §14, §15, §16 | Testing strategy, development steps, project structure |
| [08-future.md](08-future.md) | §17 | Future enhancements and extension patterns |
| [09-examples.md](09-examples.md) | §18, §19 | Worked examples with full input/output walkthroughs |
| [10-references-and-glossary.md](10-references-and-glossary.md) | §20, §21 | External references, glossary of Elixir terms |
| [11-appendices.md](11-appendices.md) | Appendix A, B | Python AST JSON examples, edge case quick reference card |
