module Lsp::Crystal::Providers
  module InlayHints
    struct InlayHint
      include JSON::Serializable

      property position : Position
      property label : String
      property kind : Int32 # 1 = Type, 2 = Parameter
      @[JSON::Field(key: "paddingLeft")]
      property padding_left : Bool
      @[JSON::Field(key: "paddingRight")]
      property padding_right : Bool

      def initialize(@position, @label, @kind, @padding_left = false, @padding_right = false)
      end
    end

    TYPE_HINT    = 1
    PARAM_HINT   = 2

    # Variable assignment patterns where we can infer simple types
    LITERAL_TYPES = {
      /^\s*\w+\s*=\s*(\d+_?\d*)\s*$/                        => "Int32",
      /^\s*\w+\s*=\s*(\d+_?\d*_?[iI]8)\s*$/                 => "Int8",
      /^\s*\w+\s*=\s*(\d+_?\d*_?[iI]16)\s*$/                => "Int16",
      /^\s*\w+\s*=\s*(\d+_?\d*_?[iI]64)\s*$/                => "Int64",
      /^\s*\w+\s*=\s*(\d+_?\d*_?[iI]128)\s*$/               => "Int128",
      /^\s*\w+\s*=\s*(\d+_?\d*_?[uU]8)\s*$/                 => "UInt8",
      /^\s*\w+\s*=\s*(\d+_?\d*_?[uU]16)\s*$/                => "UInt16",
      /^\s*\w+\s*=\s*(\d+_?\d*_?[uU]32)\s*$/                => "UInt32",
      /^\s*\w+\s*=\s*(\d+_?\d*_?[uU]64)\s*$/                => "UInt64",
      /^\s*\w+\s*=\s*(\d+\.\d+)\s*$/                        => "Float64",
      /^\s*\w+\s*=\s*(\d+\.\d+_?[fF]32)\s*$/                => "Float32",
      /^\s*\w+\s*=\s*"[^"]*"\s*$/                            => "String",
      /^\s*\w+\s*=\s*'[^']*'\s*$/                            => "Char",
      /^\s*\w+\s*=\s*true\s*$/                               => "Bool",
      /^\s*\w+\s*=\s*false\s*$/                              => "Bool",
      /^\s*\w+\s*=\s*nil\s*$/                                => "Nil",
      /^\s*\w+\s*=\s*\[\]\s*of\s+(\w+(?:::\w+)*)\s*$/       => nil, # special: array
      /^\s*\w+\s*=\s*\{[^}]*\}\s*of\s+(\w+)\s*=>\s*(\w+)$/  => nil, # special: hash
      /^\s*\w+\s*=\s*(\w+(?:::\w+)*)\.new\b/                => nil, # special: constructor
    }

    # Returns inlay hints for the visible range
    def self.run(document : Document, range : Range) : Array(InlayHint)
      hints = [] of InlayHint

      start_line = range.start.line
      end_line = range.end_pos.line

      document.content.each_line.with_index do |line, line_num|
        next if line_num < start_line
        break if line_num > end_line

        add_type_hints(line, line_num, hints)
        add_param_hints(line, line_num, document, hints)
      end

      hints
    end

    private def self.add_type_hints(line : String, line_num : Int32, hints : Array(InlayHint)) : Nil
      stripped = line.strip
      # Skip lines with explicit type annotations
      return if stripped.includes?(" : ") && stripped.includes?("=")
      # Skip property/getter/setter (they have type annotations)
      return if stripped =~ /^\s*(?:property|getter|setter)/

      # Check for variable = literal
      if match = stripped.match(/^(\w+)\s*=\s*(.+)$/)
        var_name = match[1]
        # Skip constants (UPPER_CASE)
        return if var_name =~ /^[A-Z][A-Z0-9_]+$/
        # Skip if already has type annotation in surrounding context
        rhs = match[2].strip

        type_name = infer_type(stripped, rhs)
        if type_name
          # Place hint after the variable name
          col = line.index(var_name)
          return unless col
          pos = Position.new(line: line_num, character: col + var_name.size)
          hints << InlayHint.new(
            position: pos,
            label: ": #{type_name}",
            kind: TYPE_HINT,
            padding_left: true
          )
        end
      end
    end

    private def self.infer_type(full_line : String, rhs : String) : String?
      # Integer
      return "Int32" if rhs =~ /^\d[\d_]*$/
      return "Int64" if rhs =~ /^\d[\d_]*_?[iI]64$/
      return "Int8" if rhs =~ /^\d[\d_]*_?[iI]8$/
      return "Int16" if rhs =~ /^\d[\d_]*_?[iI]16$/
      return "Int128" if rhs =~ /^\d[\d_]*_?[iI]128$/
      return "UInt8" if rhs =~ /^\d[\d_]*_?[uU]8$/
      return "UInt16" if rhs =~ /^\d[\d_]*_?[uU]16$/
      return "UInt32" if rhs =~ /^\d[\d_]*_?[uU]32$/
      return "UInt64" if rhs =~ /^\d[\d_]*_?[uU]64$/

      # Float
      return "Float64" if rhs =~ /^\d[\d_]*\.\d[\d_]*$/
      return "Float32" if rhs =~ /^\d[\d_]*\.\d[\d_]*_?[fF]32$/

      # String
      return "String" if rhs =~ /^"[^"]*"$/

      # Char
      return "Char" if rhs =~ /^'[^']*'$/

      # Bool
      return "Bool" if rhs == "true" || rhs == "false"

      # Nil
      return "Nil" if rhs == "nil"

      # Symbol
      return "Symbol" if rhs =~ /^:\w+$/

      # Constructor call: Foo.new or Foo::Bar.new
      if match = rhs.match(/^(\w+(?:::\w+)*)\.new\b/)
        return match[1]
      end

      # Array literal with of
      if match = rhs.match(/^\[\]\s*of\s+(\w+(?:::\w+)*)$/)
        return "Array(#{match[1]})"
      end

      nil
    end

    private def self.add_param_hints(line : String, line_num : Int32, document : Document, hints : Array(InlayHint)) : Nil
      # Find method calls with positional arguments: method_name(arg1, arg2)
      line.scan(/\b(\w+[?!]?)\s*\(([^)]+)\)/) do |match|
        method_name = match[1]
        next if SemanticTokens::KEYWORDS.includes?(method_name)
        args_str = match[2]

        # Find method definition in document
        params = find_method_params(method_name, document)
        next if params.empty?

        # Parse arguments
        args = split_args(args_str)
        call_start = line.index(match[0]) || next

        arg_offset = call_start + method_name.size + 1 # skip past "method("
        args.each_with_index do |arg, idx|
          break if idx >= params.size
          param_name = params[idx]
          # Skip if arg is already a named argument
          next if arg.strip.includes?(":")
          # Skip if arg is just the param name
          next if arg.strip == param_name

          # Find the actual position of this arg in the line
          arg_col = line.index(arg.strip, arg_offset)
          next unless arg_col

          hints << InlayHint.new(
            position: Position.new(line: line_num, character: arg_col),
            label: "#{param_name}:",
            kind: PARAM_HINT,
            padding_right: true
          )
          arg_offset = arg_col + arg.strip.size
        end
      end
    end

    private def self.find_method_params(method_name : String, document : Document) : Array(String)
      document.content.each_line do |line|
        if match = line.match(/^\s*def\s+(?:self\.)?#{Regex.escape(method_name)}\s*\(([^)]*)\)/)
          return parse_params(match[1])
        end
      end
      [] of String
    end

    private def self.parse_params(params_str : String) : Array(String)
      params_str.split(",").map do |param|
        param = param.strip
        # Remove type annotation: "name : Type"
        param = param.split(":").first.strip
        # Remove default: "name = value"
        param = param.split("=").first.strip
        # Remove * and ** prefixes
        param = param.lstrip('*')
        param
      end.reject(&.empty?)
    end

    private def self.split_args(args_str : String) : Array(String)
      result = [] of String
      depth = 0
      current = ""
      args_str.each_char do |c|
        case c
        when '(', '[', '{' then depth += 1; current += c
        when ')', ']', '}' then depth -= 1; current += c
        when ','
          if depth == 0
            result << current
            current = ""
          else
            current += c
          end
        else
          current += c
        end
      end
      result << current unless current.empty?
      result
    end
  end
end
