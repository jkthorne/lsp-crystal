module Lsp::Crystal::Providers
  module Definition
    def self.run(document : Document, line : Int32, character : Int32, ast_index : AST::Index? = nil) : Array(Location)
      # Try AST index first for instant results
      if idx = ast_index
        if idx.indexed?
          word = extract_word_at(document, line, character)
          unless word.empty?
            defs = idx.find_definitions(word)
            return defs.map { |uri, range| Location.new(uri: uri, range: range) } unless defs.empty?
          end
        end
      end

      file_path = document.path
      # Convert 0-based LSP to 1-based Crystal
      result = CrystalTool.implementations(file_path, line + 1, character + 1)
      return [] of Location unless result.success

      begin
        json = JSON.parse(result.stdout)
      rescue
        return [] of Location
      end

      return [] of Location unless json["status"]?.try(&.as_s) == "ok"

      implementations = json["implementations"]?.try(&.as_a) || return [] of Location
      implementations.compact_map do |impl|
        filename = impl["filename"]?.try(&.as_s) || next
        impl_line = impl["line"]?.try(&.as_i) || next
        impl_col = impl["column"]?.try(&.as_i) || next
        impl_size = impl["size"]?.try(&.as_i) || 0

        Location.new(
          uri: URI.path_to_uri(filename),
          range: Range.new(
            start: Position.new(line: impl_line - 1, character: impl_col - 1),
            end_pos: Position.new(line: impl_line - 1, character: impl_col - 1 + impl_size)
          )
        )
      end
    end

    private def self.extract_word_at(document : Document, line : Int32, character : Int32) : String
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
