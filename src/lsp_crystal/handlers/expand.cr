module Lsp::Crystal::Handlers
  module Expand
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!

      # executeCommand params: { command: "crystal-lsp/expandMacro", arguments: [{uri, line, character}] }
      arguments = params["arguments"]?.try(&.as_a)
      unless arguments && !arguments.empty?
        return JSONRPC::Response.error(id, JSONRPC::ErrorCode::InvalidParams, "Missing arguments")
      end

      arg = arguments.first
      uri = arg["uri"]?.try(&.as_s)
      line = arg["line"]?.try(&.as_i)
      character = arg["character"]?.try(&.as_i)

      unless uri && line && character
        return JSONRPC::Response.error(id, JSONRPC::ErrorCode::InvalidParams, "Missing uri, line, or character")
      end

      doc = server.document_store.get(uri)
      unless doc
        return JSONRPC::Response.error(id, JSONRPC::ErrorCode::InvalidParams, "Document not open: #{uri}")
      end

      # Convert 0-based LSP to 1-based Crystal
      crystal_line = line + 1
      crystal_col = character + 1
      timeout = server.configuration.macro_expand_timeout.seconds

      result = CrystalTool.expand_content(doc.content, doc.path, crystal_line, crystal_col, timeout)

      parsed = CrystalTool.parse_expand_result(result)
      if parsed && !parsed.expansions.empty?
        # Cache the result for future hover lookups
        content_hash = doc.content.hash.to_u64
        server.tool_result_cache.put("expand", doc.path, crystal_line, crystal_col, content_hash, result)

        # Index expanded symbols
        all_expanded = parsed.expansions.flat_map(&.expanded_sources)
        unless all_expanded.empty?
          spawn { server.ast_index.index_macro_expansions(uri, all_expanded, line) }
        end

        text = String.build do |str|
          parsed.expansions.each_with_index do |exp, i|
            str << "\n" if i > 0
            unless exp.original_source.empty?
              str << "// Original:\n#{exp.original_source}\n\n"
            end
            str << "// Expanded:\n"
            exp.expanded_sources.each do |src|
              str << src.strip << "\n"
            end
          end
        end

        JSONRPC::Response.success(id, {result: text})
      elsif result.success
        JSONRPC::Response.success(id, {result: "No macro expansion found at this position."})
      else
        JSONRPC::Response.success(id, {result: "Expansion failed: #{result.stderr}"})
      end
    end
  end
end
