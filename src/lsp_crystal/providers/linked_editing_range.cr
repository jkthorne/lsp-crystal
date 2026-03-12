module Lsp::Crystal::Providers
  module LinkedEditingRange
    struct LinkedEditingRanges
      include JSON::Serializable

      property ranges : Array(Range)

      @[JSON::Field(key: "wordPattern")]
      property word_pattern : String?

      def initialize(@ranges, @word_pattern = nil)
      end
    end

    BLOCK_REGEX = /^\s*(?:class|struct|module|enum|def|macro|if|unless|case|while|until|begin|do|for|lib|fun|annotation)\b/

    # Keywords that can appear postfix (no matching end)
    POSTFIX_KEYWORDS = Set{"if", "unless", "while", "until"}

    def self.run(document : Document, line : Int32, character : Int32) : LinkedEditingRanges?
      lines = document.content.lines
      return nil if line >= lines.size

      # Build block stack: map opener_line <-> end_line
      block_stack = [] of {keyword: String, line: Int32, col: Int32}
      pairs = [] of {opener_line: Int32, opener_col: Int32, opener_keyword: String, end_line: Int32, end_col: Int32}

      lines.each_with_index do |text, line_num|
        stripped = text.strip

        if match = stripped.match(BLOCK_REGEX)
          keyword = stripped.split(/\s+/).first.strip
          # Skip postfix keywords: line has content after the keyword block (single-line conditional)
          if POSTFIX_KEYWORDS.includes?(keyword)
            # Check if it's postfix: keyword appears after some expression on the same line
            before_keyword = text[0...text.index(keyword).not_nil!].strip rescue ""
            if !before_keyword.empty?
              next # postfix usage
            end
          end
          col = text.index(keyword) || 0
          block_stack << {keyword: keyword, line: line_num, col: col}
        elsif stripped =~ /^end\b/
          if opener = block_stack.pop?
            end_col = text.index("end") || 0
            pairs << {
              opener_line:    opener[:line],
              opener_col:     opener[:col],
              opener_keyword: opener[:keyword],
              end_line:       line_num,
              end_col:        end_col,
            }
          end
        end
      end

      current_text = lines[line]
      stripped = current_text.strip

      # Check if cursor is on a block opener
      pairs.each do |pair|
        if pair[:opener_line] == line
          keyword = pair[:opener_keyword]
          keyword_col = pair[:opener_col]
          # Check cursor is within the keyword
          if character >= keyword_col && character <= keyword_col + keyword.size
            opener_range = Range.new(
              start: Position.new(line: pair[:opener_line], character: keyword_col),
              end_pos: Position.new(line: pair[:opener_line], character: keyword_col + keyword.size)
            )
            end_range = Range.new(
              start: Position.new(line: pair[:end_line], character: pair[:end_col]),
              end_pos: Position.new(line: pair[:end_line], character: pair[:end_col] + 3)
            )
            return LinkedEditingRanges.new(ranges: [opener_range, end_range])
          end
        end

        if pair[:end_line] == line
          end_col = pair[:end_col]
          if character >= end_col && character <= end_col + 3
            keyword = pair[:opener_keyword]
            opener_range = Range.new(
              start: Position.new(line: pair[:opener_line], character: pair[:opener_col]),
              end_pos: Position.new(line: pair[:opener_line], character: pair[:opener_col] + keyword.size)
            )
            end_range = Range.new(
              start: Position.new(line: pair[:end_line], character: end_col),
              end_pos: Position.new(line: pair[:end_line], character: end_col + 3)
            )
            return LinkedEditingRanges.new(ranges: [opener_range, end_range])
          end
        end
      end

      nil
    end
  end
end
