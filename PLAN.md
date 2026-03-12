# Crystal LSP — Project Status & Roadmap

## Overview

A full-featured Language Server Protocol implementation for Crystal, written in pure Crystal with zero external dependencies. Provides intelligent code assistance — navigation, completion, refactoring, diagnostics, and more — by combining a fast AST subsystem with `crystal tool` compiler integration.

- **8,686 LOC** source across 80 files, **5,623 LOC** specs, **389 passing tests**
- 23 providers, 28 handlers, 5 AST visitors, 12 infrastructure modules
- Crystal >= 1.19.1, stdlib only (includes `compiler/crystal/syntax`)
- MIT licensed, CI on Crystal latest + nightly

---

## Architecture

```
stdin/stdout
    │
Transport::Stdio ─── JSON-RPC 2.0, Content-Length framing, 10MB limit
    │
Server ─── main loop, project root detection, diagnostics worker, signal handling
    │
Dispatcher ─── lazy-init, routes 39 methods → handlers, sync/async dispatch
    │
Handlers (28 files) ─── extract params, call provider, format response
    │
Providers (23 files) ─── business logic
    ├─ CrystalTool ─── compiler invocations, 30s timeout, cancellation, request coalescing
    ├─ ToolResultCache ─── LRU (500 entries, 60s TTL) for tool results
    ├─ DocumentStore ─── in-memory incremental text editing
    ├─ AST subsystem ─── parser, cache, lexer tokenizer, 5 visitors
    │   ├─ AST::Index ─── persistent cross-file symbol index, background parsing
    │   └─ IndexVisitor, SymbolVisitor, ReferenceVisitor, ContextVisitor, CallVisitor
    ├─ WorkspaceIndex ─── background indexing, regex symbol search
    └─ RequireGraph ─── dependency edges, BFS transitive dependents
```

### Concurrency

Main fiber reads stdin synchronously. Nine methods dispatch asynchronously in spawned fibers with `CancellationToken` support: `definition`, `typeDefinition`, `implementation`, `hover`, `formatting`, `rename`, `prepareCallHierarchy`, and both call hierarchy directions. Diagnostics run in a dedicated worker fiber with mutex-protected channel-based debouncing (500ms default). Hover dispatches `context` and `implementations` tool calls in parallel. Request coalescing deduplicates concurrent identical `crystal tool` invocations — the first caller runs the process, others wait for its result.

### AST Integration

Per-document AST cache keyed by URI + version, invalidated on `didChange`/`didClose`. Persistent cross-file AST index parses all workspace `.cr` files at startup (batched, ~1ms/file) and updates incrementally on edits. Two-tier diagnostics: instant syntax errors via `Crystal::Parser`, debounced full build via `crystal build --no-codegen`. All AST-enhanced providers fall back to regex on parse failure so editing never blocks on a broken file.

### Infrastructure Modules

| Module | LOC | Role |
|--------|-----|------|
| server | 419 | Main loop, diagnostics worker, project detection, signal handling, idle pre-compilation |
| crystal_tool | 253 | Process spawning, 30s timeout, cancellation, request coalescing |
| require_graph | 246 | Resolve relative/absolute/glob/directory requires, BFS transitive dependents |
| workspace_index | 233 | Background file indexing, regex symbol search, progress reporting |
| dispatcher | 190 | Method routing, sync/async dispatch, cancel request handling |
| diagnostics (infra) | 142 | Content-hash caching, diff-based publishing, multi-file routing |
| document_store | 136 | In-memory document state, incremental editing |
| tool_result_cache | 122 | LRU cache for crystal tool results |
| configuration | 75 | Runtime settings, diagnostic severity/debounce/suppression |
| request_tracker | 58 | In-flight request tracking, cancellation coordination |
| logger | 51 | Structured JSON logging with request ID and duration |
| cancellation_token | 15 | Fiber-safe cancellation primitive |

---

## LSP Methods (39 registered)

| Category | Methods | Count |
|----------|---------|-------|
| Lifecycle | `initialize`, `initialized`, `shutdown`, `exit` | 4 |
| Document Sync | `didOpen`, `didChange`, `didSave`, `didClose` (incremental) | 4 |
| Navigation | `definition`, `typeDefinition`, `implementation`, `references` | 4 |
| Editing | `completion`, `signatureHelp`, `hover`, `rename`, `prepareRename`, `formatting`, `codeAction`, `linkedEditingRange` | 8 |
| Symbols | `documentSymbol`, `workspace/symbol` | 2 |
| Intelligence | `semanticTokens/full`, `semanticTokens/full/delta`, `documentHighlight`, `foldingRange`, `selectionRange` | 5 |
| Call Hierarchy | `prepareCallHierarchy`, `callHierarchy/incomingCalls`, `callHierarchy/outgoingCalls` | 3 |
| Type Hierarchy | `prepareTypeHierarchy`, `typeHierarchy/supertypes`, `typeHierarchy/subtypes` | 3 |
| Extras | `inlayHint`, `codeLens`, `workspace/executeCommand` | 3 |
| Workspace | `didChangeConfiguration`, `didChangeWorkspaceFolders`, `didChangeWatchedFiles` | 3 |
| **Total** | + `$/cancelRequest` (handled inline) | **39 + 1** |

## Providers (23)

| Provider | LOC | What it does |
|----------|-----|-------------|
| code_action | 529 | 7 actions: unused var fix, method stub, add require, organize requires, extract variable, extract method, convert block syntax, expand macro |
| semantic_tokens | 383 | Lexer-based tokenization, 10+ token types, delta encoding with per-document token cache |
| completion | 381 | Keywords, snippets, context-aware dot-completion (`.`, `:`, `@` triggers) |
| call_hierarchy | 354 | Incoming/outgoing calls, AST-based with regex fallback |
| hover | 316 | Type info + doc comments, Tier 1 pattern macro expansion, Tier 2 `crystal tool expand` (cached, non-blocking), parallel tool dispatch, AST index doc lookup |
| document_symbol | 228 | Hierarchical outline — classes, methods, macros, constants, properties |
| inlay_hints | 221 | Variable and parameter type annotations |
| type_hierarchy | 211 | Supertypes/subtypes for classes, structs, modules |
| macro_expander | 147 | Pattern-based expansion for `property`, `getter`, `setter`, `record` macros |
| signature_help | 146 | Active parameter tracking, `(` and `,` triggers |
| diagnostics | 142 | Two-tier (syntax + full build), content-hash caching, diff-based publishing, severity filtering |
| selection_range | 138 | Word → block → method → class → document expansion |
| rename | 125 | Type-aware, AST-based with prepare support |
| references | 124 | AST in-document, AST index cross-file, regex fallback |
| document_highlight | 123 | Read/write occurrence classification |
| folding_range | 119 | Blocks, requires, comment sections |
| type_definition | 102 | Navigate to variable/expression type source |
| linked_editing_range | 99 | Block keyword ↔ `end` simultaneous editing |
| code_lens | 94 | Reference counts above methods/classes |
| workspace_symbol | 73 | Cross-file symbol search via AST index with regex fallback |
| definition | 65 | AST index lookup with `crystal tool` fallback |
| implementation | 34 | Abstract type implementations |
| formatting | 20 | `crystal tool format` (full document) |

### AST Subsystem

| File | LOC | Role |
|------|-----|------|
| index_visitor | 303 | Walks AST to build persistent cross-file symbol index |
| lexer_tokenizer | 271 | Drives Crystal::Lexer for semantic token generation |
| index | 225 | Cross-file symbol storage, lookup, incremental updates |
| reference_visitor | 159 | Finds all references to a symbol within a file |
| symbol_visitor | 154 | Extracts hierarchical document symbols |
| context_visitor | 118 | Resolves symbol at cursor position |
| parser | 53 | Wrapper around Crystal::Parser with error recovery |
| cache | 54 | Per-document AST cache keyed by URI + version |
| call_visitor | 49 | Extracts call sites for call hierarchy |
| indexed_symbol | 31 | Symbol data structure for the cross-file index |

---

## Development History

| Phase | Focus | Delivered |
|-------|-------|-----------|
| 1 | Reliability | Timeouts, race fix, Content-Length limit, temp file cleanup, URI/symlink handling |
| 2 | Performance | File index cache, symbol cache, workspace indexing, progress reporting |
| 3 | Core Features | Semantic tokens, call hierarchy, inlay hints, code lens, configuration |
| 4 | Intelligence | Context-aware completion, doc comments, type-aware rename, extract refactoring |
| 5 | Polish | Structured logging, integration tests, graceful shutdown, CI/CD, editor docs |
| 6 | Concurrency | Async dispatch, CancellationToken, file watching, diagnostics caching |
| 7 | AST Integration | Parser/lexer/visitors, two-tier diagnostics, AST-aware providers with regex fallback |
| 8 | Incremental Diagnostics | Diagnostic diffing, multi-file routing, require graph, idle pre-compilation |
| 9 | Medium Features | Severity config, linked editing, type hierarchy, enhanced code actions |
| 10 | Advanced Intelligence | Semantic tokens delta, macro-aware intelligence, persistent cross-file AST index |
| 11 | Compiler Acceleration | Tool result cache, request coalescing, parallel hover dispatch, `crystal tool expand`, expand command |

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
| Source files | 80 |
| Source LOC | 8,686 |
| Spec LOC | 5,623 |
| Tests | 389 passing, 0 failing |
| External deps | 0 |
| Crystal version | >= 1.19.1 |
| CI | GitHub Actions (latest + nightly) |
| License | MIT |
