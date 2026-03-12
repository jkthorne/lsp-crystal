module Lsp::Crystal::Providers
  module SemanticTokens
    # LSP semantic token types — order matters (index = type ID)
    TOKEN_TYPES = [
      "namespace",    # 0
      "type",         # 1
      "class",        # 2
      "enum",         # 3
      "struct",       # 4
      "parameter",    # 5
      "variable",     # 6
      "property",     # 7
      "function",     # 8
      "macro",        # 9
      "keyword",      # 10
      "modifier",     # 11
      "comment",      # 12
      "string",       # 13
      "number",       # 14
      "operator",     # 15
      "regexp",       # 16
    ]

    TOKEN_MODIFIERS = [
      "declaration",  # 0
      "definition",   # 1
      "readonly",     # 2
      "static",       # 3
      "abstract",     # 4
    ]

    KEYWORDS = Set{
      "abstract", "alias", "annotation", "as", "as?", "asm",
      "begin", "break",
      "case", "class",
      "def", "do",
      "else", "elsif", "end", "ensure", "enum", "extend",
      "false", "for", "forall", "fun",
      "if", "in", "include", "instance_sizeof", "is_a?",
      "lib",
      "macro", "module",
      "next", "nil", "nil?",
      "of", "offsetof", "out",
      "pointerof", "private", "protected",
      "raise", "require", "rescue", "responds_to?", "return",
      "select", "self", "sizeof", "struct", "super",
      "then", "true", "type", "typeof",
      "uninitialized", "union", "unless", "until",
      "verbatim", "when", "while", "with",
      "yield",
    }

    MODIFIERS = Set{"abstract", "private", "protected"}

    # Returns encoded token data for the full document
    def self.run(document : Document) : Array(Int32)
      tokens = [] of {Int32, Int32, Int32, Int32, Int32} # line, col, len, type, modifiers

      document.content.each_line.with_index do |line, line_num|
        tokenize_line(line, line_num, tokens)
      end

      # Encode as delta format
      encode(tokens)
    end

    private def self.tokenize_line(line : String, line_num : Int32, tokens : Array({Int32, Int32, Int32, Int32, Int32})) : Nil
      i = 0
      len = line.size

      while i < len
        char = line[i]

        # Skip whitespace
        if char.ascii_whitespace?
          i += 1
          next
        end

        # Comment
        if char == '#'
          tokens << {line_num, i, len - i, 12, 0} # comment
          break
        end

        # String (double-quoted)
        if char == '"'
          str_end = find_string_end(line, i)
          tokens << {line_num, i, str_end - i, 13, 0} # string
          i = str_end
          next
        end

        # String (single-quoted char)
        if char == '\''
          str_end = find_char_end(line, i)
          tokens << {line_num, i, str_end - i, 13, 0} # string
          i = str_end
          next
        end

        # Symbol literal
        if char == ':' && i + 1 < len && (line[i + 1].letter? || line[i + 1] == '_')
          word_end = i + 1
          while word_end < len && (line[word_end].alphanumeric? || line[word_end] == '_')
            word_end += 1
          end
          tokens << {line_num, i, word_end - i, 13, 0} # string (symbol)
          i = word_end
          next
        end

        # Number
        if char.ascii_number? || (char == '-' && i + 1 < len && line[i + 1].ascii_number?)
          num_end = i + 1
          has_dot = false
          while num_end < len
            c = line[num_end]
            if c.ascii_number? || c == '_'
              num_end += 1
            elsif c == '.' && !has_dot && num_end + 1 < len && line[num_end + 1].ascii_number?
              has_dot = true
              num_end += 1
            elsif c == 'e' || c == 'E' || c == 'x' || c == 'X' || c == 'o' || c == 'O' || c == 'b' || c == 'B'
              num_end += 1
            elsif c == 'i' || c == 'u' || c == 'f'
              # Type suffixes like i32, u64, f64
              while num_end < len && (line[num_end].alphanumeric?)
                num_end += 1
              end
              break
            else
              break
            end
          end
          # Only emit if it started with a digit (avoid highlighting lone -)
          if char.ascii_number?
            tokens << {line_num, i, num_end - i, 14, 0} # number
          end
          i = num_end
          next
        end

        # Regex literal
        if char == '/' && i + 1 < len && line[i + 1] != ' ' && line[i + 1] != '='
          # Simple heuristic: only after operator, paren, comma, or start of line
          is_regex = i == 0 || line[i - 1].in?('=', '(', ',', '|', '&', '!', '~', ' ', '\t')
          if is_regex
            regex_end = i + 1
            while regex_end < len && line[regex_end] != '/'
              regex_end += 1 if line[regex_end] == '\\'
              regex_end += 1
            end
            regex_end += 1 if regex_end < len # include closing /
            # Skip modifier flags
            while regex_end < len && line[regex_end].in?('i', 'm', 'x')
              regex_end += 1
            end
            tokens << {line_num, i, regex_end - i, 16, 0} # regexp
            i = regex_end
            next
          end
        end

        # Identifier or keyword
        if char.letter? || char == '_' || char == '@'
          word_start = i
          # Handle @instance_var and @@class_var
          if char == '@'
            i += 1
            i += 1 if i < len && line[i] == '@'
          end
          while i < len && (line[i].alphanumeric? || line[i] == '_')
            i += 1
          end
          # Include trailing ? or !
          if i < len && (line[i] == '?' || line[i] == '!')
            i += 1
          end
          word = line[word_start...i]
          bare_word = word.lstrip('@')

          if char == '@'
            tokens << {line_num, word_start, word.size, 7, 0} # property
          elsif MODIFIERS.includes?(word)
            tokens << {line_num, word_start, word.size, 11, 0} # modifier
          elsif KEYWORDS.includes?(word)
            tokens << {line_num, word_start, word.size, 10, 0} # keyword
          elsif word =~ /^[A-Z]/
            tokens << {line_num, word_start, word.size, 1, 0} # type
          else
            # Check context: is this a method def or call?
            before = line[0...word_start].rstrip
            if before.ends_with?("def")
              tokens << {line_num, word_start, word.size, 8, 1} # function, definition
            elsif before.ends_with?("macro")
              tokens << {line_num, word_start, word.size, 9, 1} # macro, definition
            elsif before.ends_with?("module")
              tokens << {line_num, word_start, word.size, 0, 1} # namespace, definition
            elsif before.ends_with?("class")
              tokens << {line_num, word_start, word.size, 2, 1} # class, definition
            elsif before.ends_with?("struct")
              tokens << {line_num, word_start, word.size, 4, 1} # struct, definition
            elsif before.ends_with?("enum")
              tokens << {line_num, word_start, word.size, 3, 1} # enum, definition
            else
              tokens << {line_num, word_start, word.size, 6, 0} # variable
            end
          end
          next
        end

        # Operators
        if char.in?('+', '-', '*', '/', '=', '<', '>', '!', '&', '|', '^', '~', '%')
          op_end = i + 1
          while op_end < len && line[op_end].in?('+', '-', '*', '/', '=', '<', '>', '!', '&', '|', '^', '~', '%')
            op_end += 1
          end
          tokens << {line_num, i, op_end - i, 15, 0} # operator
          i = op_end
          next
        end

        i += 1
      end
    end

    private def self.find_string_end(line : String, start : Int32) : Int32
      i = start + 1
      while i < line.size
        if line[i] == '\\'
          i += 2
        elsif line[i] == '"'
          return i + 1
        else
          i += 1
        end
      end
      line.size
    end

    private def self.find_char_end(line : String, start : Int32) : Int32
      i = start + 1
      while i < line.size
        if line[i] == '\\'
          i += 2
        elsif line[i] == '\''
          return i + 1
        else
          i += 1
        end
      end
      line.size
    end

    # Encode tokens as delta-encoded array
    private def self.encode(tokens : Array({Int32, Int32, Int32, Int32, Int32})) : Array(Int32)
      result = [] of Int32
      prev_line = 0
      prev_col = 0

      tokens.each do |line, col, length, type, modifiers|
        delta_line = line - prev_line
        delta_col = delta_line == 0 ? col - prev_col : col

        result << delta_line
        result << delta_col
        result << length
        result << type
        result << modifiers

        prev_line = line
        prev_col = col
      end

      result
    end
  end
end
