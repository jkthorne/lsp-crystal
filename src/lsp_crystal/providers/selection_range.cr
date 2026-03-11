module Lsp::Crystal::Providers
  module SelectionRange
    # SelectionRange is recursive: each range has an optional parent
    class SelectionRangeInfo
      include JSON::Serializable

      property range : Range
      property parent : SelectionRangeInfo?

      def initialize(@range, @parent = nil)
      end
    end

    # Block-opening keywords closed by `end`
    BLOCK_REGEX = /^\s*(?:class|struct|module|enum|def|macro|if|unless|case|while|until|begin|do|for|lib|fun|annotation)\b/

    def self.run(document : Document, positions : Array(Position)) : Array(SelectionRangeInfo)
      # Pre-compute block ranges for the document
      block_ranges = compute_block_ranges(document)

      positions.map do |pos|
        build_selection_range(document, pos, block_ranges)
      end
    end

    private def self.compute_block_ranges(document : Document) : Array(Range)
      ranges = [] of Range
      stack = [] of Int32

      document.content.each_line.with_index do |line, line_num|
        stripped = line.strip
        if BLOCK_REGEX.matches?(stripped)
          stack << line_num
        elsif stripped =~ /^end\b/
          if start_line = stack.pop?
            ranges << Range.new(
              start: Position.new(line: start_line, character: 0),
              end_pos: Position.new(line: line_num, character: stripped.size)
            )
          end
        end
      end

      ranges
    end

    private def self.build_selection_range(document : Document, pos : Position, block_ranges : Array(Range)) : SelectionRangeInfo
      line_text = document.line_at(pos.line) || ""

      # Level 1 (innermost): Current word
      word_range = find_word_range(line_text, pos)

      # Level 2: Current line (non-whitespace content)
      stripped = line_text.strip
      line_start = line_text.index(stripped) || 0
      line_range = Range.new(
        start: Position.new(line: pos.line, character: line_start),
        end_pos: Position.new(line: pos.line, character: line_start + stripped.size)
      )

      # Level 3+: Enclosing blocks (innermost first)
      enclosing = block_ranges
        .select { |r| contains_position?(r, pos) }
        .sort_by { |r| range_size(r) }

      # Build chain from outermost to innermost
      # Start with document range (outermost)
      doc_end = document.end_position
      result = SelectionRangeInfo.new(
        range: Range.new(
          start: Position.new(line: 0, character: 0),
          end_pos: doc_end
        )
      )

      # Add enclosing blocks from outermost to innermost
      enclosing.reverse_each do |block|
        result = SelectionRangeInfo.new(range: block, parent: result)
      end

      # Add line range
      result = SelectionRangeInfo.new(range: line_range, parent: result)

      # Add word range if different from line range
      if word_range
        result = SelectionRangeInfo.new(range: word_range, parent: result)
      end

      result
    end

    private def self.find_word_range(line : String, pos : Position) : Range?
      return nil if line.empty?
      char_pos = Math.min(pos.character, line.size - 1)
      return nil if char_pos < 0

      # Walk backward
      start_pos = char_pos
      while start_pos > 0 && word_char?(line[start_pos - 1]?)
        start_pos -= 1
      end

      # Walk forward
      end_pos = char_pos
      while end_pos < line.size && word_char?(line[end_pos]?)
        end_pos += 1
      end

      return nil if start_pos == end_pos

      Range.new(
        start: Position.new(line: pos.line, character: start_pos),
        end_pos: Position.new(line: pos.line, character: end_pos)
      )
    end

    private def self.word_char?(char : Char?) : Bool
      return false unless char
      char.alphanumeric? || char == '_' || char == '?' || char == '!'
    end

    private def self.contains_position?(range : Range, pos : Position) : Bool
      return false if pos.line < range.start.line
      return false if pos.line > range.end_pos.line
      if pos.line == range.start.line && pos.character < range.start.character
        return false
      end
      if pos.line == range.end_pos.line && pos.character > range.end_pos.character
        return false
      end
      true
    end

    private def self.range_size(range : Range) : Int32
      range.end_pos.line - range.start.line
    end
  end
end
