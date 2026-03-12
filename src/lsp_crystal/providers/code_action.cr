module Lsp::Crystal::Providers
  module CodeAction
    # Code action kinds
    QUICK_FIX     = "quickfix"
    SOURCE        = "source"
    SOURCE_ORGANIZE_IMPORTS = "source.organizeImports"
    REFACTOR         = "refactor"
    REFACTOR_EXTRACT = "refactor.extract"

    def self.run(document : Document, range : Range, diagnostics : Array(JSON::Any)?) : Array(Lsp::Crystal::CodeAction)
      actions = [] of Lsp::Crystal::CodeAction

      # Diagnostic-driven quick fixes
      if diags = diagnostics
        diags.each do |diag|
          message = diag["message"]?.try(&.as_s) || next
          diag_range = parse_range(diag["range"]?) || next

          if action = suggest_fix(document, message, diag_range)
            actions << action
          end
        end
      end

      # Source action: organize requires (sort)
      if action = organize_requires(document)
        actions << action
      end

      # Refactoring: extract variable (when a non-trivial expression is selected on a single line)
      if action = extract_variable(document, range)
        actions << action
      end

      # Refactoring: extract method (when multiple lines are selected)
      if action = extract_method(document, range)
        actions << action
      end

      actions
    end

    private def self.suggest_fix(document : Document, message : String, diag_range : Range) : Lsp::Crystal::CodeAction?
      # Unused variable → prefix with underscore
      if message.includes?("isn't used") || message.includes?("is not used")
        line_text = document.line_at(diag_range.start.line)
        return nil unless line_text

        # Extract the variable name from the diagnostic range
        start_col = diag_range.start.character
        end_col = diag_range.end_pos.character
        var_name = line_text[start_col...end_col]?
        return nil unless var_name && !var_name.empty? && !var_name.starts_with?("_")

        new_name = "_#{var_name}"
        edit = WorkspaceEdit.new
        edits = [TextEdit.new(range: diag_range, new_text: new_name)]
        edit.changes[document.uri] = edits

        return Lsp::Crystal::CodeAction.new(
          title: "Prefix '#{var_name}' with underscore",
          kind: QUICK_FIX,
          edit: edit
        )
      end

      nil
    end

    private def self.extract_variable(document : Document, range : Range) : Lsp::Crystal::CodeAction?
      # Only for single-line selections with content
      return nil unless range.start.line == range.end_pos.line
      return nil if range.start.character == range.end_pos.character

      line_text = document.line_at(range.start.line)
      return nil unless line_text

      selected = line_text[range.start.character...range.end_pos.character]?
      return nil unless selected && !selected.empty?

      # Skip if selection is just whitespace or a simple variable name
      return nil if selected.strip.empty?
      return nil if selected =~ /^\w+$/

      # Determine indentation of the current line
      indent = ""
      line_text.each_char do |c|
        break unless c == ' ' || c == '\t'
        indent += c.to_s
      end

      var_name = "extracted"
      declaration = "#{indent}#{var_name} = #{selected}\n"

      edits = [
        # Insert the variable declaration above the current line
        TextEdit.new(
          range: Range.new(
            start: Position.new(line: range.start.line, character: 0),
            end_pos: Position.new(line: range.start.line, character: 0)
          ),
          new_text: declaration
        ),
        # Replace the selected expression with the variable name
        TextEdit.new(
          range: Range.new(
            start: Position.new(line: range.start.line + 1, character: range.start.character),
            end_pos: Position.new(line: range.end_pos.line + 1, character: range.end_pos.character)
          ),
          new_text: var_name
        ),
      ]

      changes = Hash(String, Array(TextEdit)).new
      changes[document.uri] = edits
      edit = WorkspaceEdit.new(changes)

      Lsp::Crystal::CodeAction.new(
        title: "Extract variable",
        kind: REFACTOR_EXTRACT,
        edit: edit
      )
    end

    private def self.extract_method(document : Document, range : Range) : Lsp::Crystal::CodeAction?
      # Only for multi-line selections (at least 2 code lines)
      return nil if range.start.line == range.end_pos.line
      return nil if range.end_pos.line - range.start.line < 2

      lines = document.content.lines
      return nil if range.start.line >= lines.size

      # Don't offer extract method if the selection spans most of the document
      return nil if range.start.line == 0 && range.end_pos.line >= lines.size - 1

      # Collect selected lines
      selected_lines = [] of String
      (range.start.line..Math.min(range.end_pos.line, lines.size - 1)).each do |i|
        selected_lines << lines[i]
      end
      return nil if selected_lines.empty?

      # Determine the indentation of the first selected line
      first_line = selected_lines.first
      indent = ""
      first_line.each_char do |c|
        break unless c == ' ' || c == '\t'
        indent += c.to_s
      end

      # Find the enclosing method/class end to insert the new method after
      method_body = selected_lines.map { |l|
        # Re-indent the body with standard 2-space indent
        stripped = l.strip
        stripped.empty? ? "" : "    #{stripped}"
      }.join("\n")

      method_name = "extracted_method"
      new_method = "\n#{indent}private def #{method_name}\n#{method_body}\n#{indent}end\n"

      # Build edits: replace selection with method call, insert method after enclosing block
      insert_line = find_method_insert_point(lines, range.end_pos.line)

      edits = [
        # Replace selected lines with method call
        TextEdit.new(
          range: Range.new(
            start: Position.new(line: range.start.line, character: 0),
            end_pos: Position.new(line: range.end_pos.line, character: lines[Math.min(range.end_pos.line, lines.size - 1)].size)
          ),
          new_text: "#{indent}  #{method_name}"
        ),
        # Insert new method definition
        TextEdit.new(
          range: Range.new(
            start: Position.new(line: insert_line, character: lines[Math.min(insert_line, lines.size - 1)]?.try(&.size) || 0),
            end_pos: Position.new(line: insert_line, character: lines[Math.min(insert_line, lines.size - 1)]?.try(&.size) || 0)
          ),
          new_text: new_method
        ),
      ]

      changes = Hash(String, Array(TextEdit)).new
      changes[document.uri] = edits
      edit = WorkspaceEdit.new(changes)

      Lsp::Crystal::CodeAction.new(
        title: "Extract method",
        kind: REFACTOR_EXTRACT,
        edit: edit
      )
    end

    # Find a good insertion point for a new method (after the enclosing method's end)
    private def self.find_method_insert_point(lines : Array(String), from_line : Int32) : Int32
      depth = 0
      (from_line...lines.size).each do |i|
        stripped = lines[i].strip
        if stripped =~ /^\s*(?:def|class|struct|module)\b/
          depth += 1
        end
        if stripped =~ /^\s*end\b/
          if depth > 0
            depth -= 1
          else
            return i
          end
        end
      end
      lines.size - 1
    end

    private def self.organize_requires(document : Document) : Lsp::Crystal::CodeAction?
      lines = document.content.lines
      require_groups = [] of Array({Int32, String})
      current_group = [] of {Int32, String}

      lines.each_with_index do |line, idx|
        if line =~ /^\s*require\s+"/
          current_group << {idx, line}
        else
          if current_group.size > 1
            require_groups << current_group.dup
          end
          current_group.clear
        end
      end
      if current_group.size > 1
        require_groups << current_group
      end

      return nil if require_groups.empty?

      # Check if any group is unsorted
      needs_sort = require_groups.any? do |group|
        sorted = group.map(&.[1]).sort
        group.map(&.[1]) != sorted
      end
      return nil unless needs_sort

      changes = Hash(String, Array(TextEdit)).new
      edits = [] of TextEdit

      require_groups.each do |group|
        sorted_lines = group.map(&.[1]).sort
        next if group.map(&.[1]) == sorted_lines

        first_line = group.first[0]
        last_line = group.last[0]

        edits << TextEdit.new(
          range: Range.new(
            start: Position.new(line: first_line, character: 0),
            end_pos: Position.new(line: last_line, character: lines[last_line].size)
          ),
          new_text: sorted_lines.join("\n")
        )
      end

      return nil if edits.empty?
      changes[document.uri] = edits
      edit = WorkspaceEdit.new(changes)

      Lsp::Crystal::CodeAction.new(
        title: "Organize requires",
        kind: SOURCE_ORGANIZE_IMPORTS,
        edit: edit
      )
    end

    private def self.parse_range(json : JSON::Any?) : Range?
      return nil unless json
      start_json = json["start"]?
      end_json = json["end"]?
      return nil unless start_json && end_json

      Range.new(
        start: Position.new(
          line: start_json["line"].as_i,
          character: start_json["character"].as_i
        ),
        end_pos: Position.new(
          line: end_json["line"].as_i,
          character: end_json["character"].as_i
        )
      )
    end
  end
end
