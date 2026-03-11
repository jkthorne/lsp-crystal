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
  end
end
