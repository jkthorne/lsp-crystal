module Lsp::Crystal::Handlers
  module CodeLens
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success(id, [] of Providers::CodeLens::CodeLensItem)
      end

      lenses = Providers::CodeLens.run(doc, server.workspace_index)
      JSONRPC::Response.success(id, lenses)
    end
  end
end
