module Lsp::Crystal
  module AST
    class Index
      getter? indexed : Bool = false

      def initialize
        # Per-URI symbol tables
        @symbols = Hash(String, Array(IndexedSymbol)).new
        # name → cross-file references
        @references = Hash(String, Array(SymbolReference)).new
        # FQN → definition locations (Array for re-opened classes)
        @definitions = Hash(String, Array({String, Range})).new
        @mutex = Mutex.new
      end

      # Index all .cr files in the workspace root
      def index_workspace(root : String) : Nil
        files = Dir.glob(File.join(root, "**", "*.cr"))
        files.reject! { |f| f.includes?("/lib/") || f.includes?("/.crystal/") }

        batch_size = 20
        files.each_slice(batch_size) do |batch|
          batch.each do |file_path|
            content = File.read(file_path) rescue next
            uri = URI.path_to_uri(file_path)
            index_file_internal(uri, content)
          end
          Fiber.yield
        end

        @mutex.synchronize { @indexed = true }
        Log.info { "AST index: #{@symbols.size} files, #{total_symbols} symbols, #{total_references} references" }
      end

      # Index or re-index a single file
      def index_file(uri : String, content : String) : Nil
        remove_file_internal(uri)
        index_file_internal(uri, content)
      end

      # Remove a file from the index
      def remove_file(uri : String) : Nil
        remove_file_internal(uri)
      end

      # Find all definitions matching a name (simple name, not FQN)
      def find_definitions(name : String) : Array({String, Range})
        results = [] of {String, Range}
        @mutex.synchronize do
          @symbols.each do |uri, symbols|
            symbols.each do |sym|
              if sym.name == name
                kind = Providers::DocumentSymbol::SymbolKind.from_value?(sym.kind)
                is_def = kind.try { |k|
                  k.method? || k.function? || k.class? || k.module? ||
                  k.struct? || k.enum? || k.constant? || k.type_parameter? ||
                  k.interface? || k.property?
                }
                results << {uri, sym.selection_range} if is_def
              end
            end
          end
        end
        results
      end

      # Find all references to a name across all indexed files
      def find_references(name : String) : Array(SymbolReference)
        results = [] of SymbolReference
        @mutex.synchronize do
          if refs = @references[name]?
            results.concat(refs)
          end
        end
        results
      end

      # Search symbols by query (fuzzy, case-insensitive), returns {uri, symbol} pairs
      def search_symbols(query : String, max_results : Int32 = 200) : Array({String, IndexedSymbol})
        results = [] of {String, IndexedSymbol}
        query_lower = query.downcase

        @mutex.synchronize do
          @symbols.each do |uri, symbols|
            break if results.size >= max_results
            symbols.each do |sym|
              break if results.size >= max_results
              if query_lower.empty? || sym.name.downcase.includes?(query_lower)
                results << {uri, sym}
              end
            end
          end
        end

        results
      end

      # Find a type by fully qualified name
      def find_type(fqn : String) : {String, IndexedSymbol}?
        @mutex.synchronize do
          @symbols.each do |uri, symbols|
            symbols.each do |sym|
              return {uri, sym} if sym.fqn == fqn
            end
          end
        end
        nil
      end

      # Find definitions by FQN — supports re-opened classes (multiple locations)
      def find_definitions_by_fqn(fqn : String) : Array({String, Range})
        results = [] of {String, Range}
        @mutex.synchronize do
          if defs = @definitions[fqn]?
            results.concat(defs)
          end
        end
        results
      end

      # Get symbols for a specific URI
      def symbols_for(uri : String) : Array(IndexedSymbol)
        @mutex.synchronize do
          @symbols[uri]? || [] of IndexedSymbol
        end
      end

      def file_count : Int32
        @mutex.synchronize { @symbols.size }
      end

      # Index symbols from macro-expanded source code.
      # Parses each expanded source string and merges synthetic symbols into the file's symbol table.
      def index_macro_expansions(uri : String, expanded_sources : Array(String), line : Int32) : Nil
        expanded_sources.each do |source|
          result = AST.parse(source, "expanded")
          next unless result.success? && (node = result.node)

          visitor = IndexVisitor.new(uri)
          node.accept(visitor)

          @mutex.synchronize do
            existing = @symbols[uri]? || [] of IndexedSymbol
            visitor.symbols.each do |sym|
              # Adjust symbol ranges to point to the macro call line
              adjusted_range = Range.new(
                start: Position.new(line: line, character: 0),
                end_pos: Position.new(line: line, character: 0)
              )
              adjusted = IndexedSymbol.new(
                name: sym.name,
                fqn: sym.fqn,
                kind: sym.kind,
                range: adjusted_range,
                selection_range: adjusted_range,
                container_fqn: sym.container_fqn,
                superclass: sym.superclass,
                includes: sym.includes,
                params: sym.params
              )
              # Avoid duplicates
              unless existing.any? { |e| e.name == adjusted.name && e.fqn == adjusted.fqn }
                existing << adjusted
                (@definitions[adjusted.fqn] ||= [] of {String, Range}) << {uri, adjusted_range}
              end
            end
            @symbols[uri] = existing
          end
        rescue
          # Parse failure on expanded source — skip
        end
      end

      private def index_file_internal(uri : String, content : String) : Nil
        result = AST.parse(content, URI.uri_to_path(uri))
        return unless result.success? && (node = result.node)

        visitor = IndexVisitor.new(uri)
        node.accept(visitor)

        @mutex.synchronize do
          @symbols[uri] = visitor.symbols

          # Add references to the global reference index
          visitor.references.each do |ref|
            (@references[ref.name] ||= [] of SymbolReference) << ref
          end

          # Add definitions to the FQN → location index
          visitor.symbols.each do |sym|
            (@definitions[sym.fqn] ||= [] of {String, Range}) << {uri, sym.selection_range}
          end
        end
      rescue
        # Parse failure — skip file, existing regex fallback handles it
      end

      private def remove_file_internal(uri : String) : Nil
        @mutex.synchronize do
          @symbols.delete(uri)

          # Remove references from this URI
          @references.each_value do |refs|
            refs.reject! { |r| r.uri == uri }
          end
          @references.reject! { |_, refs| refs.empty? }

          # Remove definitions from this URI
          @definitions.each_value do |defs|
            defs.reject! { |d| d[0] == uri }
          end
          @definitions.reject! { |_, defs| defs.empty? }
        end
      end

      private def total_symbols : Int32
        @symbols.sum { |_, s| s.size }
      end

      private def total_references : Int32
        @references.sum { |_, r| r.size }
      end
    end
  end
end
