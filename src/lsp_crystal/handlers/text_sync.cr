module Lsp::Crystal::Handlers
  module TextSync
    def self.did_open(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      params = message.params.not_nil!
      td = params["textDocument"]
      uri = td["uri"].as_s
      language_id = td["languageId"].as_s
      version = td["version"].as_i
      text = td["text"].as_s

      server.document_store.open(uri, language_id, version, text)
      Log.debug { "Opened: #{uri}" }

      server.schedule_diagnostics(uri)
      nil
    end

    def self.did_change(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      params = message.params.not_nil!
      td = params["textDocument"]
      uri = td["uri"].as_s
      version = td["version"].as_i
      changes = params["contentChanges"].as_a

      server.document_store.update(uri, version, changes)
      Log.debug { "Changed: #{uri} (v#{version})" }

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
        end
      end

      server.schedule_diagnostics(uri)
      nil
    end

    def self.did_close(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s
      server.document_store.close(uri)
      Log.debug { "Closed: #{uri}" }

      # Clear diagnostics for closed file
      server.send_notification("textDocument/publishDiagnostics", {uri: uri, diagnostics: [] of Nil})
      nil
    end
  end
end
