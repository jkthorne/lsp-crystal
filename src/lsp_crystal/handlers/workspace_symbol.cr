module Lsp::Crystal::Handlers
  module WorkspaceSymbol
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      query = params["query"]?.try(&.as_s) || ""

      root = server.workspace_root
      unless root
        return JSONRPC::Response.success(id, [] of Providers::WorkspaceSymbol::WorkspaceSymbolInfo)
      end

      symbols = if server.workspace_index.indexed?
                  Providers::WorkspaceSymbol.run_indexed(server.workspace_index, query)
                else
                  Providers::WorkspaceSymbol.run(root, query)
                end
      JSONRPC::Response.success(id, symbols)
    end
  end
end
