module Lsp::Crystal::Providers
  module CodeAction
    # Code action kinds
    QUICK_FIX     = "quickfix"
    SOURCE        = "source"
    SOURCE_ORGANIZE_IMPORTS = "source.organizeImports"

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
