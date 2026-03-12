module Lsp::Crystal::Handlers
  module DidChangeWatchedFiles
    FILE_EVENT_CREATED = 1
    FILE_EVENT_CHANGED = 2
    FILE_EVENT_DELETED = 3

    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      return nil unless params = message.params
      return nil unless changes = params["changes"]?.try(&.as_a?)

      changed_paths = [] of String

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
          server.require_graph.update_file(path)
          changed_paths << path
        when FILE_EVENT_DELETED
          server.workspace_index.invalidate(path)
          server.invalidate_diagnostics_cache(uri)
          server.require_graph.remove_file(path)
          # Clear published diagnostics for deleted files
          server.publish_diagnostics_if_changed(uri, [] of Providers::Diagnostics::Diagnostic)
          changed_paths << path
        end
      end

      # Compute affected open files using the require graph
      affected_uris = Set(String).new

      if server.require_graph.built?
        changed_paths.each do |path|
          dependents = server.require_graph.transitive_dependents(path)
          dependents.each do |dep_path|
            dep_uri = URI.path_to_uri(dep_path)
            affected_uris << dep_uri if server.document_store.get(dep_uri)
          end
          # The changed file itself may be open
          changed_uri = URI.path_to_uri(path)
          affected_uris << changed_uri if server.document_store.get(changed_uri)
        end

        affected_uris.each do |open_uri|
          server.invalidate_diagnostics_cache(open_uri)
          server.schedule_diagnostics(open_uri)
        end
      else
        # Fallback: invalidate all open files (graph not yet built)
        server.document_store.each_uri do |open_uri|
          server.invalidate_diagnostics_cache(open_uri)
          server.schedule_diagnostics(open_uri)
        end
      end

      nil
    end
  end
end
