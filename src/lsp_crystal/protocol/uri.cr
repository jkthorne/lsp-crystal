module Lsp::Crystal
  module URI
    def self.path_to_uri(path : String) : String
      "file://#{path}"
    end

    def self.uri_to_path(uri : String) : String
      if uri.starts_with?("file://")
        uri[7..]
      else
        uri
      end
    end

    # Check that a resolved path is within the workspace root
    def self.path_within_workspace?(path : String, workspace_root : String) : Bool
      resolved = File.realpath(path) rescue path
      root = File.realpath(workspace_root) rescue workspace_root
      resolved.starts_with?(root)
    end
  end
end
