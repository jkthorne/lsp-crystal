# Crystal LSP — Status & Future Plan

## Current State (v0.2.0)

- **~6,400 LOC** source, **~4,550 LOC** specs, **313 passing tests**
- 23 providers, 27 handlers, 0 external dependencies (Crystal stdlib only)
- Clean layered architecture: Transport → Dispatcher → Handlers → Providers → CrystalTool / AST
- Crystal AST integration via `compiler/crystal/syntax` — zero external dependencies maintained
- Two-tier async dispatch: slow crystal-tool requests run in fibers, fast requests stay synchronous
- File watching via dynamic `client/registerCapability` registration
- Diagnostics content-hash caching, diff-based publishing, active file priority, configurable debounce
- Require dependency graph for targeted invalidation of affected files
- Multi-file diagnostic routing (errors published under their source file URI)
- Idle background pre-compilation for cache warming
- Structured JSON logging with request tracing, graceful signal handling
- GitHub Actions CI against Crystal latest + nightly
- Editor docs for VS Code, Neovim, Helix, Zed, Sublime Text, Emacs

---

## Implemented Features

### LSP Methods Supported

| Category | Methods |
|----------|---------|
| Lifecycle | `initialize`, `initialized`, `shutdown`, `exit` |
| Document Sync | `didOpen`, `didChange`, `didSave`, `didClose` (incremental) |
| Navigation | `definition`, `typeDefinition`, `implementation`, `references` |
| Editing | `completion`, `signatureHelp`, `hover`, `rename`, `prepareRename`, `formatting`, `codeAction`, `linkedEditingRange` |
| Symbols | `documentSymbol`, `workspace/symbol` |
| Intelligence | `semanticTokens/full`, `documentHighlight`, `foldingRange`, `selectionRange` |
| Advanced | `prepareCallHierarchy`, `callHierarchy/incomingCalls`, `callHierarchy/outgoingCalls`, `prepareTypeHierarchy`, `typeHierarchy/supertypes`, `typeHierarchy/subtypes`, `inlayHint`, `codeLens` |
| Workspace | `didChangeConfiguration`, `didChangeWorkspaceFolders`, `didChangeWatchedFiles`, `window/workDoneProgress` |
| Concurrency | `$/cancelRequest`, async dispatch for slow methods |

### Infrastructure

- 30s configurable timeout on all `crystal tool` invocations with cancellation support
- Concurrent request handling: slow methods (definition, hover, formatting, rename, etc.) run in spawned fibers with `CancellationToken` support
- `RequestTracker` manages in-flight async requests; `$/cancelRequest` terminates running crystal processes
- File watching: dynamic `client/registerCapability` for `**/*.cr` files; detects external changes (git checkout, other editors)
- Diagnostics content-hash caching: skips re-running compiler when content unchanged
- Diagnostic diffing: compares by value before publishing, eliminates editor flicker
- Multi-file diagnostic routing: errors from `crystal build` published under their source file URI, stale diagnostics cleared automatically
- Require dependency graph (`RequireGraph`): resolves relative, absolute, glob, and directory-form requires; tracks dependency/dependent edges; BFS transitive dependents
- Smart file-change invalidation: only re-diagnoses open files that transitively depend on the changed external file (falls back to all-open when graph not built)
- Idle background pre-compilation: warms OS/compiler caches after 5s idle, cancelled on edit, configurable via `precompileOnIdle`
- Active file priority: most recently edited file gets diagnosed first
- Configurable debounce via `diagnosticsDelay` setting (500ms default)
- Diagnostic severity filtering (`diagnosticsMinSeverity`) and message pattern suppression (`diagnosticsSuppressedPatterns`)
- Mutex-protected diagnostics with channel-based debouncing
- Content-Length validation (10MB max)
- Background workspace indexing with incremental updates
- In-memory symbol cache per document
- Server→client request support (`send_request` with auto-incrementing IDs)
- SIGTERM/SIGINT graceful shutdown with in-flight request cancellation
- JSON structured logging with request ID and duration tracing

---

## Completed Phases

All five original plan phases plus high-impact improvements are complete:

- **Phase 1 — Reliability & Safety:** Timeouts, race fix, Content-Length limit, temp file cleanup, URI validation, symlink handling
- **Phase 2 — Performance:** File index cache, symbol cache, workspace index, references optimization, progress reporting
- **Phase 3 — Core Features:** Semantic tokens, call hierarchy, inlay hints, code lens, configuration, workspace folders
- **Phase 4 — Smarter Intelligence:** Context-aware completion, doc comments in hover, type-aware rename, extract refactoring, type definition
- **Phase 5 — Polish & Hardening:** Structured logging, integration/stress/large-file tests, graceful shutdown, CI/CD, editor docs
- **Phase 6 — Concurrency & Responsiveness:** Async dispatch with CancellationToken, file watching via dynamic registration, diagnostics caching with content hashing, active file priority, configurable debounce
- **Phase 7 — Crystal AST Integration:** AST-based document symbols, lexer-based semantic tokens, two-tier diagnostics (instant syntax + debounced full), AST-aware references/highlights/rename (ignores strings/comments), AST context completion, AST call hierarchy. All providers fall back to regex on parse failure.
- **Phase 8 — Incremental Diagnostics:** Diagnostic diffing (skip identical publishes), multi-file error routing, require dependency graph with targeted invalidation, idle background pre-compilation for cache warming.
- **Phase 9 — Medium-Impact Features:** Diagnostic severity configuration, linked editing ranges for block/end pairs, type hierarchy (supertypes/subtypes), enhanced code actions (generate method stub, add missing require, convert to multi-line block).

---

## Remaining Limitations

These are known architectural constraints that limit quality but are not blockers for typical use:

1. **No incremental compilation** — Every full diagnostic runs a full `crystal build --no-codegen`. Content-hash caching, diagnostic diffing, and require-graph-targeted invalidation reduce redundant work, but each run is still whole-program. Syntax errors are instant via Crystal::Parser.
2. **Cross-file references use regex** — In-document references use AST (accurate), but cross-file search still uses workspace index regex. Parsing every workspace file on each reference request would be too slow.

## Future Work

Potential improvements if the project continues beyond 1.0:

### Medium Impact (Phase 9 — Complete)
- ~~**Type hierarchy** — `typeHierarchy/supertypes` and `typeHierarchy/subtypes` for inheritance browsing.~~
- ~~**Linked editing ranges** — Simultaneous editing of matching pairs (e.g. block/end).~~
- ~~**Workspace edits** — Multi-file refactoring support beyond rename.~~
- ~~**Diagnostic severity configuration** — Let users suppress specific warning categories.~~

### Low Impact
- **Range formatting** — Format selected regions instead of whole file.
- **On-type formatting** — Auto-format as the user types.
- **Document links** — Make `require` paths clickable.
- **Color provider** — Preview color literals in the gutter.
