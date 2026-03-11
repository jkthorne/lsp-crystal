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

    CONSTANT_REGEX = /^\s*([A-Z][A-Z0-9_]+)\s*=/

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

    def self.run(document : Document) : Array(SymbolInfo)
      symbols = [] of SymbolInfo

      document.content.each_line.with_index do |line, line_num|
        PATTERNS.each do |pattern, kind|
          if match = pattern.match(line)
            # For `def self.name`, the capture group setup differs
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

            symbols << SymbolInfo.new(
              name: name,
              kind: kind.value,
              range: range,
              selection_range: range
            )
            break # Only match first pattern per line
          end
        end

        # Constants (UPPER_CASE = ...)
        if match = CONSTANT_REGEX.match(line)
          name = match[1]
          col = (line.index(name) || 0)
          pos = Position.new(line: line_num, character: col)
          end_pos = Position.new(line: line_num, character: col + name.size)
          range = Range.new(start: pos, end_pos: end_pos)

          symbols << SymbolInfo.new(
            name: name,
            kind: SymbolKind::Constant.value,
            range: range,
            selection_range: range
          )
        end
      end

      symbols
    end
  end
end
