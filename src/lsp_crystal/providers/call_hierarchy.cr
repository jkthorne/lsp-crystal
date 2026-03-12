module Lsp::Crystal::Providers
  module CallHierarchy
    struct CallHierarchyItem
      include JSON::Serializable

      property name : String
      property kind : Int32
      property uri : String
      property range : Range

      @[JSON::Field(key: "selectionRange")]
      property selection_range : Range

      def initialize(@name, @kind, @uri, @range, @selection_range)
      end
    end

    struct IncomingCall
      include JSON::Serializable

      @[JSON::Field(key: "from")]
      property from_item : CallHierarchyItem
      @[JSON::Field(key: "fromRanges")]
      property from_ranges : Array(Range)

      def initialize(@from_item, @from_ranges)
      end
    end

    struct OutgoingCall
      include JSON::Serializable

      @[JSON::Field(key: "to")]
      property to_item : CallHierarchyItem
      @[JSON::Field(key: "toRanges")]
      property to_ranges : Array(Range)

      def initialize(@to_item, @to_ranges)
      end
    end

    # Prepare: find the method/class at cursor
    def self.prepare(document : Document, line : Int32, character : Int32) : Array(CallHierarchyItem)
      text = document.line_at(line)
      return [] of CallHierarchyItem unless text

      # Check if cursor is on a method definition
      if match = text.match(/^\s*def\s+(self\.)?(\w+[?!=]?)/)
        name = match[1]? == "self." ? "self.#{match[2]}" : match[2]
        col = text.index(name) || 0
        range = Range.new(
          start: Position.new(line: line, character: col),
          end_pos: Position.new(line: line, character: col + name.size)
        )
        return [CallHierarchyItem.new(
          name: name,
          kind: DocumentSymbol::SymbolKind::Method.value,
          uri: document.uri,
          range: range,
          selection_range: range
        )]
      end

      # Check if cursor is on a class/module/struct definition
      if match = text.match(/^\s*(class|module|struct|enum)\s+(\w+(?:::\w+)*)/)
        name = match[2]
        kind = case match[1]
               when "class"  then DocumentSymbol::SymbolKind::Class
               when "module" then DocumentSymbol::SymbolKind::Module
               when "struct" then DocumentSymbol::SymbolKind::Struct
               when "enum"   then DocumentSymbol::SymbolKind::Enum
               else               DocumentSymbol::SymbolKind::Class
               end
        col = text.index(name) || 0
        range = Range.new(
          start: Position.new(line: line, character: col),
          end_pos: Position.new(line: line, character: col + name.size)
        )
        return [CallHierarchyItem.new(
          name: name,
          kind: kind.value,
          uri: document.uri,
          range: range,
          selection_range: range
        )]
      end

      # Check if cursor is on a method call (word under cursor)
      word = extract_word(text, character)
      return [] of CallHierarchyItem if word.empty?

      col = find_word_start(text, character)
      range = Range.new(
        start: Position.new(line: line, character: col),
        end_pos: Position.new(line: line, character: col + word.size)
      )
      [CallHierarchyItem.new(
        name: word,
        kind: DocumentSymbol::SymbolKind::Method.value,
        uri: document.uri,
        range: range,
        selection_range: range
      )]
    end

    # Find methods that call the given method
    def self.incoming_calls(item : CallHierarchyItem, workspace_index : WorkspaceIndex?) : Array(IncomingCall)
      return [] of IncomingCall unless workspace_index && workspace_index.indexed?

      calls = [] of IncomingCall
      name = item.name
      pattern = /\b#{Regex.escape(name)}\b/

      # Scan all files for calls to this method
      workspace_index.search_references(pattern).each do |ref|
        # Skip the definition itself
        next if ref.uri == item.uri && ref.range.start.line == item.range.start.line

        # Find what method contains this call
        containing = find_containing_method(ref, workspace_index)
        next unless containing

        # Group calls from the same method
        existing = calls.find { |c| c.from_item.name == containing.name && c.from_item.uri == containing.uri }
        if existing
          existing.from_ranges << ref.range
        else
          calls << IncomingCall.new(
            from_item: containing,
            from_ranges: [ref.range]
          )
        end
      end

      calls
    end

    # Find methods called by the given method
    def self.outgoing_calls(item : CallHierarchyItem, document : Document?, workspace_index : WorkspaceIndex?) : Array(OutgoingCall)
      return [] of OutgoingCall unless document

      calls = [] of OutgoingCall
      method_name = item.name
      start_line = item.range.start.line

      # Find the method body: from def line to its end
      in_method = false
      depth = 0
      call_pattern = /\b(\w+[?!]?)\s*[\(\.]/

      document.content.each_line.with_index do |line, line_num|
        stripped = line.strip
        if line_num == start_line
          in_method = true
          depth = 1
          next
        end

        next unless in_method

        if stripped =~ /^(?:class|struct|module|enum|def|macro|if|unless|case|while|until|begin|do|for)\b/
          depth += 1
        end
        if stripped =~ /^end\b/
          depth -= 1
          break if depth <= 0
        end

        # Find method calls in this line
        line.scan(call_pattern) do |match|
          call_name = match[1]
          next if call_name == method_name # skip recursion
          next if SemanticTokens::KEYWORDS.includes?(call_name)

          col = line.index(call_name) || 0
          call_range = Range.new(
            start: Position.new(line: line_num, character: col),
            end_pos: Position.new(line: line_num, character: col + call_name.size)
          )

          # Find the target definition
          target = find_definition(call_name, document, workspace_index)
          next unless target

          existing = calls.find { |c| c.to_item.name == call_name }
          if existing
            existing.to_ranges << call_range
          else
            calls << OutgoingCall.new(
              to_item: target,
              to_ranges: [call_range]
            )
          end
        end
      end

      calls
    end

    private def self.find_containing_method(ref : Location, workspace_index : WorkspaceIndex?) : CallHierarchyItem?
      return nil unless workspace_index
      path = URI.uri_to_path(ref.uri)

      # Find the file in the index
      content = nil
      workspace_index.@mutex.synchronize do
        if entry = workspace_index.@files[path]?
          content = entry.content
        end
      end
      return nil unless content

      # Walk backwards from the reference line to find the containing def
      ref_line = ref.range.start.line
      ref_line.downto(0) do |line_num|
        line = content.lines[line_num]?
        next unless line
        if match = line.match(/^\s*def\s+(self\.)?(\w+[?!=]?)/)
          name = match[1]? == "self." ? "self.#{match[2]}" : match[2]
          col = line.index(name) || 0
          range = Range.new(
            start: Position.new(line: line_num, character: col),
            end_pos: Position.new(line: line_num, character: col + name.size)
          )
          return CallHierarchyItem.new(
            name: name,
            kind: DocumentSymbol::SymbolKind::Method.value,
            uri: ref.uri,
            range: range,
            selection_range: range
          )
        end
      end
      nil
    end

    private def self.find_definition(name : String, document : Document, workspace_index : WorkspaceIndex?) : CallHierarchyItem?
      # Search in current document first
      document.content.each_line.with_index do |line, line_num|
        if match = line.match(/^\s*def\s+(self\.)?(\w+[?!=]?)/)
          def_name = match[1]? == "self." ? "self.#{match[2]}" : match[2]
          if def_name == name
            col = line.index(name) || 0
            range = Range.new(
              start: Position.new(line: line_num, character: col),
              end_pos: Position.new(line: line_num, character: col + name.size)
            )
            return CallHierarchyItem.new(
              name: name,
              kind: DocumentSymbol::SymbolKind::Method.value,
              uri: document.uri,
              range: range,
              selection_range: range
            )
          end
        end
      end
      nil
    end

    private def self.extract_word(text : String, character : Int32) : String
      start_pos = character
      while start_pos > 0 && word_char?(text[start_pos - 1]?)
        start_pos -= 1
      end
      end_pos = character
      while end_pos < text.size && word_char?(text[end_pos]?)
        end_pos += 1
      end
      return "" if start_pos == end_pos
      text[start_pos...end_pos]
    end

    private def self.find_word_start(text : String, character : Int32) : Int32
      start_pos = character
      while start_pos > 0 && word_char?(text[start_pos - 1]?)
        start_pos -= 1
      end
      start_pos
    end

    private def self.word_char?(char : Char?) : Bool
      return false unless char
      char.alphanumeric? || char == '_' || char == '?' || char == '!'
    end
  end
end
