module Lsp::Crystal::Handlers
  module References
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s
      line = params["position"]["line"].as_i
      character = params["position"]["character"].as_i
      include_declaration = params["context"]?.try { |c| c["includeDeclaration"]?.try(&.as_bool) } || true

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success(id, [] of Location)
      end

      locations = Providers::References.run(doc, line, character, server.workspace_root, include_declaration, server.workspace_index)
      JSONRPC::Response.success(id, locations)
    end
  end
end
