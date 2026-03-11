module Lsp::Crystal::Handlers
  module SelectionRange
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success(id, [] of Providers::SelectionRange::SelectionRangeInfo)
      end

      positions = params["positions"].as_a.map do |p|
        Position.new(line: p["line"].as_i, character: p["character"].as_i)
      end

      ranges = Providers::SelectionRange.run(doc, positions)
      JSONRPC::Response.success(id, ranges)
    end
  end
end
