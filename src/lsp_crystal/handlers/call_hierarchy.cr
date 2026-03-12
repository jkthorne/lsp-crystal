module Lsp::Crystal::Handlers
  module CallHierarchy
    def self.prepare(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s
      line = params["position"]["line"].as_i
      character = params["position"]["character"].as_i

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success(id, [] of Providers::CallHierarchy::CallHierarchyItem)
      end

      items = Providers::CallHierarchy.prepare(doc, line, character)
      JSONRPC::Response.success(id, items)
    end

    def self.incoming_calls(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      item_json = params["item"]
      item = Providers::CallHierarchy::CallHierarchyItem.from_json(item_json.to_json)

      calls = Providers::CallHierarchy.incoming_calls(item, server.workspace_index)
      JSONRPC::Response.success(id, calls)
    end

    def self.outgoing_calls(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      item_json = params["item"]
      item = Providers::CallHierarchy::CallHierarchyItem.from_json(item_json.to_json)

      doc = server.document_store.get(item.uri)
      calls = Providers::CallHierarchy.outgoing_calls(item, doc, server.workspace_index)
      JSONRPC::Response.success(id, calls)
    end
  end
end
