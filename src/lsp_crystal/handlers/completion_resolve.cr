module Lsp::Crystal::Handlers
  module CompletionResolve
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!

      # Reconstruct the CompletionItem from params
      label = params["label"].as_s
      kind = params["kind"]?.try(&.as_i?)
      detail = params["detail"]?.try(&.as_s?)
      insert_text = params["insertText"]?.try(&.as_s?)
      insert_text_format = params["insertTextFormat"]?.try(&.as_i?)
      sort_text = params["sortText"]?.try(&.as_s?)
      data = params["data"]?

      # If no data, return item unchanged (keywords, snippets)
      unless data
        return JSONRPC::Response.success(id, params)
      end

      name = data["name"]?.try(&.as_s)
      unless name
        return JSONRPC::Response.success(id, params)
      end

      # Try to find documentation via AST index
      documentation = resolve_documentation(server, name)

      # Build response with documentation added
      item = Providers::Completion::CompletionItem.new(
        label: label,
        kind: kind,
        detail: detail,
        insert_text: insert_text,
        insert_text_format: insert_text_format,
        sort_text: sort_text,
        documentation: documentation,
        data: data
      )

      JSONRPC::Response.success(id, item)
    end

    private def self.resolve_documentation(server : Lsp::Crystal::Server, name : String) : MarkupContent?
      # Strip trailing = from setter names for lookup
      lookup_name = name.rstrip("=")

      defs = server.ast_index.find_definitions(lookup_name)
      return nil if defs.empty?

      # Try each definition location for comments
      defs.each do |uri, range|
        path = URI.uri_to_path(uri)
        if doc_text = Providers::Hover.extract_comments_above(path, range.start.line)
          return MarkupContent.new(kind: "markdown", value: doc_text)
        end
      end

      nil
    end
  end
end
