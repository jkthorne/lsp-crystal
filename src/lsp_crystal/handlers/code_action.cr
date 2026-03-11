module Lsp::Crystal::Handlers
  module CodeAction
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!
      uri = params["textDocument"]["uri"].as_s

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.success(id, [] of Lsp::Crystal::CodeAction)
      end

      range_json = params["range"]
      range = Range.new(
        start: Position.new(
          line: range_json["start"]["line"].as_i,
          character: range_json["start"]["character"].as_i
        ),
        end_pos: Position.new(
          line: range_json["end"]["line"].as_i,
          character: range_json["end"]["character"].as_i
        )
      )

      diagnostics = params["context"]?.try { |c| c["diagnostics"]?.try(&.as_a) }

      actions = Providers::CodeAction.run(doc, range, diagnostics)
      JSONRPC::Response.success(id, actions)
    end
  end
end
