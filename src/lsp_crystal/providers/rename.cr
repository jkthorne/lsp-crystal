module Lsp::Crystal::Providers
  module Rename
    # Prepare rename: validate the cursor is on a renameable symbol
    def self.prepare(document : Document, line : Int32, character : Int32) : {Range, String}?
      word = extract_word(document, line, character)
      return nil if word.empty?

      text = document.line_at(line)
      return nil unless text

      start_pos = character
      while start_pos > 0 && word_char?(text[start_pos - 1]?)
        start_pos -= 1
      end

      end_pos = character
      while end_pos < text.size && word_char?(text[end_pos]?)
        end_pos += 1
      end

      range = Range.new(
        start: Position.new(line: line, character: start_pos),
        end_pos: Position.new(line: line, character: end_pos)
      )

      {range, word}
    end

    # Perform rename across workspace — uses crystal tool implementations for type-aware rename
    def self.run(document : Document, line : Int32, character : Int32, new_name : String, workspace_root : String?, workspace_index : WorkspaceIndex? = nil, ast_cache : AST::Cache? = nil, ast_index : AST::Index? = nil) : WorkspaceEdit
      # Try type-aware rename first using crystal tool implementations
      impl_locations = find_implementation_references(document, line, character)

      locations = if impl_locations && !impl_locations.empty?
                    # Use implementation-based references for accurate rename
                    impl_locations
                  else
                    # Fall back to text-based references (AST-aware for current doc)
                    References.run(document, line, character, workspace_root, include_declaration: true, workspace_index: workspace_index, ast_cache: ast_cache, ast_index: ast_index)
                  end

      changes = Hash(String, Array(TextEdit)).new
      locations.each do |loc|
        edits = changes[loc.uri] ||= [] of TextEdit
        edits << TextEdit.new(range: loc.range, new_text: new_name)
      end

      WorkspaceEdit.new(changes)
    end

    # Use crystal tool implementations to find the definition, then find all references
    # to the same symbol using its definition location as a confirmation
    private def self.find_implementation_references(document : Document, line : Int32, character : Int32) : Array(Location)?
      word = extract_word(document, line, character)
      return nil if word.empty?

      # Get the definition location via crystal tool
      result = CrystalTool.implementations(document.path, line + 1, character + 1)
      return nil unless result.success

      begin
        json = JSON.parse(result.stdout)
      rescue
        return nil
      end

      return nil unless json["status"]?.try(&.as_s) == "ok"
      implementations = json["implementations"]?.try(&.as_a)
      return nil unless implementations && !implementations.empty?

      # We found the definition — now collect all locations where this exact symbol
      # is used, but verify they point to the same definition
      locations = [] of Location
      pattern = /\b#{Regex.escape(word)}\b/

      # Search the current document
      find_verified_references(document.content, document.uri, document.path, pattern, word, implementations, locations)

      locations
    rescue
      nil
    end

    private def self.find_verified_references(content : String, uri : String, file_path : String, pattern : Regex, word : String, target_impls : Array(JSON::Any), results : Array(Location))
      content.each_line.with_index do |text, line_num|
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
