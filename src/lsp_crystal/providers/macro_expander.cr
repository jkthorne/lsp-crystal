module Lsp::Crystal::Providers
  module MacroExpander
    enum MethodKind
      Getter
      Setter
      Method
      Constructor
    end

    struct MacroMethod
      property name : String
      property type : String?
      property kind : MethodKind
      property owner_type : String?
      property line : Int32

      def initialize(@name, @type = nil, @kind = MethodKind::Method, @owner_type = nil, @line = 0)
      end

      def signature : String
        case kind
        when .getter?
          type ? "def #{name} : #{type}" : "def #{name}"
        when .setter?
          type ? "def #{name}=(value : #{type})" : "def #{name}=(value)"
        when .constructor?
          "def initialize(#{name})"
        else
          type ? "def #{name} : #{type}" : "def #{name}"
        end
      end
    end

    # Expand known Crystal macros into their generated methods.
    # Returns synthetic methods for property, getter, setter, record, etc.
    def self.expand(macro_name : String, args : Array(String), type_hints : Array(String?), container : String? = nil, line : Int32 = 0) : Array(MacroMethod)
      methods = [] of MacroMethod

      case macro_name
      when "property"
        args.each_with_index do |arg, i|
          type = type_hints[i]?
          methods << MacroMethod.new(name: arg, type: type, kind: MethodKind::Getter, owner_type: container, line: line)
          methods << MacroMethod.new(name: "#{arg}=", type: type, kind: MethodKind::Setter, owner_type: container, line: line)
        end
      when "property?"
        args.each_with_index do |arg, i|
          type = type_hints[i]?
          methods << MacroMethod.new(name: "#{arg}?", type: type || "Bool", kind: MethodKind::Getter, owner_type: container, line: line)
          methods << MacroMethod.new(name: "#{arg}=", type: type || "Bool", kind: MethodKind::Setter, owner_type: container, line: line)
        end
      when "property!"
        args.each_with_index do |arg, i|
          type = type_hints[i]?
          methods << MacroMethod.new(name: arg, type: type, kind: MethodKind::Getter, owner_type: container, line: line)
          methods << MacroMethod.new(name: "#{arg}?", type: type ? "#{type}?" : "Bool", kind: MethodKind::Getter, owner_type: container, line: line)
          methods << MacroMethod.new(name: "#{arg}=", type: type, kind: MethodKind::Setter, owner_type: container, line: line)
        end
      when "getter"
        args.each_with_index do |arg, i|
          type = type_hints[i]?
          methods << MacroMethod.new(name: arg, type: type, kind: MethodKind::Getter, owner_type: container, line: line)
        end
      when "getter?"
        args.each_with_index do |arg, i|
          type = type_hints[i]?
          methods << MacroMethod.new(name: "#{arg}?", type: type || "Bool", kind: MethodKind::Getter, owner_type: container, line: line)
        end
      when "getter!"
        args.each_with_index do |arg, i|
          type = type_hints[i]?
          methods << MacroMethod.new(name: arg, type: type, kind: MethodKind::Getter, owner_type: container, line: line)
          methods << MacroMethod.new(name: "#{arg}?", type: type ? "#{type}?" : "Bool", kind: MethodKind::Getter, owner_type: container, line: line)
        end
      when "setter"
        args.each_with_index do |arg, i|
          type = type_hints[i]?
          methods << MacroMethod.new(name: "#{arg}=", type: type, kind: MethodKind::Setter, owner_type: container, line: line)
        end
      when "record"
        # First arg is the type name, rest are fields
        if args.size > 0
          record_name = args[0]
          field_args = args[1..]
          field_types = type_hints[1..]? || [] of String?
          # Generate getters for each field
          field_args.each_with_index do |field, i|
            type = field_types[i]?
            methods << MacroMethod.new(name: field, type: type, kind: MethodKind::Getter, owner_type: record_name, line: line)
          end
          # Generate initialize
          init_params = field_args.map_with_index { |f, i|
            t = field_types[i]?
            t ? "@#{f} : #{t}" : "@#{f}"
          }.join(", ")
          methods << MacroMethod.new(name: "initialize", type: nil, kind: MethodKind::Constructor, owner_type: record_name, line: line)
        end
      end

      methods
    end

    # Extract macro arguments from an AST Call node
    def self.expand_from_call(node : ::Crystal::Call, container : String? = nil) : Array(MacroMethod)
      macro_name = node.name
      args = [] of String
      type_hints = [] of String?
      line = node.location.try(&.line_number) || 0

      node.args.each do |arg|
        case arg
        when ::Crystal::Var
          args << arg.name
          type_hints << nil
        when ::Crystal::TypeDeclaration
          args << arg.var.to_s
          type_hints << arg.declared_type.to_s
        when ::Crystal::Path
          args << arg.to_s
          type_hints << nil
        when ::Crystal::StringLiteral
          args << arg.value
          type_hints << nil
        end
      end

      expand(macro_name, args, type_hints, container, line)
    end

    # Check if a macro call name is one we know how to expand
    def self.known_macro?(name : String) : Bool
      name.in?("property", "property?", "property!", "getter", "getter?", "getter!", "setter", "record")
    end

    # Generate hover documentation for a known macro call
    def self.hover_info(macro_name : String, args : Array(String), type_hints : Array(String?)) : String?
      methods = expand(macro_name, args, type_hints)
      return nil if methods.empty?

      lines = ["Expands to:"]
      methods.each do |m|
        lines << "- `#{m.signature}`"
      end
      lines.join("\n")
    end
  end
end
