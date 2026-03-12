module Lsp::Crystal
  class WorkspaceIndex
    struct FileEntry
      property path : String
      property uri : String
      property content : String
      property symbols : Array(Providers::DocumentSymbol::SymbolInfo)

      def initialize(@path, @uri, @content, @symbols)
      end
    end

    getter workspace_root : String?
    getter? indexed : Bool = false
    @files : Hash(String, FileEntry)
    @mutex : Mutex

    def initialize
      @files = Hash(String, FileEntry).new
      @mutex = Mutex.new
    end

    # Full index of all .cr files in the workspace
    def index(workspace_root : String) : Nil
      @workspace_root = workspace_root
      entries = Hash(String, FileEntry).new

      Dir.glob(File.join(workspace_root, "**", "*.cr")) do |file_path|
        next if skip_path?(file_path, workspace_root)
        if entry = build_entry(file_path)
          entries[file_path] = entry
        end
      end

      @mutex.synchronize do
        @files = entries
        @indexed = true
      end
      Log.info { "Indexed #{entries.size} files in workspace" }
    end

    # Index an additional folder (for multi-root workspaces)
    def index_folder(folder : String) : Nil
      new_entries = Hash(String, FileEntry).new
      Dir.glob(File.join(folder, "**", "*.cr")) do |file_path|
        next if skip_path?(file_path, folder)
        if entry = build_entry(file_path)
          new_entries[file_path] = entry
        end
      end
      @mutex.synchronize do
        new_entries.each { |k, v| @files[k] = v }
      end
      Log.info { "Indexed #{new_entries.size} files from #{folder}" }
    end

    # Remove all files belonging to a folder
    def remove_folder(folder : String) : Nil
      @mutex.synchronize do
        @files.reject! { |path, _| path.starts_with?(folder) }
      end
    end

    # Invalidate a file from disk (re-read or remove)
    def invalidate(path : String) : Nil
      @mutex.synchronize do
        if File.exists?(path)
          if entry = build_entry(path)
            @files[path] = entry
          end
        else
          @files.delete(path)
        end
      end
    end

    # Invalidate with known content (from open document)
    def invalidate_content(path : String, content : String) : Nil
      uri = URI.path_to_uri(path)
      symbols = extract_symbols(content)
      @mutex.synchronize do
        @files[path] = FileEntry.new(path, uri, content, symbols)
      end
    end

    # Search symbols across all indexed files
    def search_symbols(query : String, max_results : Int32 = 200) : Array(Providers::WorkspaceSymbol::WorkspaceSymbolInfo)
      results = [] of Providers::WorkspaceSymbol::WorkspaceSymbolInfo
      query_lower = query.downcase

      @mutex.synchronize do
        @files.each_value do |entry|
          break if results.size >= max_results
          entry.symbols.each do |sym|
            break if results.size >= max_results
            if query_lower.empty? || sym.name.downcase.includes?(query_lower)
              results << Providers::WorkspaceSymbol::WorkspaceSymbolInfo.new(
                name: sym.name,
                kind: sym.kind,
                location: Location.new(uri: entry.uri, range: sym.range)
              )
            end
          end
        end
      end

      results
    end

    # Search for word references across all indexed files
    def search_references(pattern : Regex, exclude_path : String? = nil, max_results : Int32 = 500) : Array(Location)
      results = [] of Location

      @mutex.synchronize do
        @files.each_value do |entry|
          break if results.size >= max_results
          next if entry.path == exclude_path

          entry.content.each_line.with_index do |text, line_num|
            break if results.size >= max_results
            offset = 0
            while match = pattern.match(text, offset)
              col = match.begin
              break unless col
              results << Location.new(
                uri: entry.uri,
                range: Range.new(
                  start: Position.new(line: line_num, character: col),
                  end_pos: Position.new(line: line_num, character: col + match[0].size)
                )
              )
              offset = col + match[0].size
              break if results.size >= max_results
            end
          end
        end
      end

      results
    end

    # Search for methods defined on a specific type
    def search_type_methods(type_name : String, &block : String, String ->) : Nil
      type_pattern = /^\s*(?:class|struct|module)\s+#{Regex.escape(type_name)}\b/

      @mutex.synchronize do
        @files.each_value do |entry|
          in_type = false
          depth = 0

          entry.content.each_line do |line|
            stripped = line.strip
            if !in_type && stripped =~ type_pattern
              in_type = true
              depth = 1
              next
            end

            next unless in_type

            if stripped =~ /^\s*(?:class|struct|module|def|if|unless|case|begin|do|while|until|macro|enum|lib|fun|annotation)\b/
              depth += 1
            end
            if stripped =~ /^\s*end\b/
              depth -= 1
              if depth <= 0
                in_type = false
                next
              end
            end

            if depth == 2 && stripped =~ /^\s*def\s+(\w+[?!]?)/
              yield $1, "#{type_name}##{$1}"
            elsif depth == 1 && stripped =~ /^\s*(property|property\?|property!|getter|getter\?|getter!|setter)\s+(\w+)/
              macro_name = $1
              prop_name = $2
              # Yield getter (except for setter-only)
              yield prop_name, "#{type_name}##{prop_name}" unless macro_name == "setter"
              # Yield setter for property/property!/setter macros
              if macro_name.in?("property", "property!", "setter")
                yield "#{prop_name}=", "#{type_name}##{prop_name}="
              end
            end
          end
        end
      end
    end

    # Search for a type definition by name
    def search_type_definition(type_name : String, &block : String, Int32, Int32 ->) : Nil
      pattern = /^\s*(?:class|struct|module|enum|alias|annotation)\s+#{Regex.escape(type_name)}\b/

      @mutex.synchronize do
        @files.each_value do |entry|
          entry.content.each_line.with_index do |line_text, line_num|
            if pattern.match(line_text)
              col = line_text.index(type_name)
              next unless col
              yield entry.uri, line_num, col
            end
          end
        end
      end
    end

    def file_count : Int32
      @mutex.synchronize { @files.size }
    end

    private def skip_path?(file_path : String, workspace_root : String) : Bool
      return true if file_path.includes?("/lib/") || file_path.includes?("/.crystal/")
      return true if File.symlink?(file_path) && !URI.path_within_workspace?(file_path, workspace_root)
      false
    end

    private def build_entry(file_path : String) : FileEntry?
      content = File.read(file_path) rescue return nil
      uri = URI.path_to_uri(file_path)
      symbols = extract_symbols(content)
      FileEntry.new(file_path, uri, content, symbols)
    end

    private def extract_symbols(content : String) : Array(Providers::DocumentSymbol::SymbolInfo)
      symbols = [] of Providers::DocumentSymbol::SymbolInfo
      content.each_line.with_index do |line, line_num|
        if info = Providers::DocumentSymbol.match_symbol(line, line_num)
          symbols << info
        end
      end
      symbols
    end
  end
end
