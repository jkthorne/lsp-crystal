# lsp-crystal

A Language Server Protocol (LSP) implementation for Crystal, written in Crystal with zero external dependencies.

## Features

- **Diagnostics** — Real-time error reporting via `crystal build --no-codegen` with 500ms debounce
- **Completion** — Keywords, context-aware suggestions (after `.`), and document symbol completion
- **Hover** — Type information via `crystal tool context`
- **Go to Definition** — Jump to implementations via `crystal tool implementations`
- **Document Symbols** — Outline of classes, methods, macros, properties, and constants
- **Formatting** — Code formatting via `crystal tool format`
- **Signature Help** — Method signature display on `(` and `,`

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

### Neovim (nvim-lspconfig)

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
stdin/stdout <-> Transport (JSON-RPC 2.0) <-> Dispatcher <-> Handlers <-> Providers <-> Crystal Tools
```

Key design decisions:
- All LSP types use `JSON::Serializable` with camelCase field mapping
- Main fiber reads stdin synchronously; diagnostics run in spawned fibers
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
