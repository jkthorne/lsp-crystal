module Lsp::Crystal
  module AST
    # A symbol extracted from the AST with fully qualified name and hierarchy info
    struct IndexedSymbol
      property name : String
      property fqn : String
      property kind : Int32
      property range : Range
      property selection_range : Range
      property container_fqn : String?
      property superclass : String?
      property includes : Array(String)?
      property params : Array(String)?

      def initialize(@name, @fqn, @kind, @range, @selection_range,
                     @container_fqn = nil, @superclass = nil, @includes = nil, @params = nil)
      end
    end

    # A reference to a name found in the AST
    struct SymbolReference
      property name : String
      property uri : String
      property range : Range
      property kind : ReferenceKind

      def initialize(@name, @uri, @range, @kind)
      end
    end
  end
end
