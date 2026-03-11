module Lsp::Crystal::Providers
  module FoldingRange
    # FoldingRangeKind
    COMMENT = "comment"
    IMPORTS = "imports"
    REGION  = "region"

    struct FoldingRangeInfo
      include JSON::Serializable

      @[JSON::Field(key: "startLine")]
      property start_line : Int32

      @[JSON::Field(key: "startCharacter")]
      property start_character : Int32?

      @[JSON::Field(key: "endLine")]
      property end_line : Int32

      @[JSON::Field(key: "endCharacter")]
      property end_character : Int32?

      property kind : String?

      def initialize(@start_line, @end_line, @kind = nil, @start_character = nil, @end_character = nil)
      end
    end

    # Block-opening keywords that are closed by `end`
    BLOCK_REGEX = /^\s*(?:class|struct|module|enum|def|macro|if|unless|case|while|until|begin|do|for|lib|fun|annotation)\b/

    def self.run(document : Document) : Array(FoldingRangeInfo)
      ranges = [] of FoldingRangeInfo

      # Track block ranges (keyword...end)
      block_stack = [] of Int32 # stack of start lines

      # Track comment ranges
      comment_start : Int32? = nil
      comment_end : Int32? = nil

      # Track require ranges
      require_start : Int32? = nil
      require_end : Int32? = nil

      document.content.each_line.with_index do |line, line_num|
        stripped = line.strip

        # Track consecutive require lines
        if stripped.starts_with?("require ")
          require_start ||= line_num
          require_end = line_num
        else
          if require_start && require_end && require_end > require_start
            ranges << FoldingRangeInfo.new(
              start_line: require_start,
              end_line: require_end,
              kind: IMPORTS
            )
          end
          require_start = nil
          require_end = nil
        end

        # Track consecutive comment lines
        if stripped.starts_with?("#")
          comment_start ||= line_num
          comment_end = line_num
        else
          if comment_start && comment_end && comment_end > comment_start
            ranges << FoldingRangeInfo.new(
              start_line: comment_start,
              end_line: comment_end,
              kind: COMMENT
            )
          end
          comment_start = nil
          comment_end = nil
        end

        # Track block open/close
        if BLOCK_REGEX.matches?(stripped)
          block_stack << line_num
        elsif stripped =~ /^end\b/
          if start_line = block_stack.pop?
            # Only create fold if it spans multiple lines
            if line_num > start_line + 1
              ranges << FoldingRangeInfo.new(
                start_line: start_line,
                end_line: line_num,
                kind: REGION
              )
            end
          end
        end
      end

      # Flush trailing comments
      if comment_start && comment_end && comment_end.not_nil! > comment_start.not_nil!
        ranges << FoldingRangeInfo.new(
          start_line: comment_start.not_nil!,
          end_line: comment_end.not_nil!,
          kind: COMMENT
        )
      end

      # Flush trailing requires
      if require_start && require_end && require_end.not_nil! > require_start.not_nil!
        ranges << FoldingRangeInfo.new(
          start_line: require_start.not_nil!,
          end_line: require_end.not_nil!,
          kind: IMPORTS
        )
      end

      ranges
    end
  end
end
