module Lsp::Crystal::Providers
  module CodeAction
    # Code action kinds
    QUICK_FIX     = "quickfix"
    SOURCE        = "source"
    SOURCE_ORGANIZE_IMPORTS = "source.organizeImports"
    REFACTOR         = "refactor"
    REFACTOR_EXTRACT = "refactor.extract"

    def self.run(document : Document, range : Range, diagnostics : Array(JSON::Any)?, workspace_index : WorkspaceIndex? = nil) : Array(Lsp::Crystal::CodeAction)
      actions = [] of Lsp::Crystal::CodeAction

      # Diagnostic-driven quick fixes
      if diags = diagnostics
        diags.each do |diag|
          message = diag["message"]?.try(&.as_s) || next
          diag_range = parse_range(diag["range"]?) || next

          if action = suggest_fix(document, message, diag_range, workspace_index)
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

      # Refactoring: convert single-line block to multi-line
      if action = convert_to_multiline(document, range)
        actions << action
      end

      actions
    end

    private def self.suggest_fix(document : Document, message : String, diag_range : Range, workspace_index : WorkspaceIndex? = nil) : Lsp::Crystal::CodeAction?
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

      # Generate missing method stub
      if match = message.match(/undefined method '(\w+[?!=]?)'\s*(?:for\s+(\w+(?:::\w+)*))?/)
        method_name = match[1]
        type_name = match[2]?
        if action = generate_method_stub(document, method_name, type_name, workspace_index)
          return action
        end
      end

      # Add missing require for undefined type
      if match = message.match(/undefined constant (\w+(?:::\w+)*)/)
        type_name = match[1]
        if action = add_missing_require(document, type_name, workspace_index)
          return action
        end
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

    private def self.generate_method_stub(document : Document, method_name : String, type_name : String?, workspace_index : WorkspaceIndex?) : Lsp::Crystal::CodeAction?
      return nil unless type_name
      idx = workspace_index
      return nil unless idx && idx.indexed?

      # Find the type definition in workspace
      target_uri : String? = nil
      target_line : Int32? = nil

      idx.search_type_definition(type_name) do |uri, line_num, _col|
        target_uri = uri
        target_line = line_num
      end

      return nil unless target_uri && target_line

      # Find the end of the type body to insert before it
      target_path = URI.uri_to_path(target_uri.not_nil!)
      content = File.read(target_path) rescue nil
      return nil unless content

      lines = content.not_nil!.lines
      insert_line = find_type_end(lines, target_line.not_nil!)
      return nil unless insert_line

      # Determine indentation from the type definition
      type_line_text = lines[target_line.not_nil!]?
      indent = "  "
      if type_line_text
        base_indent = ""
        type_line_text.each_char do |c|
          break unless c == ' ' || c == '\t'
          base_indent += c.to_s
        end
        indent = base_indent + "  "
      end

      stub = "\n#{indent}def #{method_name}\n#{indent}end\n"

      edit = WorkspaceEdit.new
      insert_col = lines[insert_line]?.try(&.size) || 0
      # Insert before the end keyword
      edits = [TextEdit.new(
        range: Range.new(
          start: Position.new(line: insert_line, character: 0),
          end_pos: Position.new(line: insert_line, character: 0)
        ),
        new_text: stub
      )]
      edit.changes[target_uri.not_nil!] = edits

      Lsp::Crystal::CodeAction.new(
        title: "Generate method '#{method_name}' on #{type_name}",
        kind: QUICK_FIX,
        edit: edit
      )
    end

    private def self.find_type_end(lines : Array(String), type_line : Int32) : Int32?
      depth = 0
      (type_line...lines.size).each do |i|
        stripped = lines[i].strip
        if stripped =~ /^(?:class|struct|module|enum|def|macro|if|unless|case|while|until|begin|do|for|lib|fun|annotation)\b/
          depth += 1
        end
        if stripped =~ /^end\b/
          depth -= 1
          return i if depth <= 0
        end
      end
      nil
    end

    private def self.add_missing_require(document : Document, type_name : String, workspace_index : WorkspaceIndex?) : Lsp::Crystal::CodeAction?
      idx = workspace_index
      return nil unless idx && idx.indexed?

      # Find the file defining this type
      target_path : String? = nil
      idx.search_type_definition(type_name) do |uri, _line_num, _col|
        target_path = URI.uri_to_path(uri)
      end
      return nil unless target_path

      doc_path = document.path
      return nil if doc_path == target_path

      # Compute relative require path
      doc_dir = File.dirname(doc_path)
      rel = compute_relative_require(doc_dir, target_path.not_nil!)
      return nil unless rel

      # Find insertion point: after existing requires or at top
      lines = document.content.lines
      insert_line = 0
      lines.each_with_index do |line, idx|
        if line =~ /^\s*require\s+"/
          insert_line = idx + 1
        end
      end

      require_text = "require \"#{rel}\"\n"

      edit = WorkspaceEdit.new
      edits = [TextEdit.new(
        range: Range.new(
          start: Position.new(line: insert_line, character: 0),
          end_pos: Position.new(line: insert_line, character: 0)
        ),
        new_text: require_text
      )]
      edit.changes[document.uri] = edits

      Lsp::Crystal::CodeAction.new(
        title: "Add require for '#{type_name}'",
        kind: QUICK_FIX,
        edit: edit
      )
    end

    private def self.compute_relative_require(from_dir : String, target_path : String) : String?
      rel = Path.new(target_path).relative_to(Path.new(from_dir)).to_s
      return nil if rel.empty?

      # Remove .cr extension
      rel = rel.chomp(".cr")

      # Ensure it starts with ./
      rel = "./#{rel}" unless rel.starts_with?("../")
      rel
    end

    private def self.convert_to_multiline(document : Document, range : Range) : Lsp::Crystal::CodeAction?
      # Cursor must be on a single line
      return nil unless range.start.line == range.end_pos.line

      line_text = document.line_at(range.start.line)
      return nil unless line_text

      # Match single-line block: expr { |args| body } or expr {body}
      match = line_text.match(/^(\s*)(.*?)\s*\{\s*(\|[^|]*\|)?\s*(.*?)\s*\}\s*$/)
      return nil unless match

      indent = match[1]
      prefix = match[2]
      block_args = match[3]?
      body = match[4]

      # Skip empty blocks or hash literals
      return nil if body.nil? || body.empty?
      return nil if prefix.empty? # likely a hash literal

      # Build multi-line version
      args_part = block_args ? " #{block_args}" : ""
      new_text = "#{indent}#{prefix} do#{args_part}\n#{indent}  #{body}\n#{indent}end"

      edits = [TextEdit.new(
        range: Range.new(
          start: Position.new(line: range.start.line, character: 0),
          end_pos: Position.new(line: range.start.line, character: line_text.size)
        ),
        new_text: new_text
      )]

      changes = Hash(String, Array(TextEdit)).new
      changes[document.uri] = edits
      edit = WorkspaceEdit.new(changes)

      Lsp::Crystal::CodeAction.new(
        title: "Convert to multi-line block",
        kind: REFACTOR,
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
