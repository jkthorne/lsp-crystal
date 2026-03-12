module Lsp::Crystal::Handlers
  module WorkspaceFolders
    def self.did_change(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      params = message.params
      return nil unless params

      event = params["event"]?
      return nil unless event

      # Handle added folders
      if added = event["added"]?
        added.as_a.each do |folder|
          if uri = folder["uri"]?.try(&.as_s?)
            path = URI.uri_to_path(uri)
            server.add_workspace_folder(path)
            Log.info { "Added workspace folder: #{path}" }
          end
        end
      end

      # Handle removed folders
      if removed = event["removed"]?
        removed.as_a.each do |folder|
          if uri = folder["uri"]?.try(&.as_s?)
            path = URI.uri_to_path(uri)
            server.remove_workspace_folder(path)
            Log.info { "Removed workspace folder: #{path}" }
          end
        end
      end

      nil
    end
  end
end
