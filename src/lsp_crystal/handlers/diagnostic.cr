module Lsp::Crystal::Handlers
  module Diagnostic
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s
      previous_result_id = params["previousResultId"]?.try(&.as_s?)

      cached_diagnostics, result_id = server.get_cached_diagnostics(uri)

      # If client has the same result, return unchanged
      if previous_result_id && result_id && previous_result_id == result_id
        return JSONRPC::Response.success(id, {
          kind:     "unchanged",
          resultId: result_id,
        })
      end

      # If we have cached diagnostics, return them
      if diags = cached_diagnostics
        filtered = server.filter_diagnostics(diags)
        return JSONRPC::Response.success(id, {
          kind:     "full",
          resultId: result_id,
          items:    filtered,
        })
      end

      # No cached results — run fast syntax check and trigger background full build
      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success(id, {
          kind:  "full",
          items: [] of Providers::Diagnostics::Diagnostic,
        })
      end

      syntax_diags = Providers::Diagnostics.check_syntax(doc.content, doc.path)
      filtered = server.filter_diagnostics(syntax_diags)

      # Trigger background full build
      server.schedule_diagnostics(uri)

      JSONRPC::Response.success(id, {
        kind:  "full",
        items: filtered,
      })
    end
  end
end
