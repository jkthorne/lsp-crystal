module Lsp::Crystal::Handlers
  module CodeLensResolve
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!

      # Reconstruct CodeLensItem from params
      range_data = params["range"]
      range = Range.new(
        start: Position.new(
          line: range_data["start"]["line"].as_i,
          character: range_data["start"]["character"].as_i
        ),
        end_pos: Position.new(
          line: range_data["end"]["line"].as_i,
          character: range_data["end"]["character"].as_i
        )
      )

      data = params["data"]?
      item = Providers::CodeLens::CodeLensItem.new(range: range, data: data)

      # Find the document from the data URI
      uri = data.try { |d| d["uri"]?.try(&.as_s) }
      unless uri
        return JSONRPC::Response.success(id, item)
      end

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success(id, item)
      end

      resolved = Providers::CodeLens.resolve(item, doc, server.workspace_index)
      JSONRPC::Response.success(id, resolved)
    end
  end
end
