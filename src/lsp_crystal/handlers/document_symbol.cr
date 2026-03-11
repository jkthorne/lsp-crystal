module Lsp::Crystal::Handlers
  module DocumentSymbol
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success(id, [] of Providers::DocumentSymbol::SymbolInfo)
      end

      symbols = Providers::DocumentSymbol.run(doc)
      JSONRPC::Response.success(id, symbols)
    end
  end
end
