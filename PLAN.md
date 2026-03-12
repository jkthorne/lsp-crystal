# Crystal LSP — Project Status & Roadmap

## Current State

- **8,686 LOC** source across 80 files, **5,623 LOC** specs, **389 passing tests**
- 23 providers, 28 handlers, 5 AST visitors, 0 external dependencies
- Crystal >= 1.19.1, stdlib only (includes `compiler/crystal/syntax`)
- MIT licensed, CI on Crystal latest + nightly

### Architecture

```
stdin/stdout
    │
Transport::Stdio (JSON-RPC 2.0, Content-Length framing, 10MB limit)
    │
Server (main loop, project root detection, diagnostics worker)
    │
Dispatcher (lazy-init, routes methods → handlers)
    │
Handlers (26 files — extract params, call provider, format response)
    │
Providers (22 files — business logic)
    ├─ CrystalTool (compiler invocations, 30s timeout, cancellation, request coalescing)
    ├─ ToolResultCache (LRU cache for tool results, 500 entries, 60s TTL)
    ├─ DocumentStore (in-memory incremental editing)
    ├─ AST subsystem (parser, cache, lexer tokenizer, 5 visitors)
    ├─ AST::Index (persistent cross-file symbol index, background parsing)
    ├─ WorkspaceIndex (background indexing, regex symbol search)
    └─ RequireGraph (dependency edges, BFS transitive dependents)
```

**Concurrency model:** Main fiber reads stdin synchronously. Slow methods (definition, hover, formatting, rename, diagnostics) run in spawned fibers with `CancellationToken` support. Diagnostics use mutex-protected channel-based debouncing (500ms default). Hover runs `context` and `implementations` in parallel via spawned fibers. Request coalescing deduplicates concurrent identical `crystal tool` invocations.

**AST integration:** Per-document AST cache keyed by URI + version. Persistent cross-file AST index parses all workspace `.cr` files at startup (batched, ~1ms/file) and updates incrementally on edits. Two-tier diagnostics: instant syntax errors via `Crystal::Parser`, debounced full build via `crystal build --no-codegen`. All AST-enhanced providers fall back to regex on parse failure.

---

## Feature Inventory

### LSP Methods (40+)

| Category | Methods |
|----------|---------|
| Lifecycle | `initialize`, `initialized`, `shutdown`, `exit` |
| Document Sync | `didOpen`, `didChange`, `didSave`, `didClose` (incremental) |
| Navigation | `definition`, `typeDefinition`, `implementation`, `references` |
| Editing | `completion`, `signatureHelp`, `hover`, `rename`, `prepareRename`, `formatting`, `rangeFormatting`, `onTypeFormatting`, `codeAction`, `linkedEditingRange` |
| Symbols | `documentSymbol`, `workspace/symbol` |
| Intelligence | `semanticTokens/full`, `semanticTokens/full/delta`, `documentHighlight`, `foldingRange`, `selectionRange` |
| Hierarchy | `prepareCallHierarchy`, `callHierarchy/incomingCalls`, `callHierarchy/outgoingCalls`, `prepareTypeHierarchy`, `typeHierarchy/supertypes`, `typeHierarchy/subtypes` |
| Extras | `inlayHint`, `codeLens`, `codeLens/resolve`, `documentLink`, `documentColor`, `colorPresentation`, `workspace/executeCommand` |
| Workspace | `didChangeConfiguration`, `didChangeWorkspaceFolders`, `didChangeWatchedFiles`, `window/workDoneProgress` |
| Concurrency | `$/cancelRequest`, async dispatch for slow methods |

### Providers by Size

| Provider | LOC | Capabilities |
|----------|-----|-------------|
| code_action | 529 | Unused var fix, method stub, add require, organize requires, extract variable/method, convert block, expand macro |
| completion | 360 | Keywords, snippets, context-aware dot-completion (`.`, `:`, `@` triggers) |
| call_hierarchy | 354 | Incoming/outgoing calls, AST-based with regex fallback |
| semantic_tokens | 370 | Lexer-based tokenization, 10+ token types, delta encoding with token cache |
| document_symbol | 228 | Hierarchical outline (classes, methods, macros, constants, properties) |
| inlay_hints | 221 | Variable/parameter type annotations |
| type_hierarchy | 211 | Supertypes/subtypes for classes, structs, modules |
| signature_help | 146 | Active parameter tracking, `(` and `,` triggers |
| diagnostics | 142 | Two-tier, content-hash caching, diff-based publishing, severity filtering |
| selection_range | 138 | Word → block → method → class → document expansion |
| rename | 125 | Type-aware, AST-based with prepare support |
| document_highlight | 123 | Read/write occurrence classification |
| folding_range | 119 | Blocks, requires, comment sections |
| references | 125 | AST in-document, AST index cross-file with regex fallback |
| hover | 316 | Type info + doc comments, Tier 1 pattern macro expansion, Tier 2 crystal tool expand (cached, non-blocking), parallel tool dispatch, AST index doc lookup |
| type_definition | 102 | Navigate to variable/expression type |
| linked_editing_range | 99 | Block keyword ↔ `end` simultaneous editing |
| code_lens | 94 | Reference counts above methods/classes |
| macro_expander | 120 | Pattern-based expansion for property, getter, setter, record macros |
| workspace_symbol | 73 | Cross-file symbol search via AST index with regex fallback |
| implementation | 34 | Abstract type implementations |
| definition | 60 | AST index lookup with crystal tool fallback |
| formatting | 20 | crystal tool format (full + range + on-type) |

### Infrastructure

- **Transport:** Content-Length framing, 10MB max, header validation
- **Diagnostics:** Content-hash caching, diff-based publishing (no editor flicker), multi-file error routing, active file priority, configurable debounce/severity/pattern suppression
- **File watching:** Dynamic `client/registerCapability` for `**/*.cr`; detects external changes
- **RequireGraph:** Resolves relative/absolute/glob/directory requires; BFS transitive dependents; targeted invalidation on file changes
- **Tool result cache:** LRU (500 entries, 60s TTL) caching of `crystal tool` results; avoids redundant compiler invocations for hover, definition, and expand at the same position
- **Request coalescing:** Concurrent identical tool invocations deduplicate — first runs the process, others wait for its result
- **Background tasks:** Idle pre-compilation (5s), workspace indexing with incremental updates, background macro expansion
- **Logging:** Structured JSON with request ID and duration tracing
- **Shutdown:** SIGTERM/SIGINT graceful handling with in-flight request cancellation

---

## Development History

| Phase | Focus | Key Deliverables |
|-------|-------|-----------------|
| 1 | Reliability | Timeouts, race fix, Content-Length limit, temp file cleanup, URI/symlink handling |
| 2 | Performance | File index cache, symbol cache, workspace indexing, progress reporting |
| 3 | Core Features | Semantic tokens, call hierarchy, inlay hints, code lens, configuration |
| 4 | Intelligence | Context-aware completion, doc comments, type-aware rename, extract refactoring |
| 5 | Polish | Structured logging, integration tests, graceful shutdown, CI/CD, editor docs |
| 6 | Concurrency | Async dispatch, CancellationToken, file watching, diagnostics caching |
| 7 | AST Integration | Parser/lexer/visitors, two-tier diagnostics, AST-aware providers with regex fallback |
| 8 | Incremental Diagnostics | Diagnostic diffing, multi-file routing, require graph, idle pre-compilation |
| 9 | Medium Features | Severity config, linked editing, type hierarchy, enhanced code actions |
| 10 | Low Features | Range formatting, on-type formatting, document links, color provider |
| 11 | Advanced Intelligence | Semantic tokens delta, macro-aware intelligence, persistent cross-file AST index |
| 12 | Compiler Acceleration | Tool result cache, request coalescing, parallel hover dispatch, Tier 2 macro expand via `crystal tool expand`, expand command, auto-disable on failure |

---

## Known Limitations

1. **No incremental compilation** — Each full diagnostic runs `crystal build --no-codegen` on the whole program. Content-hash caching, diagnostic diffing, and require-graph targeting reduce redundant work, but each invocation is still whole-program. Syntax errors are instant via `Crystal::Parser`.

2. **Cross-file references partially AST-based** — Cross-file references now use the persistent AST index for accurate results, with regex fallback when the index is not ready or for files that fail to parse. Complex overloaded methods may still require `crystal tool` for full resolution.

3. **Macro expansion is two-tier** — Tier 1: Common macros (`property`, `getter`, `setter`, `record`) are expanded instantly via pattern matching. Tier 2: Arbitrary user-defined macros are expanded via `crystal tool expand` with result caching (non-blocking, background). Tier 2 requires a compilable project and adds latency on first hover; subsequent hovers serve from cache. Auto-disables after 3 consecutive failures.

4. **Single-project scope** — The server assumes one Crystal project per workspace root (detected via `shard.yml`). Multi-root workspaces with independent shards are not fully supported.

5. **No type inference without compiler** — Type information comes from `crystal tool context` which requires a full compiler pass. The AST subsystem provides syntax-level intelligence but cannot infer types independently.

---

## Future Roadmap

### High Impact

**~~Macro expansion Tier 2~~ (done)** — Implemented via `crystal tool expand` with LRU caching, non-blocking background expansion, and auto-disable on failure. Expanded symbols are indexed into the AST index.

**~~Compiler acceleration~~ (done)** — Tool result cache (LRU, 500 entries, 60s TTL), request coalescing for concurrent identical invocations, and parallel hover dispatch. Crystal has no daemon mode, so true incremental compilation isn't possible, but these optimizations eliminate redundant work.

### Medium Impact

**Completion resolve**
Implement `completionItem/resolve` to lazy-load documentation and detail for completion items. Currently all completion info is computed upfront. Resolve would speed up the initial completion list, especially for large projects.

**Diagnostic pull model**
Implement LSP 3.17 `textDocument/diagnostic` pull model alongside the current push model. Pull diagnostics give editors more control over when to request diagnostics and can reduce unnecessary computation.

**Smarter on-type formatting**
Extend on-type formatting beyond `end` insertion: auto-indent after `do`/`{`, auto-close string interpolation `#{}`, auto-indent `when` in case statements.

**Snippet completions for common patterns**
Add snippet-based completions for Crystal idioms: `spec describe/it` blocks, `JSON::Serializable` boilerplate, `property`/`getter`/`setter` with types, error handling patterns.

### Low Impact / Exploratory

**Debug Adapter Protocol (DAP)**
Crystal has limited debugging support, but a basic DAP implementation could provide breakpoints and variable inspection if Crystal gains better debug info in future releases.

**Test discovery and execution**
Detect `spec/**/*_spec.cr` files, extract `describe`/`it` blocks, and expose them via code lens or a custom LSP extension for in-editor test running.

**Workspace symbol resolve**
Implement `workspaceSymbol/resolve` to lazy-load location details for workspace symbol search results.

**Goto declaration**
Implement `textDocument/declaration` as distinct from definition, pointing to forward declarations or abstract method signatures.

---

## Project Health

| Metric | Value |
|--------|-------|
| Source LOC | 8,686 |
| Spec LOC | 5,623 |
| Tests passing | 389 |
| Tests failing | 0 |
| External deps | 0 |
| Crystal version | >= 1.19.1 |
| CI | GitHub Actions (latest + nightly) |
| License | MIT |
