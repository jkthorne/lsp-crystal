# lsp-crystal

A Language Server Protocol (LSP) implementation for Crystal, written in Crystal with zero external dependencies.

## Features

### Navigation
- **Go to Definition** — Jump to symbol definitions via `crystal tool implementations`
- **Go to Type Definition** — Navigate to the type of a variable or expression
- **Go to Implementation** — Find all implementations of abstract types
- **Find References** — Search for symbol occurrences across the workspace
- **Document Symbols** — Hierarchical outline of classes, methods, macros, properties, constants, and more
- **Workspace Symbols** — Search symbols across all `.cr` files in the project
- **Call Hierarchy** — Incoming and outgoing call navigation
- **Type Hierarchy** — Browse supertypes and subtypes for classes, structs, and modules
- **Document Links** — Clickable `require` paths that navigate to the resolved file

### Editing
- **Completion** — Keywords, 21 snippets (Crystal idioms, spec blocks, JSON::Serializable boilerplate), and context-aware dot-completion (trigger: `.`, `:`, `@`), with lazy documentation resolution
- **Signature Help** — Method signature display with active parameter tracking (trigger: `(`, `,`)
- **Hover** — Type information and documentation comments via `crystal tool context`, with parallel tool dispatch for faster results
- **Rename** — Type-aware workspace-wide symbol renaming with prepare support
- **Code Actions** — Quick fix for unused variables, generate method stubs, add missing requires, organize/sort requires, extract variable/method, convert to multi-line block, expand macro
- **Linked Editing** — Simultaneous editing of block keywords and their matching `end`
- **Formatting** — Code formatting via `crystal tool format` (full document and range)
- **On-Type Formatting** — Auto-indent after block-opening keywords, auto-dedent `end` to match its opener
- **Inlay Hints** — Inline type annotations for variables and parameters
- **Code Lens** — Reference counts above methods and classes, lazily resolved for fast initial display

### Code Intelligence
- **Diagnostics** — Real-time error and warning reporting via `crystal build --no-codegen` with 500ms debounce, configurable severity filtering and pattern suppression
- **Semantic Tokens** — Token-level syntax highlighting with delta encoding (only changed tokens sent on edits)
- **Macro Intelligence** — Tier 1: instant pattern-based expansion of `property`, `getter`, `setter`, and `record` macros. Tier 2: arbitrary user-defined macro expansion via `crystal tool expand` with result caching (non-blocking). Expanded symbols are indexed for go-to-definition and workspace search. Explicit "Expand macro" command available via code actions
- **Cross-File AST Index** — Persistent in-memory index of all workspace symbols, updated incrementally on edits. Powers instant cross-file references, go-to-definition, rename, and workspace symbol search without compiler invocations
- **Document Highlight** — Highlight all occurrences of a symbol with read/write classification
- **Folding Ranges** — Fold blocks, consecutive requires, and comment sections
- **Selection Range** — Smart expand/shrink selection from word to block to document
- **Color Provider** — Preview hex color literals in the editor gutter

## Requirements

- Crystal >= 1.19.1

## Installation

```sh
git clone https://github.com/jackthorne/lsp-crystal.git
cd lsp-crystal
shards build --release
```

The binary will be at `bin/lsp-crystal`.

## Usage

The server communicates over stdin/stdout using the LSP protocol with JSON-RPC 2.0 and Content-Length framing.

### Neovim

```lua
vim.lsp.start({
  name = "crystal-lsp",
  cmd = { "/path/to/bin/lsp-crystal" },
  root_dir = vim.fs.dirname(vim.fs.find("shard.yml", { upward = true })[1]),
})
```

### VS Code

Use a generic LSP client extension and configure it to run `bin/lsp-crystal` with stdio transport.

### Other Editors

See [docs/editors.md](docs/editors.md) for setup guides for Helix, Zed, Sublime Text, and Emacs.

## Development

```sh
# Run specs
crystal spec

# Build debug
shards build

# Build release
shards build --release
```

## Architecture

```
stdin/stdout
  |
Transport::Stdio (Content-Length framing)
  |
Server (main loop, project detection, diagnostics worker)
  |
Dispatcher (routes JSON-RPC methods to handlers)
  |
Handlers (extract params, call provider, format response)
  |
Providers (business logic)
  |
CrystalTool        DocumentStore     AST::Index       ToolResultCache
(spawns crystal,   (in-memory docs)  (cross-file      (LRU cache for
 coalescing)                          symbols)          tool results)
```

Key design decisions:
- Zero external dependencies — Crystal stdlib only
- All LSP types use `JSON::Serializable` with camelCase field mapping
- Main fiber reads stdin synchronously; diagnostics run in spawned fibers with 500ms debounce
- Hover runs context and implementations in parallel; request coalescing deduplicates concurrent identical tool invocations
- Tool result cache (LRU, 60s TTL) eliminates redundant compiler invocations
- Unsaved files use stdin for formatting, temp files for diagnostics
- Project root detected via `shard.yml` targets

## Contributing

1. Fork it (<https://github.com/jackthorne/lsp-crystal/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## License

MIT

## Contributors

- [Jack Thorne](https://github.com/jackthorne) - creator and maintainer
