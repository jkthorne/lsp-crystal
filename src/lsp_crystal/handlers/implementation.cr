module Lsp::Crystal::Handlers
  module Implementation
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s
      line = params["position"]["line"].as_i
      character = params["position"]["character"].as_i

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success(id, [] of Location)
      end

      locations = Providers::Implementation.run(doc, line, character)
      JSONRPC::Response.success(id, locations)
    end
  end
end
