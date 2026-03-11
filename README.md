# lsp-crystal

A Language Server Protocol (LSP) implementation for Crystal, written in Crystal with zero external dependencies.

## Features

### Navigation
- **Go to Definition** — Jump to symbol definitions via `crystal tool implementations`
- **Go to Implementation** — Find all implementations of abstract types
- **Find References** — Search for symbol occurrences across the workspace
- **Document Symbols** — Hierarchical outline of classes, methods, macros, properties, constants, and more
- **Workspace Symbols** — Search symbols across all `.cr` files in the project

### Editing
- **Completion** — Keywords, snippets, and context-aware suggestions (trigger: `.`, `:`, `@`)
- **Signature Help** — Method signature display with active parameter tracking (trigger: `(`, `,`)
- **Hover** — Type information via `crystal tool context`
- **Rename** — Workspace-wide symbol renaming with prepare support
- **Code Actions** — Quick fix for unused variables, organize/sort requires
- **Formatting** — Code formatting via `crystal tool format`

### Code Intelligence
- **Diagnostics** — Real-time error and warning reporting via `crystal build --no-codegen` with 500ms debounce
- **Document Highlight** — Highlight all occurrences of a symbol with read/write classification
- **Folding Ranges** — Fold blocks, consecutive requires, and comment sections
- **Selection Range** — Smart expand/shrink selection from word to block to document

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
CrystalTool          DocumentStore
(spawns crystal)      (in-memory docs)
```

Key design decisions:
- Zero external dependencies — Crystal stdlib only
- All LSP types use `JSON::Serializable` with camelCase field mapping
- Main fiber reads stdin synchronously; diagnostics run in spawned fibers with 500ms debounce
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
