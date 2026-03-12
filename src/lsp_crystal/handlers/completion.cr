module Lsp::Crystal::Handlers
  module Completion
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s
      line = params["position"]["line"].as_i
      character = params["position"]["character"].as_i

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success(id, Providers::Completion::CompletionList.new(
          is_incomplete: false, items: [] of Providers::Completion::CompletionItem
        ))
      end

      result = Providers::Completion.run(doc, line, character, server.workspace_root, server.workspace_index, server.ast_cache)
      JSONRPC::Response.success(id, result)
    end
  end
end
