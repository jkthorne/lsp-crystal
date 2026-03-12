module Lsp::Crystal::Providers
  module References
    MAX_RESULTS = 500

    # Find all references to the word at the given position across the workspace
    def self.run(document : Document, line : Int32, character : Int32, workspace_root : String?, include_declaration : Bool = true, workspace_index : WorkspaceIndex? = nil, ast_cache : AST::Cache? = nil, ast_index : AST::Index? = nil) : Array(Location)
      word = extract_word(document, line, character)
      return [] of Location if word.empty?

      results = [] of Location
      pattern = /\b#{Regex.escape(word)}\b/

      # Search current document: AST-aware for accuracy, regex fallback
      ast_found = false
      if cache = ast_cache
        parse_result = cache.get(document)
        if parse_result && parse_result.success? && (node = parse_result.node)
          ast_found = find_in_ast(node, word, document.uri, results)
        end
      end
      find_in_content(document.content, document.uri, pattern, results) unless ast_found

      # Cross-file references: prefer AST index, fall back to workspace index, then file scan
      cross_file_found = false
      if idx = ast_index
        if idx.indexed?
          refs = idx.find_references(word)
          cross_refs = refs.select { |r| r.uri != document.uri }
          unless cross_refs.empty?
            cross_refs.each do |ref|
              break if results.size >= MAX_RESULTS
              next if !include_declaration && ref.kind.definition?
              results << Location.new(uri: ref.uri, range: ref.range)
            end
            cross_file_found = true
          end
        end
      end

      unless cross_file_found
        if workspace_index && workspace_index.indexed?
          current_path = URI.uri_to_path(document.uri)
          indexed_refs = workspace_index.search_references(pattern, exclude_path: current_path, max_results: MAX_RESULTS - results.size)
          results.concat(indexed_refs)
        elsif root = workspace_root
          current_path = URI.uri_to_path(document.uri)
          Dir.glob(File.join(root, "**", "*.cr")) do |file_path|
            break if results.size >= MAX_RESULTS
            next if file_path.includes?("/lib/") || file_path.includes?("/.crystal/")
            next if file_path == current_path # Already searched
            next if File.symlink?(file_path) && !URI.path_within_workspace?(file_path, root)

            content = begin
              File.read(file_path)
            rescue
              next
            end

            uri = URI.path_to_uri(file_path)
            find_in_content(content, uri, pattern, results)
          end
        end
      end

      results
    end

    # AST-based in-document reference search — ignores strings and comments
    private def self.find_in_ast(node : ::Crystal::ASTNode, word : String, uri : String, results : Array(Location)) : Bool
      visitor = AST::ReferenceVisitor.new(target_name: word)
      node.accept(visitor)
      refs = visitor.references
      return false if refs.empty?
      refs.each do |ref|
        results << Location.new(uri: uri, range: ref.range)
      end
      true
    rescue
      false
    end

    private def self.find_in_content(content : String, uri : String, pattern : Regex, results : Array(Location)) : Nil
      content.each_line.with_index do |text, line_num|
        return if results.size >= MAX_RESULTS
        offset = 0
        while match = pattern.match(text, offset)
          col = match.begin
          break unless col
          results << Location.new(
            uri: uri,
            range: Range.new(
              start: Position.new(line: line_num, character: col),
              end_pos: Position.new(line: line_num, character: col + match[0].size)
            )
          )
          offset = col + match[0].size
        end
      end
    end

    private def self.extract_word(document : Document, line : Int32, character : Int32) : String
      text = document.line_at(line)
      return "" unless text

      start_pos = character
      while start_pos > 0 && word_char?(text[start_pos - 1]?)
        start_pos -= 1
      end

      end_pos = character
      while end_pos < text.size && word_char?(text[end_pos]?)
        end_pos += 1
      end

      return "" if start_pos == end_pos
      text[start_pos...end_pos]
    end

    private def self.word_char?(char : Char?) : Bool
      return false unless char
      char.alphanumeric? || char == '_' || char == '?' || char == '!'
    end
  end
end
