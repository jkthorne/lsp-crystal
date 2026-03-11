module Lsp::Crystal::Handlers
  module FoldingRange
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success(id, [] of Providers::FoldingRange::FoldingRangeInfo)
      end

      ranges = Providers::FoldingRange.run(doc)
      JSONRPC::Response.success(id, ranges)
    end
  end
end
