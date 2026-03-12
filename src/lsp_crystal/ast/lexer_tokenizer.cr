module Lsp::Crystal
  module AST
    module LexerTokenizer
      # Maps Crystal lexer tokens to LSP semantic token type IDs
      # Must match Providers::SemanticTokens::TOKEN_TYPES indices
      TYPE_NAMESPACE = 0
      TYPE_TYPE      = 1
      TYPE_CLASS     = 2
      TYPE_ENUM      = 3
      TYPE_STRUCT    = 4
      TYPE_PARAMETER = 5
      TYPE_VARIABLE  = 6
      TYPE_PROPERTY  = 7
      TYPE_FUNCTION  = 8
      TYPE_MACRO     = 9
      TYPE_KEYWORD   = 10
      TYPE_MODIFIER  = 11
      TYPE_COMMENT   = 12
      TYPE_STRING    = 13
      TYPE_NUMBER    = 14
      TYPE_OPERATOR  = 15
      TYPE_REGEXP    = 16

      MOD_DEFINITION = 1 # bit 1

      MODIFIER_KEYWORDS = Set{"abstract", "private", "protected"}

      DEFINITION_KEYWORDS = Set{"def", "macro", "class", "struct", "module", "enum"}

      # Tokenize source code using Crystal's Lexer
      # Returns array of {line, col, length, type, modifiers} tuples (0-based line/col)
      def self.tokenize(source : String) : Array({Int32, Int32, Int32, Int32, Int32})?
        tokens = [] of {Int32, Int32, Int32, Int32, Int32}
        lexer = ::Crystal::Lexer.new(source)
        lexer.comments_enabled = true

        prev_keyword : String? = nil
        string_depth = 0

        loop do
          token = lexer.next_token

          case token.type
          when .eof?
            break
          when .space?, .newline?
            next
          when .comment?
            val = token.value.to_s
            line = token.line_number - 1
            col = token.column_number - 1
            tokens << {line, col, val.size, TYPE_COMMENT, 0}
          when .number?
            val = token.value.to_s
            line = token.line_number - 1
            col = token.column_number - 1
            tokens << {line, col, val.size, TYPE_NUMBER, 0}
          when .char?
            line = token.line_number - 1
            col = token.column_number - 1
            # Char literal is at least 3 chars: 'x'
            raw = token.raw
            len = raw.empty? ? 3 : raw.size
            tokens << {line, col, len, TYPE_STRING, 0}
          when .symbol?
            val = token.value.to_s
            line = token.line_number - 1
            col = token.column_number - 1
            # Symbol includes the leading :
            tokens << {line, col, val.size + 1, TYPE_STRING, 0}
          when .instance_var?
            val = token.value.to_s
            line = token.line_number - 1
            col = token.column_number - 1
            tokens << {line, col, val.size, TYPE_PROPERTY, 0}
          when .class_var?
            val = token.value.to_s
            line = token.line_number - 1
            col = token.column_number - 1
            tokens << {line, col, val.size, TYPE_PROPERTY, 0}
          when .const?
            val = token.value.to_s
            line = token.line_number - 1
            col = token.column_number - 1
            modifiers = 0
            sem_type = TYPE_TYPE
            # Check if this is after a definition keyword
            if pk = prev_keyword
              case pk
              when "class"  then sem_type = TYPE_CLASS; modifiers = MOD_DEFINITION
              when "struct" then sem_type = TYPE_STRUCT; modifiers = MOD_DEFINITION
              when "module" then sem_type = TYPE_NAMESPACE; modifiers = MOD_DEFINITION
              when "enum"   then sem_type = TYPE_ENUM; modifiers = MOD_DEFINITION
              end
            end
            tokens << {line, col, val.size, sem_type, modifiers}
            prev_keyword = nil
          when .ident?
            val = token.value
            line = token.line_number - 1
            col = token.column_number - 1

            case val
            when ::Crystal::Keyword
              word = val.to_s.downcase
              if MODIFIER_KEYWORDS.includes?(word)
                tokens << {line, col, word.size, TYPE_MODIFIER, 0}
              else
                tokens << {line, col, word.size, TYPE_KEYWORD, 0}
              end
              prev_keyword = word if DEFINITION_KEYWORDS.includes?(word)
              next
            end

            word = val.to_s
            modifiers = 0
            sem_type = TYPE_VARIABLE

            if pk = prev_keyword
              case pk
              when "def"   then sem_type = TYPE_FUNCTION; modifiers = MOD_DEFINITION
              when "macro" then sem_type = TYPE_MACRO; modifiers = MOD_DEFINITION
              end
              prev_keyword = nil
            end

            tokens << {line, col, word.size, sem_type, modifiers}
            next
          when .global?
            val = token.value.to_s
            line = token.line_number - 1
            col = token.column_number - 1
            tokens << {line, col, val.size, TYPE_VARIABLE, 0}
          when .delimiter_start?
            # String/regex/heredoc start — track the opening position and read through
            start_line = token.line_number - 1
            start_col = token.column_number - 1
            delimiter_state = token.delimiter_state
            is_regex = delimiter_state.kind.regex?

            # Read string contents until delimiter end
            end_line = start_line
            end_col = start_col + 1
            loop do
              token = lexer.next_string_token(delimiter_state)
              end_line = token.line_number - 1
              end_col = token.column_number - 1
              if token.type.delimiter_end?
                end_col += 1 # include closing delimiter
                break
              elsif token.type.eof?
                break
              elsif token.type.interpolation_start?
                # Emit the string portion so far
                len = 0
                if end_line == start_line
                  len = end_col - start_col
                else
                  # Multi-line: just emit from start to end of first line as approximation
                  # and handle rest via successive tokens
                  len = end_col - start_col
                end
                if len > 0
                  sem_type = is_regex ? TYPE_REGEXP : TYPE_STRING
                  tokens << {start_line, start_col, len, sem_type, 0}
                end

                # Read interpolation contents with normal lexer
                interp_depth = 1
                loop do
                  token = lexer.next_token
                  break if token.type.eof?
                  if token.type == ::Crystal::Token::Kind::OP_LCURLY
                    interp_depth += 1
                  elsif token.type == ::Crystal::Token::Kind::OP_RCURLY
                    interp_depth -= 1
                    break if interp_depth == 0
                  end
                  # Emit interpolation tokens
                  emit_simple_token(token, tokens)
                end

                # Continue reading string after interpolation
                start_line = token.line_number - 1
                start_col = token.column_number - 1
                next
              end
            end

            # Emit the final string token
            len = if end_line == start_line
                    end_col - start_col
                  else
                    # For multi-line strings, just report the whole thing on the start line
                    # This is a simplification but avoids complex multi-line token tracking
                    1
                  end

            if len > 0
              sem_type = is_regex ? TYPE_REGEXP : TYPE_STRING
              tokens << {start_line, start_col, len, sem_type, 0}
            end
          else
            # Operators and punctuation
            line = token.line_number - 1
            col = token.column_number - 1
            type_str = token.type.to_s

            if operator_token?(token.type)
              tokens << {line, col, type_str.size, TYPE_OPERATOR, 0}
            end
            # Skip punctuation (parens, brackets, etc.)
          end

          # Clear prev_keyword for non-whitespace tokens that aren't keywords
          unless token.type.ident? || token.type.space? || token.type.newline?
            prev_keyword = nil
          end
        end

        tokens
      rescue
        nil
      end

      private def self.emit_simple_token(token : ::Crystal::Token, tokens : Array({Int32, Int32, Int32, Int32, Int32})) : Nil
        line = token.line_number - 1
        col = token.column_number - 1

        case token.type
        when .ident?
          val = token.value
          case val
          when ::Crystal::Keyword
            word = val.to_s.downcase
            tokens << {line, col, word.size, TYPE_KEYWORD, 0}
          else
            word = val.to_s
            tokens << {line, col, word.size, TYPE_VARIABLE, 0}
          end
        when .const?
          val = token.value.to_s
          tokens << {line, col, val.size, TYPE_TYPE, 0}
        when .instance_var?, .class_var?
          val = token.value.to_s
          tokens << {line, col, val.size, TYPE_PROPERTY, 0}
        when .number?
          val = token.value.to_s
          tokens << {line, col, val.size, TYPE_NUMBER, 0}
        end
      end

      private def self.operator_token?(type : ::Crystal::Token::Kind) : Bool
        case type
        when .op_plus?, .op_minus?, .op_star?, .op_slash?, .op_eq?, .op_lt?, .op_gt?,
             .op_bang?, .op_amp?, .op_bar?, .op_caret?, .op_tilde?, .op_percent?,
             .op_eq_eq?, .op_bang_eq?, .op_lt_eq?, .op_gt_eq?, .op_lt_eq_gt?,
             .op_amp_amp?, .op_bar_bar?, .op_eq_tilde?, .op_bang_tilde?,
             .op_star_star?, .op_lt_lt?, .op_gt_gt?,
             .op_plus_eq?, .op_minus_eq?, .op_star_eq?, .op_slash_eq?,
             .op_amp_eq?, .op_bar_eq?, .op_caret_eq?, .op_percent_eq?,
             .op_star_star_eq?, .op_lt_lt_eq?, .op_gt_gt_eq?,
             .op_amp_amp_eq?, .op_bar_bar_eq?, .op_eq_eq_eq?
          true
        else
          false
        end
      end
    end
  end
end
