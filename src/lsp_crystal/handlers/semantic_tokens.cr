module Lsp::Crystal::Handlers
  module SemanticTokens
    def self.full(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success(id, {data: [] of Int32})
      end

      data = Providers::SemanticTokens.run(doc, server.ast_cache)
      result_id = server.semantic_token_cache.store(uri, data, doc.version)
      JSONRPC::Response.success(id, {resultId: result_id, data: data})
    end

    def self.full_delta(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s
      previous_result_id = params["previousResultId"].as_s

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success(id, {data: [] of Int32})
      end

      new_data = Providers::SemanticTokens.run(doc, server.ast_cache)
      new_result_id = server.semantic_token_cache.store(uri, new_data, doc.version)

      # Try to compute delta from previous result
      previous = server.semantic_token_cache.get(uri, previous_result_id)
      if previous
        edits = Providers::SemanticTokens::TokenCache.compute_edits(previous.data, new_data)
        # Return delta if it's smaller than full data
        edit_size = edits.sum { |e| (e.data.try(&.size) || 0) + 2 }
        if edit_size < new_data.size
          return JSONRPC::Response.success(id, {resultId: new_result_id, edits: edits})
        end
      end

      # Fall back to full response
      JSONRPC::Response.success(id, {resultId: new_result_id, data: new_data})
    end
  end
end
