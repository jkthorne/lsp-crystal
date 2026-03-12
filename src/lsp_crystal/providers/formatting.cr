module Lsp::Crystal::Providers
  module Formatting
    BLOCK_OPENERS = /^\s*(def |class |struct |module |enum |if |unless |case |while |until |begin\b|do\b|macro |for |lib |fun |annotation |(?:.*\bdo\s*(?:\|.*\|)?\s*$))/

    def self.run(document : Document) : Array(TextEdit)?
      result = CrystalTool.format(document.content)
      return nil unless result.success

      formatted = result.stdout
      return nil if formatted == document.content

      # Single edit replacing entire document
      [TextEdit.new(
        range: Range.new(
          start: Position.new(line: 0, character: 0),
          end_pos: document.end_position
        ),
        new_text: formatted
      )]
    end

    # Format only the lines within the requested range
    def self.run_range(document : Document, range : Range) : Array(TextEdit)?
      result = CrystalTool.format(document.content)
      return nil unless result.success

      formatted = result.stdout
      return nil if formatted == document.content

      original_lines = document.content.lines(chomp: false)
      formatted_lines = formatted.lines(chomp: false)

      start_line = range.start.line
      end_line = range.end_pos.line

      edits = [] of TextEdit
      # Compare lines within range
      max_line = {end_line, original_lines.size - 1, formatted_lines.size - 1}.min
      (start_line..max_line).each do |i|
        orig = i < original_lines.size ? original_lines[i] : ""
        fmt = i < formatted_lines.size ? formatted_lines[i] : ""
        if orig != fmt
          # Replace the entire line
          orig_text = orig.chomp
          edits << TextEdit.new(
            range: Range.new(
              start: Position.new(line: i, character: 0),
              end_pos: Position.new(line: i, character: orig_text.size)
            ),
            new_text: fmt.chomp
          )
        end
      end

      edits.empty? ? nil : edits
    end

    # On-type formatting for auto-indent
    def self.run_on_type(document : Document, line : Int32, character : Int32, ch : String) : Array(TextEdit)?
      lines = document.content.lines(chomp: false)
      return nil if line < 0 || line >= lines.size

      case ch
      when "\n"
        format_after_newline(lines, line)
      when "d"
        format_after_end(lines, line)
      else
        nil
      end
    end

    # After pressing enter, if previous line opens a block, indent current line
    private def self.format_after_newline(lines : Array(String), line : Int32) : Array(TextEdit)?
      return nil if line < 1
      prev_line = lines[line - 1]

      if prev_line =~ BLOCK_OPENERS
        prev_indent = prev_line[/^(\s*)/, 1]? || ""
        new_indent = prev_indent + "  "
        current_line = lines[line]? || ""
        current_text = current_line.strip

        [TextEdit.new(
          range: Range.new(
            start: Position.new(line: line, character: 0),
            end_pos: Position.new(line: line, character: current_line.chomp.size)
          ),
          new_text: new_indent + current_text
        )]
      else
        nil
      end
    end

    # After typing 'd' (completing 'end'), dedent to match the block opener
    private def self.format_after_end(lines : Array(String), line : Int32) : Array(TextEdit)?
      current_line = lines[line]? || ""
      return nil unless current_line.strip == "end"

      # Walk backwards to find matching block opener
      depth = 1
      i = line - 1
      while i >= 0
        stripped = lines[i].strip
        # Count block closers
        if stripped == "end" || stripped =~ /^end\s/
          depth += 1
        end
        # Count block openers
        if stripped =~ BLOCK_OPENERS
          depth -= 1
          if depth == 0
            opener_indent = lines[i][/^(\s*)/, 1]? || ""
            current_indent_end = current_line.size - current_line.lstrip.size
            return nil if current_line[0...current_indent_end] == opener_indent

            return [TextEdit.new(
              range: Range.new(
                start: Position.new(line: line, character: 0),
                end_pos: Position.new(line: line, character: current_line.chomp.size)
              ),
              new_text: opener_indent + "end"
            )]
          end
        end
        i -= 1
      end

      nil
    end
  end
end
