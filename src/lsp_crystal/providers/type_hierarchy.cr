module Lsp::Crystal::Providers
  module TypeHierarchy
    struct TypeHierarchyItem
      include JSON::Serializable

      property name : String
      property kind : Int32
      property uri : String
      property range : Range

      @[JSON::Field(key: "selectionRange")]
      property selection_range : Range

      property data : JSON::Any?

      def initialize(@name, @kind, @uri, @range, @selection_range, @data = nil)
      end
    end

    TYPE_REGEX = /^\s*(class|struct|module|enum)\s+(\w+(?:::\w+)*)(?:\s*<\s*(\w+(?:::\w+)*))?/

    def self.prepare(document : Document, line : Int32, character : Int32) : Array(TypeHierarchyItem)
      text = document.line_at(line)
      return [] of TypeHierarchyItem unless text

      match = text.match(TYPE_REGEX)
      return [] of TypeHierarchyItem unless match

      keyword = match[1]
      name = match[2]
      superclass = match[3]?

      kind = case keyword
             when "class"  then DocumentSymbol::SymbolKind::Class
             when "struct" then DocumentSymbol::SymbolKind::Struct
             when "module" then DocumentSymbol::SymbolKind::Module
             when "enum"   then DocumentSymbol::SymbolKind::Enum
             else               DocumentSymbol::SymbolKind::Class
             end

      col = text.index(name) || 0
      range = Range.new(
        start: Position.new(line: line, character: col),
        end_pos: Position.new(line: line, character: col + name.size)
      )

      # Build data with superclass and includes
      includes = find_includes(document, line)
      data_hash = {} of String => JSON::Any
      data_hash["superclass"] = JSON::Any.new(superclass) if superclass
      data_hash["includes"] = JSON::Any.new(includes.map { |i| JSON::Any.new(i) }) unless includes.empty?

      data = data_hash.empty? ? nil : JSON::Any.new(data_hash)

      [TypeHierarchyItem.new(
        name: name,
        kind: kind.value,
        uri: document.uri,
        range: range,
        selection_range: range,
        data: data
      )]
    end

    def self.supertypes(item : TypeHierarchyItem, workspace_index : WorkspaceIndex?) : Array(TypeHierarchyItem)
      results = [] of TypeHierarchyItem

      if data = item.data
        # Check superclass
        if superclass = data["superclass"]?.try(&.as_s?)
          if found = find_type_in_workspace(superclass, workspace_index)
            results << found
          end
        end

        # Check includes
        if includes = data["includes"]?.try(&.as_a?)
          includes.each do |inc|
            if name = inc.as_s?
              if found = find_type_in_workspace(name, workspace_index)
                results << found
              end
            end
          end
        end
      end

      results
    end

    def self.subtypes(item : TypeHierarchyItem, workspace_index : WorkspaceIndex?) : Array(TypeHierarchyItem)
      results = [] of TypeHierarchyItem
      return results unless workspace_index && workspace_index.indexed?

      name = item.name
      # Search for classes inheriting from this type
      inherit_pattern = /^\s*(?:class|struct)\s+(\w+(?:::\w+)*)\s*<\s*#{Regex.escape(name)}\b/
      include_pattern = /^\s*(?:include|extend)\s+#{Regex.escape(name)}\b/

      workspace_index.@mutex.synchronize do
        workspace_index.@files.each_value do |entry|
          entry.content.each_line.with_index do |line_text, line_num|
            if match = line_text.match(inherit_pattern)
              subtype_name = match[1]
              col = line_text.index(subtype_name) || 0
              range = Range.new(
                start: Position.new(line: line_num, character: col),
                end_pos: Position.new(line: line_num, character: col + subtype_name.size)
              )
              results << TypeHierarchyItem.new(
                name: subtype_name,
                kind: DocumentSymbol::SymbolKind::Class.value,
                uri: entry.uri,
                range: range,
                selection_range: range
              )
            elsif match = line_text.match(include_pattern)
              # Find the enclosing type
              enclosing = find_enclosing_type(entry.content, line_num)
              if enclosing
                results << enclosing.call(entry.uri)
              end
            end
          end
        end
      end

      results
    end

    private def self.find_includes(document : Document, type_line : Int32) : Array(String)
      includes = [] of String
      lines = document.content.lines
      depth = 0

      ((type_line + 1)...lines.size).each do |i|
        stripped = lines[i].strip
        if stripped =~ /^(?:class|struct|module|enum|def|macro|if|unless|case|while|until|begin|do|for|lib|fun|annotation)\b/
          depth += 1
        end
        if stripped =~ /^end\b/
          if depth > 0
            depth -= 1
          else
            break # end of type body
          end
        end
        if depth == 0 && (match = stripped.match(/^(?:include|extend)\s+(\w+(?:::\w+)*)/))
          includes << match[1]
        end
      end

      includes
    end

    private def self.find_type_in_workspace(type_name : String, workspace_index : WorkspaceIndex?) : TypeHierarchyItem?
      return nil unless workspace_index && workspace_index.indexed?

      workspace_index.search_type_definition(type_name) do |uri, line_num, col|
        range = Range.new(
          start: Position.new(line: line_num, character: col),
          end_pos: Position.new(line: line_num, character: col + type_name.size)
        )
        return TypeHierarchyItem.new(
          name: type_name,
          kind: DocumentSymbol::SymbolKind::Class.value,
          uri: uri,
          range: range,
          selection_range: range
        )
      end

      nil
    end

    private def self.find_enclosing_type(content : String, include_line : Int32) : Proc(String, TypeHierarchyItem)?
      lines = content.lines
      depth = 0

      (include_line - 1).downto(0) do |i|
        stripped = lines[i].strip
        if stripped =~ /^end\b/
          depth += 1
        elsif stripped =~ /^(?:class|struct|module|enum)\s+(\w+(?:::\w+)*)/
          if depth == 0
            type_name = $1
            col = lines[i].index(type_name) || 0
            line_num = i
            return Proc(String, TypeHierarchyItem).new { |uri|
              range = Range.new(
                start: Position.new(line: line_num, character: col),
                end_pos: Position.new(line: line_num, character: col + type_name.size)
              )
              TypeHierarchyItem.new(
                name: type_name,
                kind: DocumentSymbol::SymbolKind::Class.value,
                uri: uri,
                range: range,
                selection_range: range
              )
            }
          else
            depth -= 1
          end
        end
      end

      nil
    end
  end
end
