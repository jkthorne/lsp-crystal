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

      # Invalidate AST cache and tool result cache
      server.ast_cache.invalidate(uri)
      server.invalidate_tool_cache(uri)

      # Cancel any pending idle precompile
      server.cancel_idle_precompile

      # Update workspace index and AST index with latest content
      if doc
        server.workspace_index.invalidate_content(doc.path, doc.content)
        spawn { server.ast_index.index_file(uri, doc.content) }

        # Tier 1: Instant syntax diagnostics (ms) — published with diffing
        syntax_diags = Providers::Diagnostics.check_syntax(doc.content, doc.path)
        server.publish_diagnostics_if_changed(uri, syntax_diags)
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
      path = URI.uri_to_path(uri)
      if text = params["text"]?.try(&.as_s?)
        if doc = server.document_store.get(uri)
          doc.content = text
          server.workspace_index.invalidate_content(doc.path, text)
        end
        server.require_graph.update_file(path, text)
        spawn { server.ast_index.index_file(uri, text) }
      else
        # Re-read from disk on save
        server.workspace_index.invalidate(path)
        server.require_graph.update_file(path)
        content = File.read(path) rescue nil
        spawn { server.ast_index.index_file(uri, content) } if content
      end

      server.schedule_diagnostics(uri)
      nil
    end

    def self.did_close(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s
      server.document_store.close(uri)
      server.ast_cache.invalidate(uri)
      server.semantic_token_cache.invalidate(uri)
      server.invalidate_tool_cache(uri)
      Log.debug { "Closed: #{uri}" }

      # Re-index from disk when document is closed
      path = URI.uri_to_path(uri)
      server.workspace_index.invalidate(path)
      content = File.read(path) rescue nil
      if content
        spawn { server.ast_index.index_file(uri, content) }
      else
        server.ast_index.remove_file(uri)
      end

      # Clear diagnostics for closed file
      server.clear_published_diagnostics(uri)
      server.send_notification("textDocument/publishDiagnostics", {uri: uri, diagnostics: [] of Nil})
      nil
    end
  end
end
