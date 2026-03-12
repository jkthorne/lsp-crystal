module Lsp::Crystal::Handlers
  module Formatting
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.error(id, JSONRPC::ErrorCode::InvalidParams, "Document not found: #{uri}")
      end

      edits = Providers::Formatting.run(doc)
      JSONRPC::Response.success(id, edits || [] of TextEdit)
    end

    def self.handle_range(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.error(id, JSONRPC::ErrorCode::InvalidParams, "Document not found: #{uri}")
      end

      range_data = params["range"]
      range = Range.new(
        start: Position.new(
          line: range_data["start"]["line"].as_i,
          character: range_data["start"]["character"].as_i
        ),
        end_pos: Position.new(
          line: range_data["end"]["line"].as_i,
          character: range_data["end"]["character"].as_i
        )
      )

      edits = Providers::Formatting.run_range(doc, range)
      JSONRPC::Response.success(id, edits || [] of TextEdit)
    end

    def self.handle_on_type(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.error(id, JSONRPC::ErrorCode::InvalidParams, "Document not found: #{uri}")
      end

      line = params["position"]["line"].as_i
      character = params["position"]["character"].as_i
      ch = params["ch"].as_s

      edits = Providers::Formatting.run_on_type(doc, line, character, ch)
      JSONRPC::Response.success(id, edits || [] of TextEdit)
    end
  end
end
