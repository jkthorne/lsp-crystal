module Lsp::Crystal::Handlers
  module LinkedEditingRange
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s
      line = params["position"]["line"].as_i
      character = params["position"]["character"].as_i

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success_null(id)
      end

      result = Providers::LinkedEditingRange.run(doc, line, character)
      if result
        JSONRPC::Response.success(id, result)
      else
        JSONRPC::Response.success_null(id)
      end
    end
  end
end
