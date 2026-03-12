module Lsp::Crystal::Handlers
  module DocumentSymbol
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success(id, [] of Providers::DocumentSymbol::HierarchicalSymbolInfo)
      end

      # Use cached symbols if available and version matches
      if !doc.symbols_stale? && (cached = doc.cached_symbols)
        return JSONRPC::Response.success(id, cached)
      end

      symbols = Providers::DocumentSymbol.run(doc, server.ast_cache)
      flat = Providers::DocumentSymbol.run_flat(doc)
      doc.cache_symbols(symbols, flat)
      JSONRPC::Response.success(id, symbols)
    end
  end
end
