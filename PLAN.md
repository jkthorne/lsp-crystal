# Crystal LSP — Status & Future Plan

## Current State (v0.2.0)

- **~4,900 LOC** source, **~3,400 LOC** specs, **223 passing tests**
- 20 providers, 24 handlers, 0 external dependencies (Crystal stdlib only)
- Clean layered architecture: Transport → Dispatcher → Handlers → Providers → CrystalTool
- Two-tier async dispatch: slow crystal-tool requests run in fibers, fast requests stay synchronous
- File watching via dynamic `client/registerCapability` registration
- Diagnostics content-hash caching, active file priority, configurable debounce
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
| Editing | `completion`, `signatureHelp`, `hover`, `rename`, `prepareRename`, `formatting`, `codeAction` |
| Symbols | `documentSymbol`, `workspace/symbol` |
| Intelligence | `semanticTokens/full`, `documentHighlight`, `foldingRange`, `selectionRange` |
| Advanced | `prepareCallHierarchy`, `callHierarchy/incomingCalls`, `callHierarchy/outgoingCalls`, `inlayHint`, `codeLens` |
| Workspace | `didChangeConfiguration`, `didChangeWorkspaceFolders`, `didChangeWatchedFiles`, `window/workDoneProgress` |
| Concurrency | `$/cancelRequest`, async dispatch for slow methods |

### Infrastructure

- 30s configurable timeout on all `crystal tool` invocations with cancellation support
- Concurrent request handling: slow methods (definition, hover, formatting, rename, etc.) run in spawned fibers with `CancellationToken` support
- `RequestTracker` manages in-flight async requests; `$/cancelRequest` terminates running crystal processes
- File watching: dynamic `client/registerCapability` for `**/*.cr` files; detects external changes (git checkout, other editors)
- Diagnostics content-hash caching: skips re-running compiler when content unchanged
- Active file priority: most recently edited file gets diagnosed first
- Configurable debounce via `diagnosticsDelay` setting (500ms default)
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

---

## Remaining Limitations

These are known architectural constraints that limit quality but are not blockers for typical use:

1. **Regex-based providers** — Document symbols, references, highlights, and rename are pattern-matching based, not AST-aware. This causes occasional false positives (e.g. matching a word inside a string or comment).
2. **No incremental compilation** — Every diagnostic runs a full `crystal build --no-codegen`. Content-hash caching avoids redundant runs, but each run is still whole-program.
3. **Semantic tokens are regex-based** — Not using Crystal's actual lexer/parser, so edge cases in string interpolation, heredocs, and macros may be misclassified.

## Future Work

Potential improvements if the project continues beyond 1.0:

### High Impact
- **Crystal AST integration** — Use Crystal's compiler API for true semantic analysis instead of regex. Would dramatically improve accuracy of symbols, references, rename, and completion. Blocked on Crystal exposing a stable compiler library API.
- **Incremental diagnostics** — Cache compilation state between runs. Requires Crystal compiler changes for partial re-checking.

### Medium Impact
- **Type hierarchy** — `typeHierarchy/supertypes` and `typeHierarchy/subtypes` for inheritance browsing.
- **Linked editing ranges** — Simultaneous editing of matching pairs (e.g. block/end).
- **Workspace edits** — Multi-file refactoring support beyond rename.
- **Diagnostic severity configuration** — Let users suppress specific warning categories.

### Low Impact
- **Range formatting** — Format selected regions instead of whole file.
- **On-type formatting** — Auto-format as the user types.
- **Document links** — Make `require` paths clickable.
- **Color provider** — Preview color literals in the gutter.
