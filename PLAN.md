# Crystal LSP — Status & Future Plan

## Current State (v0.1.0)

- **4,668 LOC** source, **3,074 LOC** specs, **200 passing tests**
- 20 providers, 23 handlers, 0 external dependencies (Crystal stdlib only)
- Clean layered architecture: Transport → Dispatcher → Handlers → Providers → CrystalTool
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
| Workspace | `didChangeConfiguration`, `didChangeWorkspaceFolders`, `window/workDoneProgress` |

### Infrastructure

- 30s configurable timeout on all `crystal tool` invocations
- Mutex-protected diagnostics with channel-based debouncing (500ms default)
- Content-Length validation (10MB max)
- Background workspace indexing with incremental updates
- In-memory symbol cache per document
- SIGTERM/SIGINT graceful shutdown
- JSON structured logging with request ID and duration tracing

---

## Completed Phases

All five original plan phases are complete:

- **Phase 1 — Reliability & Safety:** Timeouts, race fix, Content-Length limit, temp file cleanup, URI validation, symlink handling
- **Phase 2 — Performance:** File index cache, symbol cache, workspace index, references optimization, progress reporting
- **Phase 3 — Core Features:** Semantic tokens, call hierarchy, inlay hints, code lens, configuration, workspace folders
- **Phase 4 — Smarter Intelligence:** Context-aware completion, doc comments in hover, type-aware rename, extract refactoring, type definition
- **Phase 5 — Polish & Hardening:** Structured logging, integration/stress/large-file tests, graceful shutdown, CI/CD, editor docs

---

## Remaining Limitations

These are known architectural constraints that limit quality but are not blockers for typical use:

1. **Regex-based providers** — Document symbols, references, highlights, and rename are pattern-matching based, not AST-aware. This causes occasional false positives (e.g. matching a word inside a string or comment).
2. **No incremental compilation** — Every diagnostic runs a full `crystal build --no-codegen`. Slow on large projects.
3. **Single-fiber request handling** — Crystal tool calls block the main loop. Long-running operations (diagnostics, context) can delay responses to fast operations (symbols, highlights).
4. **No file watcher** — External file changes (git checkout, external editor saves) are only detected on next workspace indexing. The server relies on `didOpen`/`didChange` for open files.
5. **Semantic tokens are regex-based** — Not using Crystal's actual lexer/parser, so edge cases in string interpolation, heredocs, and macros may be misclassified.

## Future Work

Potential improvements if the project continues beyond 1.0:

### High Impact
- **Crystal AST integration** — Use Crystal's compiler API for true semantic analysis instead of regex. Would dramatically improve accuracy of symbols, references, rename, and completion.
- **Incremental diagnostics** — Cache compilation state between runs or use `crystal tool` for faster feedback.
- **Concurrent request handling** — Process crystal tool calls in spawned fibers so fast requests aren't blocked by slow ones.
- **File watching** — Implement `workspace/didChangeWatchedFiles` to detect external changes.

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
