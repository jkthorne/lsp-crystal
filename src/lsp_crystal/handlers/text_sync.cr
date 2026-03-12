module Lsp::Crystal::Handlers
  module TextSync
    def self.did_open(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      params = message.params.not_nil!
      td = params["textDocument"]
      uri = td["uri"].as_s
      language_id = td["languageId"].as_s
      version = td["version"].as_i
      text = td["text"].as_s

      doc = server.document_store.open(uri, language_id, version, text)
      Log.debug { "Opened: #{uri}" }

      # Update workspace index with open document content
      server.workspace_index.invalidate_content(doc.path, text)
      server.schedule_diagnostics(uri)
      nil
    end

    def self.did_change(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      params = message.params.not_nil!
      td = params["textDocument"]
      uri = td["uri"].as_s
      version = td["version"].as_i
      changes = params["contentChanges"].as_a

      doc = server.document_store.update(uri, version, changes)
      Log.debug { "Changed: #{uri} (v#{version})" }

      # Invalidate AST cache
      server.ast_cache.invalidate(uri)

      # Update workspace index with latest content
      if doc
        server.workspace_index.invalidate_content(doc.path, doc.content)

        # Tier 1: Instant syntax diagnostics (ms) — published immediately
        syntax_diags = Providers::Diagnostics.check_syntax(doc.content, doc.path)
        server.send_notification("textDocument/publishDiagnostics", {
          uri:         uri,
          diagnostics: syntax_diags,
        })
      end

      # Tier 2: Full diagnostics via crystal build (debounced)
      server.schedule_diagnostics(uri)
      nil
    end

    def self.did_save(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s
      Log.debug { "Saved: #{uri}" }

      # Update content if included
      if text = params["text"]?.try(&.as_s?)
        if doc = server.document_store.get(uri)
          doc.content = text
          server.workspace_index.invalidate_content(doc.path, text)
        end
      else
        # Re-read from disk on save
        path = URI.uri_to_path(uri)
        server.workspace_index.invalidate(path)
      end

      server.schedule_diagnostics(uri)
      nil
    end

    def self.did_close(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s
      server.document_store.close(uri)
      server.ast_cache.invalidate(uri)
      Log.debug { "Closed: #{uri}" }

      # Re-index from disk when document is closed
      path = URI.uri_to_path(uri)
      server.workspace_index.invalidate(path)

      # Clear diagnostics for closed file
      server.send_notification("textDocument/publishDiagnostics", {uri: uri, diagnostics: [] of Nil})
      nil
    end
  end
end
