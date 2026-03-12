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

    # Perform rename across workspace
    def self.run(document : Document, line : Int32, character : Int32, new_name : String, workspace_root : String?, workspace_index : WorkspaceIndex? = nil) : WorkspaceEdit
      locations = References.run(document, line, character, workspace_root, include_declaration: true, workspace_index: workspace_index)

      changes = Hash(String, Array(TextEdit)).new
      locations.each do |loc|
        edits = changes[loc.uri] ||= [] of TextEdit
        edits << TextEdit.new(range: loc.range, new_text: new_name)
      end

      WorkspaceEdit.new(changes)
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
