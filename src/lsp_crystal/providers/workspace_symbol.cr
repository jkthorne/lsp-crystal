module Lsp::Crystal::Providers
  module WorkspaceSymbol
    MAX_RESULTS = 200

    struct WorkspaceSymbolInfo
      include JSON::Serializable

      property name : String
      property kind : Int32
      property location : Location

      def initialize(@name, @kind, @location)
      end
    end

    # Use the AST index for rich symbol search with hierarchy info
    def self.run_ast_indexed(ast_index : AST::Index, query : String) : Array(WorkspaceSymbolInfo)
      results = [] of WorkspaceSymbolInfo
      ast_index.search_symbols(query, MAX_RESULTS).each do |uri, sym|
        display_name = sym.name
        results << WorkspaceSymbolInfo.new(
          name: display_name,
          kind: sym.kind,
          location: Location.new(uri: uri, range: sym.selection_range)
        )
      end
      results
    end

    # Use the workspace index for fast symbol search
    def self.run_indexed(index : WorkspaceIndex, query : String) : Array(WorkspaceSymbolInfo)
      index.search_symbols(query, MAX_RESULTS)
    end

    # Fallback: scan files directly (used when index not ready)
    def self.run(workspace_root : String, query : String) : Array(WorkspaceSymbolInfo)
      results = [] of WorkspaceSymbolInfo
      query_lower = query.downcase

      Dir.glob(File.join(workspace_root, "**", "*.cr")) do |file_path|
        break if results.size >= MAX_RESULTS

        # Skip lib/ and .crystal/ directories
        next if file_path.includes?("/lib/") || file_path.includes?("/.crystal/")
        next if File.symlink?(file_path) && !URI.path_within_workspace?(file_path, workspace_root)

        content = begin
          File.read(file_path)
        rescue
          next
        end

        uri = URI.path_to_uri(file_path)

        content.each_line.with_index do |line, line_num|
          break if results.size >= MAX_RESULTS

          if info = DocumentSymbol.match_symbol(line, line_num)
            if query_lower.empty? || info.name.downcase.includes?(query_lower)
              results << WorkspaceSymbolInfo.new(
                name: info.name,
                kind: info.kind,
                location: Location.new(uri: uri, range: info.range)
              )
            end
          end
        end
      end

      results
    end
  end
end
