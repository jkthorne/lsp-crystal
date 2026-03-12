module Lsp::Crystal::Providers
  module CodeLens
    struct CodeLensItem
      include JSON::Serializable

      property range : Range
      property command : CodeLensCommand?
      property data : JSON::Any?

      def initialize(@range, @command = nil, @data = nil)
      end
    end

    struct CodeLensCommand
      include JSON::Serializable

      property title : String
      property command : String
      property arguments : Array(JSON::Any)?

      def initialize(@title, @command, @arguments = nil)
      end
    end

    # Returns unresolved code lenses (no command, just data for lazy resolution)
    def self.run(document : Document, uri : String) : Array(CodeLensItem)
      lenses = [] of CodeLensItem

      document.content.each_line.with_index do |line, line_num|
        # Match method definitions
        if match = line.match(/^\s*def\s+(self\.)?(\w+[?!=]?)/)
          name = match[1]? == "self." ? "self.#{match[2]}" : match[2]
          col = line.index(name) || 0
          add_unresolved_lens(lenses, line_num, col, name, uri)
        end

        # Match class/module/struct/enum definitions
        if match = line.match(/^\s*(class|module|struct|enum)\s+(\w+(?:::\w+)*)/)
          name = match[2]
          col = line.index(name) || 0
          add_unresolved_lens(lenses, line_num, col, name, uri)
        end

        # Match constants
        if match = line.match(/^\s*([A-Z][A-Z0-9_]+)\s*=/)
          name = match[1]
          col = line.index(name) || 0
          add_unresolved_lens(lenses, line_num, col, name, uri)
        end
      end

      lenses
    end

    # Resolve a single code lens by computing its reference count
    def self.resolve(item : CodeLensItem, document : Document, workspace_index : WorkspaceIndex?) : CodeLensItem
      data = item.data
      name = data.try { |d| d["name"]?.try(&.as_s) } || "unknown"

      count = count_references(name, document, workspace_index)
      line_num = item.range.start.line
      col = item.range.start.character

      title = count == 1 ? "1 reference" : "#{count} references"
      command = CodeLensCommand.new(
        title: title,
        command: "crystal-lsp.showReferences",
        arguments: [JSON::Any.new(line_num.to_i64), JSON::Any.new(col.to_i64)]
      )

      CodeLensItem.new(range: item.range, command: command, data: item.data)
    end

    private def self.add_unresolved_lens(lenses : Array(CodeLensItem), line_num : Int32, col : Int32, name : String, uri : String) : Nil
      range = Range.new(
        start: Position.new(line: line_num, character: col),
        end_pos: Position.new(line: line_num, character: col + name.size)
      )

      data = JSON::Any.new({
        "name" => JSON::Any.new(name),
        "uri"  => JSON::Any.new(uri),
      })

      lenses << CodeLensItem.new(range: range, data: data)
    end

    private def self.count_references(name : String, document : Document, workspace_index : WorkspaceIndex?) : Int32
      pattern = /\b#{Regex.escape(name)}\b/
      count = 0

      # Count in current document
      document.content.each_line do |line|
        line.scan(pattern) { count += 1 }
      end

      # Count in workspace index
      if workspace_index && workspace_index.indexed?
        current_path = URI.uri_to_path(document.uri)
        workspace_index.search_references(pattern, exclude_path: current_path, max_results: 1000).size.tap do |ws_count|
          count += ws_count
        end
      end

      # Subtract 1 for the definition itself
      {count - 1, 0}.max
    end
  end
end
