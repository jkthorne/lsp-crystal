module Lsp::Crystal::Handlers
  module Rename
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s
      line = params["position"]["line"].as_i
      character = params["position"]["character"].as_i
      new_name = params["newName"].as_s

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success(id, nil)
      end

      edit = Providers::Rename.run(doc, line, character, new_name, server.workspace_root, server.workspace_index, server.ast_cache, server.ast_index)
      JSONRPC::Response.success(id, edit)
    end

    def self.prepare(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s
      line = params["position"]["line"].as_i
      character = params["position"]["character"].as_i

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success(id, nil)
      end

      result = Providers::Rename.prepare(doc, line, character)
      unless result
        return JSONRPC::Response.success(id, nil)
      end

      range, placeholder = result
      JSONRPC::Response.success(id, {range: range, placeholder: placeholder})
    end
  end
end
