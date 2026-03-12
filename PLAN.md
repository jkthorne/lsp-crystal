# Crystal LSP — Production Readiness Plan

## Current State

- ~3,800 LOC, 89 specs, 14 providers, 0 external dependencies
- Clean layered architecture: Transport → Dispatcher → Handlers → Providers → CrystalTool
- Covers most-used LSP features (hover, completion, definition, references, rename, etc.)
- Suitable for small projects; not yet production-hardened for large codebases

---

## Critical Gaps

| Gap | Impact | Why It Matters |
|-----|--------|----------------|
| No crystal tool timeout | LSP hangs indefinitely | Compiler stuck on large/broken code = frozen editor |
| No workspace caching | O(n*m) per references/symbol query | Every request re-reads every `.cr` file |
| Race condition on `@pending_diagnostics` | Missed/duplicate diagnostics | Main fiber + worker fiber both access without sync |
| No Content-Length limit | OOM crash | Malformed header allocates unbounded memory |
| Text-based references/rename | False positives | Renames `name` inside `filename` — not type-aware |

## Missing LSP Features (by impact)

| Feature | Editor Impact | Difficulty |
|---------|--------------|------------|
| Semantic tokens | Syntax highlighting quality | Hard (needs AST) |
| Call hierarchy | "Who calls this?" navigation | Medium |
| Inlay hints | Inline type annotations | Medium |
| Code lens | Run/debug annotations | Easy-Medium |
| Type hierarchy | Inheritance browsing | Medium |
| Progress reporting | UX during slow ops | Easy |
| Configuration | User customization | Easy |
| Workspace folders | Multi-root projects | Medium |
| File watching | External change detection | Medium |

## Architectural Weaknesses

1. **All providers are regex-based** — no AST, no semantic understanding. This caps the quality ceiling for completion, references, rename, and symbols.
2. **No result caching** — workspace symbol and references re-glob and re-read all files per request.
3. **Single-threaded request handling** — crystal tool calls block the main loop.
4. **No incremental compilation** — every diagnostic runs `crystal build --no-codegen` from scratch.

---

## Phase 1: Reliability & Safety

**Goal: Won't crash or hang in real use.**

- [x] Add timeout to `CrystalTool.run()` — 30s default, configurable
- [x] Fix `@pending_diagnostics` race — replace with channel-based queuing or mutex
- [x] Add Content-Length validation — reject messages > 10MB
- [x] Add `ensure` blocks for temp file cleanup in `check_content`
- [x] Validate document URI paths — reject paths outside workspace root
- [x] Handle symlinks in `Dir.glob` — skip symlink cycles

## Phase 2: Performance

**Goal: Usable on projects with 1,000+ files.**

- [x] File index cache — maintain in-memory list of `.cr` files, invalidate on `didChangeWatchedFiles`
- [x] Symbol cache per document — cache `DocumentSymbol` results, invalidate on `didChange`
- [x] Workspace symbol index — background-index all files on init, update incrementally
- [x] References search optimization — search index instead of re-reading all files
- [x] Add `window/workDoneProgress` — report progress on slow operations (diagnostics, workspace search)

## Phase 3: Missing Core Features

**Goal: Feature parity with basic language servers.**

- [ ] Semantic tokens — use Crystal's parser/lexer for token classification (keywords, types, strings, comments, variables)
- [ ] Call hierarchy — `crystal tool implementations` can provide incoming/outgoing calls
- [ ] Inlay hints — show inferred types using `crystal tool context`
- [ ] Code lens — "N references" count above methods/classes
- [ ] Configuration support — handle `workspace/didChangeConfiguration`, support settings like crystal path, format on save, diagnostic delay
- [ ] Multiple workspace folders — handle `workspace/didChangeWorkspaceFolders`

## Phase 4: Smarter Intelligence

**Goal: Completion and navigation that actually understands Crystal.**

- [ ] Context-aware completion — use `crystal tool context` for dot-completion (method/property suggestions on typed objects)
- [ ] Improved hover — include documentation from comments above definitions
- [ ] Type-aware rename — use `crystal tool implementations` to find true references, not text matches
- [ ] Extract method/variable refactoring — code actions for common refactors
- [ ] Go-to-type-definition — separate from go-to-definition

## Phase 5: Polish & Hardening

**Goal: 1.0 release quality.**

- [ ] Structured logging — JSON log format with request IDs for tracing
- [ ] Integration test suite — tests against real Crystal project files
- [ ] Concurrency stress tests — rapid open/edit/close cycles
- [ ] Large file tests — documents with 10K+ lines
- [ ] Graceful shutdown — handle SIGTERM, drain pending work
- [ ] CI/CD pipeline — automated build + test on Crystal nightly
- [ ] Editor-specific documentation — VS Code, Neovim, Helix, Zed setup guides

---

## Priority Matrix

```
         HIGH IMPACT
              |
  Semantic    |   Timeouts
  Tokens      |   Caching
  Completion  |   Race Fix
              |   Progress
              |
LOW ----------+---------- HIGH EFFORT
EFFORT        |
  Config      |   Multi-workspace
  Code Lens   |   Call Hierarchy
  Inlay Hints |   Type-aware Rename
              |
         LOW IMPACT
```

Start top-right (high impact, necessary), then top-left (high impact, quick wins), then bottom as time allows.

## Estimated Effort

- **Minimum viable production (Phases 1-2):** ~2 weeks — safe, performant, current features
- **Competitive LSP (Phases 1-4):** ~6 weeks — smart completion, semantic understanding
- **Polished 1.0 (all phases):** ~7 weeks — full test suite, CI, docs
