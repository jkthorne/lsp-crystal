# Editor Setup

## VS Code

Install the [vscode-crystal-lang](https://marketplace.visualstudio.com/items?itemName=crystal-lang-tools.crystal-lang) extension or use any generic LSP client extension.

### Using generic LSP (e.g. [LSP](https://marketplace.visualstudio.com/items?itemName=APerez.generic-lsp-client))

Add to your `settings.json`:

```json
{
  "genericLSP.serverCommand": "/path/to/bin/lsp-crystal",
  "genericLSP.languageId": "crystal"
}
```

### Configuration

Optional settings can be provided via `workspace/didChangeConfiguration`:

```json
{
  "crystalLsp": {
    "crystalPath": "crystal",
    "diagnosticsDelay": 500,
    "formatOnSave": false,
    "inlayHints": true,
    "codeLens": true,
    "semanticTokens": true
  }
}
```

---

## Neovim

### Using `vim.lsp.start` (Neovim 0.8+)

Add to your `init.lua` or a Crystal-specific ftplugin (`~/.config/nvim/ftplugin/crystal.lua`):

```lua
vim.lsp.start({
  name = "crystal-lsp",
  cmd = { "/path/to/bin/lsp-crystal" },
  root_dir = vim.fs.dirname(vim.fs.find("shard.yml", { upward = true })[1]),
})
```

### Using nvim-lspconfig

If you prefer [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig), add a custom server config:

```lua
local lspconfig = require("lspconfig")
local configs = require("lspconfig.configs")

if not configs.crystal_lsp then
  configs.crystal_lsp = {
    default_config = {
      cmd = { "/path/to/bin/lsp-crystal" },
      filetypes = { "crystal" },
      root_dir = lspconfig.util.root_pattern("shard.yml"),
      settings = {},
    },
  }
end

lspconfig.crystal_lsp.setup({})
```

---

## Helix

Add to `~/.config/helix/languages.toml`:

```toml
[[language]]
name = "crystal"
language-servers = ["crystal-lsp"]

[language-server.crystal-lsp]
command = "/path/to/bin/lsp-crystal"
```

Helix has built-in Crystal syntax highlighting. The LSP will provide additional features like go-to-definition, hover, completion, and diagnostics.

---

## Zed

Add to your Zed settings (`~/.config/zed/settings.json`):

```json
{
  "lsp": {
    "crystal-lsp": {
      "binary": {
        "path": "/path/to/bin/lsp-crystal"
      }
    }
  },
  "languages": {
    "Crystal": {
      "language_servers": ["crystal-lsp"]
    }
  }
}
```

---

## Sublime Text

Install the [LSP](https://packagecontrol.io/packages/LSP) package, then add to `LSP.sublime-settings`:

```json
{
  "clients": {
    "crystal-lsp": {
      "enabled": true,
      "command": ["/path/to/bin/lsp-crystal"],
      "selector": "source.crystal",
      "initializationOptions": {}
    }
  }
}
```

---

## Emacs (lsp-mode)

Add to your Emacs config:

```elisp
(with-eval-after-load 'lsp-mode
  (add-to-list 'lsp-language-id-configuration '(crystal-mode . "crystal"))
  (lsp-register-client
    (make-lsp-client
      :new-connection (lsp-stdio-connection '("/path/to/bin/lsp-crystal"))
      :activation-fn (lsp-activate-on "crystal")
      :server-id 'crystal-lsp)))
```

---

## Emacs (Eglot)

```elisp
(add-to-list 'eglot-server-programs
             '(crystal-mode . ("/path/to/bin/lsp-crystal")))
```

---

## Troubleshooting

### Viewing logs

The server logs to stderr in JSON format. To capture logs:

```sh
/path/to/bin/lsp-crystal 2>/tmp/crystal-lsp.log
```

Then tail the log:

```sh
tail -f /tmp/crystal-lsp.log | python3 -m json.tool
```

### Common issues

**Server not starting:** Ensure `crystal` is in your PATH. The server needs the Crystal compiler for diagnostics, formatting, and type information.

**Slow diagnostics:** The server runs `crystal build --no-codegen` for diagnostics. This can be slow for large projects. Increase `diagnosticsDelay` in settings.

**No completions after `.`:** Context-aware completion requires `crystal tool context`, which needs a valid Crystal project (shard.yml with targets).
