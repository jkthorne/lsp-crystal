module Lsp::Crystal::Handlers
  module Lifecycle
    def self.initialize(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      if params = message.params
        if root_uri = params["rootUri"]?.try(&.as_s?)
          server.detect_project(root_uri)
        elsif root_path = params["rootPath"]?.try(&.as_s?)
          server.detect_project(URI.path_to_uri(root_path))
        end
      end

      server.initialized = true

      result = {
        capabilities: {
          textDocumentSync: {
            openClose: true,
            change:    2, # Incremental
            save:      {includeText: true},
          },
          completionProvider: {
            triggerCharacters: [".", ":", "@"],
            resolveProvider:   false,
          },
          hoverProvider:              true,
          definitionProvider:         true,
          documentFormattingProvider: true,
          documentSymbolProvider:     true,
          signatureHelpProvider:      {
            triggerCharacters: ["(", ","],
          },
        },
        serverInfo: {
          name:    "crystal-lsp",
          version: VERSION,
        },
      }

      JSONRPC::Response.success(message.id.not_nil!, result)
    end

    def self.initialized(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      Log.info { "Client initialized" }
      nil
    end

    def self.shutdown(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      server.shutdown_requested = true
      Log.info { "Shutdown requested" }
      JSONRPC::Response.success_null(message.id.not_nil!)
    end

    def self.exit(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      code = server.shutdown_requested? ? 0 : 1
      Log.info { "Exiting with code #{code}" }
      ::exit(code)
    end
  end
end
