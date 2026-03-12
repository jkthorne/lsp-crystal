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
            resolveProvider:   true,
          },
          hoverProvider:              true,
          definitionProvider:         true,
          typeDefinitionProvider:     true,
          documentFormattingProvider: true,
          documentSymbolProvider:     true,
          signatureHelpProvider:      {
            triggerCharacters: ["(", ","],
          },
          workspaceSymbolProvider:    true,
          documentHighlightProvider: true,
          foldingRangeProvider:      true,
          selectionRangeProvider:    true,
          implementationProvider:    true,
          referencesProvider:        true,
          codeActionProvider:        true,
          renameProvider:            {prepareProvider: true},
          semanticTokensProvider:    {
            legend: {
              tokenTypes:     Providers::SemanticTokens::TOKEN_TYPES,
              tokenModifiers: Providers::SemanticTokens::TOKEN_MODIFIERS,
            },
            full: {delta: true},
          },
          callHierarchyProvider:    true,
          inlayHintProvider:        true,
          codeLensProvider:         {resolveProvider: false},
          linkedEditingRangeProvider: true,
          typeHierarchyProvider:     true,
          executeCommandProvider:    {commands: ["crystal-lsp/expandMacro"]},
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

      # Register file watcher for *.cr files via dynamic registration
      server.send_request("client/registerCapability", {
        registrations: [{
          id:              "file-watcher",
          method:          "workspace/didChangeWatchedFiles",
          registerOptions: {
            watchers: [{
              globPattern: "**/*.cr",
              kind:        7, # Create | Change | Delete
            }],
          },
        }],
      })

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
