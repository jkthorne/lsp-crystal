module Lsp::Crystal::Handlers
  module InlayHints
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s
      range = Range.from_json(params["range"].to_json)

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success(id, [] of Providers::InlayHints::InlayHint)
      end

      hints = Providers::InlayHints.run(doc, range)
      JSONRPC::Response.success(id, hints)
    end
  end
end
