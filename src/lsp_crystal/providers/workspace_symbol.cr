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

    def self.run(workspace_root : String, query : String) : Array(WorkspaceSymbolInfo)
      results = [] of WorkspaceSymbolInfo
      query_lower = query.downcase

      Dir.glob(File.join(workspace_root, "**", "*.cr")) do |file_path|
        break if results.size >= MAX_RESULTS

        # Skip lib/ and .crystal/ directories
        next if file_path.includes?("/lib/") || file_path.includes?("/.crystal/")

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
