module Lsp::Crystal::Providers
  module DocumentHighlight
    # DocumentHighlightKind
    TEXT  = 1
    READ  = 2
    WRITE = 3

    struct HighlightInfo
      include JSON::Serializable

      property range : Range
      property kind : Int32

      def initialize(@range, @kind)
      end
    end

    # Find all occurrences of the word at the given position
    # Uses AST for accurate READ/WRITE classification when available
    def self.run(document : Document, line : Int32, character : Int32, ast_cache : AST::Cache? = nil) : Array(HighlightInfo)
      word = extract_word(document, line, character)
      return [] of HighlightInfo if word.empty?

      # Try AST path first
      if cache = ast_cache
        parse_result = cache.get(document)
        if parse_result && parse_result.success? && (node = parse_result.node)
          results = run_ast(node, word)
          return results unless results.empty?
        end
      end

      run_regex(document, word)
    end

    # AST-based highlight with accurate read/write classification
    private def self.run_ast(node : ::Crystal::ASTNode, word : String) : Array(HighlightInfo)
      visitor = AST::ReferenceVisitor.new(target_name: word)
      node.accept(visitor)

      visitor.references.map do |ref|
        kind = case ref.kind
               when .definition? then WRITE
               when .write?      then WRITE
               else                   READ
               end
        HighlightInfo.new(range: ref.range, kind: kind)
      end
    rescue
      [] of HighlightInfo
    end

    # Regex-based highlight (fallback)
    private def self.run_regex(document : Document, word : String) : Array(HighlightInfo)
      results = [] of HighlightInfo
      pattern = /\b#{Regex.escape(word)}\b/

      document.content.each_line.with_index do |text, line_num|
        offset = 0
        while match = pattern.match(text, offset)
          col = match.begin
          break unless col

          kind = classify_occurrence(text, col, word)
          results << HighlightInfo.new(
            range: Range.new(
              start: Position.new(line: line_num, character: col),
              end_pos: Position.new(line: line_num, character: col + word.size)
            ),
            kind: kind
          )
          offset = col + word.size
        end
      end

      results
    end

    private def self.extract_word(document : Document, line : Int32, character : Int32) : String
      text = document.line_at(line)
      return "" unless text

      # Walk backward to find word start
      start_pos = character
      while start_pos > 0 && word_char?(text[start_pos - 1]?)
        start_pos -= 1
      end

      # Walk forward to find word end
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

    # Classify whether this occurrence is a read or write
    private def self.classify_occurrence(line : String, col : Int32, word : String) : Int32
      stripped = line.strip
      # Assignment patterns: word = ..., word +=, word ||=, etc.
      after_word = line[col + word.size..]?.try(&.lstrip) || ""
      if after_word.starts_with?("=") && !after_word.starts_with?("==")
        return WRITE
      end
      # Variable declaration via property/getter/setter
      if stripped =~ /^\s*(?:property|getter|setter)[?!]?\s+#{Regex.escape(word)}\b/
        return WRITE
      end
      # Parameter in method def
      if stripped =~ /^\s*def\s/
        return WRITE
      end
      READ
    end
  end
end
