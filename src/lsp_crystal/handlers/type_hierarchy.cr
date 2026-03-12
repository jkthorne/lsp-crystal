module Lsp::Crystal::Handlers
  module TypeHierarchy
    def self.prepare(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s
      line = params["position"]["line"].as_i
      character = params["position"]["character"].as_i

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success(id, [] of Providers::TypeHierarchy::TypeHierarchyItem)
      end

      items = Providers::TypeHierarchy.prepare(doc, line, character)
      JSONRPC::Response.success(id, items)
    end

    def self.supertypes(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      item_json = params["item"]
      item = Providers::TypeHierarchy::TypeHierarchyItem.from_json(item_json.to_json)

      results = Providers::TypeHierarchy.supertypes(item, server.workspace_index)
      JSONRPC::Response.success(id, results)
    end

    def self.subtypes(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      item_json = params["item"]
      item = Providers::TypeHierarchy::TypeHierarchyItem.from_json(item_json.to_json)

      results = Providers::TypeHierarchy.subtypes(item, server.workspace_index)
      JSONRPC::Response.success(id, results)
    end
  end
end
