module Lsp::Crystal::Handlers
  module Formatting
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.error(id, JSONRPC::ErrorCode::InvalidParams, "Document not found: #{uri}")
      end

      edits = Providers::Formatting.run(doc)
      JSONRPC::Response.success(id, edits || [] of TextEdit)
    end
  end
end
