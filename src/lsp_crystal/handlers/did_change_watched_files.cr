module Lsp::Crystal::Handlers
  module DidChangeWatchedFiles
    FILE_EVENT_CREATED = 1
    FILE_EVENT_CHANGED = 2
    FILE_EVENT_DELETED = 3

    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      return nil unless params = message.params
      return nil unless changes = params["changes"]?.try(&.as_a?)

      changes.each do |change|
        uri = change["uri"]?.try(&.as_s?) || next
        type = change["type"]?.try(&.as_i?) || next
        path = URI.uri_to_path(uri)

        # Skip files that are open in the editor — the editor is source of truth
        next if server.document_store.get(uri)

        case type
        when FILE_EVENT_CREATED, FILE_EVENT_CHANGED
          server.workspace_index.invalidate(path)
          server.invalidate_diagnostics_cache(uri)
        when FILE_EVENT_DELETED
          server.workspace_index.invalidate(path)
          server.invalidate_diagnostics_cache(uri)
          # Clear published diagnostics for deleted files
          server.send_notification("textDocument/publishDiagnostics", {
            uri:         uri,
            diagnostics: [] of Nil,
          })
        end
      end

      # Re-schedule diagnostics for all open documents since Crystal
      # does whole-program compilation — any file change can affect any open file
      server.document_store.each_uri do |open_uri|
        server.invalidate_diagnostics_cache(open_uri)
        server.schedule_diagnostics(open_uri)
      end

      nil
    end
  end
end
