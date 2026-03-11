module Lsp::Crystal::Providers
  module DocumentSymbol
    enum SymbolKind
      File          =  1
      Module        =  2
      Namespace     =  3
      Package       =  4
      Class         =  5
      Method        =  6
      Property      =  7
      Field         =  8
      Constructor   =  9
      Enum          = 10
      Interface     = 11
      Function      = 12
      Variable      = 13
      Constant      = 14
      String        = 15
      Number        = 16
      Boolean       = 17
      Array         = 18
      Object        = 19
      Key           = 20
      Null          = 21
      EnumMember    = 22
      Struct        = 23
      Event         = 24
      Operator      = 25
      TypeParameter = 26
    end

    PATTERNS = [
      {/^\s*class\s+(\w+(?:::\w+)*)/, SymbolKind::Class},
      {/^\s*struct\s+(\w+(?:::\w+)*)/, SymbolKind::Struct},
      {/^\s*module\s+(\w+(?:::\w+)*)/, SymbolKind::Module},
      {/^\s*enum\s+(\w+(?:::\w+)*)/, SymbolKind::Enum},
      {/^\s*def\s+(self\.)?(\w+[?!=]?)/, SymbolKind::Method},
      {/^\s*macro\s+(\w+)/, SymbolKind::Function},
      {/^\s*(?:property|getter|setter)[?!]?\s+(\w+)/, SymbolKind::Property},
      {/^\s*annotation\s+(\w+)/, SymbolKind::Interface},
      {/^\s*alias\s+(\w+)/, SymbolKind::TypeParameter},
    ]

    CONTAINER_KINDS = Set{SymbolKind::Class, SymbolKind::Struct, SymbolKind::Module, SymbolKind::Enum}

    CONSTANT_REGEX = /^\s*([A-Z][A-Z0-9_]+)\s*=/

    # Flat symbol info — used by workspace symbols and completion
    struct SymbolInfo
      include JSON::Serializable

      property name : String
      property kind : Int32
      property range : Range

      @[JSON::Field(key: "selectionRange")]
      property selection_range : Range

      def initialize(@name, @kind, @range, @selection_range)
      end
    end

    # Hierarchical symbol with children — used by textDocument/documentSymbol
    class HierarchicalSymbolInfo
      include JSON::Serializable

      property name : String
      property kind : Int32
      property range : Range

      @[JSON::Field(key: "selectionRange")]
      property selection_range : Range

      property children : Array(HierarchicalSymbolInfo)

      # Track scope depth for building hierarchy (not serialized)
      @[JSON::Field(ignore: true)]
      property depth : Int32 = 0

      def initialize(@name, @kind, @range, @selection_range, @depth = 0)
        @children = [] of HierarchicalSymbolInfo
      end
    end

    # Regex to detect keywords that open a block closed by `end`
    BLOCK_OPEN_REGEX = /^\s*(?:class|struct|module|enum|def|macro|if|unless|case|while|until|begin|do|for|lib|fun|annotation)\b/

    # Returns hierarchical document symbols with nesting
    def self.run(document : Document) : Array(HierarchicalSymbolInfo)
      root_symbols = [] of HierarchicalSymbolInfo
      # scope_stack tracks container symbols for nesting children
      scope_stack = [] of HierarchicalSymbolInfo
      # depth_stack tracks what each nesting level corresponds to:
      # true = container symbol on scope_stack, false = non-container block
      depth_stack = [] of Bool

      document.content.each_line.with_index do |line, line_num|
        stripped = line.strip

        # Check for `end` first
        if stripped =~ /^end\b/
          if depth_stack.size > 0
            is_container = depth_stack.pop
            if is_container && scope_stack.size > 0
              closed = scope_stack.pop
              closed.range = Range.new(
                start: closed.range.start,
                end_pos: Position.new(line: line_num, character: stripped.size)
              )
            end
          end
          next
        end

        symbol = match_symbol(line, line_num)
        is_block_open = BLOCK_OPEN_REGEX.matches?(stripped)

        if symbol
          kind = SymbolKind.from_value(symbol.kind)
          node = HierarchicalSymbolInfo.new(
            name: symbol.name,
            kind: symbol.kind,
            range: symbol.range,
            selection_range: symbol.selection_range
          )

          if parent = scope_stack.last?
            parent.children << node
          else
            root_symbols << node
          end

          if CONTAINER_KINDS.includes?(kind)
            scope_stack << node
            depth_stack << true
          elsif is_block_open
            # def, macro, etc. — opens a block but not a container
            depth_stack << false
          end
        elsif is_block_open
          # Block-opening keyword with no symbol match (if, begin, etc.)
          depth_stack << false
        end
      end

      root_symbols
    end

    # Returns flat symbol list (for workspace symbols and completion)
    def self.run_flat(document : Document) : Array(SymbolInfo)
      symbols = [] of SymbolInfo

      document.content.each_line.with_index do |line, line_num|
        if info = match_symbol(line, line_num)
          symbols << info
        end
      end

      symbols
    end

    # Match a single line against symbol patterns, returns SymbolInfo or nil
    def self.match_symbol(line : String, line_num : Int32) : SymbolInfo?
      PATTERNS.each do |pattern, kind|
        if match = pattern.match(line)
          name = if kind == SymbolKind::Method && match[1]? == "self."
                   "self.#{match[2]}"
                 elsif kind == SymbolKind::Method
                   match[2]? || match[1]
                 else
                   match[1]
                 end

          col = (line.index(name) || 0)
          pos = Position.new(line: line_num, character: col)
          end_pos = Position.new(line: line_num, character: col + name.size)
          range = Range.new(start: pos, end_pos: end_pos)

          return SymbolInfo.new(
            name: name,
            kind: kind.value,
            range: range,
            selection_range: range
          )
        end
      end

      # Constants (UPPER_CASE = ...)
      if match = CONSTANT_REGEX.match(line)
        name = match[1]
        col = (line.index(name) || 0)
        pos = Position.new(line: line_num, character: col)
        end_pos = Position.new(line: line_num, character: col + name.size)
        range = Range.new(start: pos, end_pos: end_pos)

        return SymbolInfo.new(
          name: name,
          kind: SymbolKind::Constant.value,
          range: range,
          selection_range: range
        )
      end

      nil
    end
  end
end
