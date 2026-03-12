module Lsp::Crystal::Handlers
  module SemanticTokens
    def self.full(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success(id, {data: [] of Int32})
      end

      data = Providers::SemanticTokens.run(doc, server.ast_cache)
      JSONRPC::Response.success(id, {data: data})
    end
  end
end
