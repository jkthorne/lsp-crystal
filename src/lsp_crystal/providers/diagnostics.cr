module Lsp::Crystal::Providers
  module Diagnostics
    # Crystal multi-line error format:
    #   In file.cr:10:5
    #
    #    10 | some code
    #              ^
    #   Error: message here
    LOCATION_REGEX = /^In (.+?):(\d+):(\d+)$/
    MESSAGE_REGEX  = /^(Error|Warning): (.+)$/

    struct Diagnostic
      include JSON::Serializable

      property range : Range
      property severity : Int32
      property source : String
      property message : String

      def initialize(@range, @severity, @source, @message)
      end
    end

    enum Severity
      Error       = 1
      Warning     = 2
      Information = 3
      Hint        = 4
    end

    def self.run(file_path : String) : Array(Diagnostic)
      result = CrystalTool.check(file_path)
      return [] of Diagnostic if result.success
      parse_output(result.stderr)
    end

    def self.run_content(content : String, filename : String) : Array(Diagnostic)
      result = CrystalTool.check_content(content, filename)
      return [] of Diagnostic if result.success
      parse_output(result.stderr)
    end

    def self.parse_output(output : String) : Array(Diagnostic)
      diagnostics = [] of Diagnostic
      seen = Set(String).new

      lines = output.lines
      i = 0
      while i < lines.size
        line = lines[i].strip
        if loc_match = LOCATION_REGEX.match(line)
          file = loc_match[1]
          line_num = loc_match[2].to_i - 1 # Convert to 0-based
          col = loc_match[3].to_i - 1

          # Scan forward for Error/Warning line
          j = i + 1
          message_text = nil
          severity = Severity::Error
          while j < lines.size
            stripped = lines[j].strip
            if msg_match = MESSAGE_REGEX.match(stripped)
              severity = msg_match[1] == "Warning" ? Severity::Warning : Severity::Error
              # Collect the full error message (may span multiple lines)
              message_text = msg_match[2]
              # Check for continuation lines (indented under Error:)
              k = j + 1
              while k < lines.size
                next_line = lines[k]
                # Continuation lines are typically indented or non-empty non-location lines
                break if next_line.strip.empty?
                break if LOCATION_REGEX.match(next_line.strip)
                message_text += "\n" + next_line.strip
                k += 1
              end
              i = k
              break
            elsif LOCATION_REGEX.match(stripped)
              # Hit next error without finding message
              break
            end
            j += 1
          end

          if message_text
            line_num = Math.max(0, line_num)
            col = Math.max(0, col)

            key = "#{file}:#{line_num}:#{col}:#{message_text}"
            unless seen.includes?(key)
              seen.add(key)
              diagnostics << Diagnostic.new(
                range: Range.new(
                  start: Position.new(line: line_num, character: col),
                  end_pos: Position.new(line: line_num, character: col)
                ),
                severity: severity.value,
                source: "crystal",
                message: message_text
              )
            end
          else
            i = j
          end
        else
          i += 1
        end
      end

      diagnostics
    end
  end
end
