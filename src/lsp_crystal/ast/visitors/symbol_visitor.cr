module Lsp::Crystal
  module AST
    class SymbolVisitor < ::Crystal::Visitor
      alias HierarchicalSymbolInfo = Providers::DocumentSymbol::HierarchicalSymbolInfo
      alias SymbolKind = Providers::DocumentSymbol::SymbolKind

      getter root_symbols : Array(HierarchicalSymbolInfo)

      def initialize
        @root_symbols = [] of HierarchicalSymbolInfo
        @scope_stack = [] of HierarchicalSymbolInfo
      end

      def visit(node : ::Crystal::ClassDef) : Bool
        kind = node.struct? ? SymbolKind::Struct : SymbolKind::Class
        name = node.name.to_s
        push_symbol(name, kind, node)
        true
      end

      def end_visit(node : ::Crystal::ClassDef) : Nil
        pop_symbol(node)
      end

      def visit(node : ::Crystal::ModuleDef) : Bool
        push_symbol(node.name.to_s, SymbolKind::Module, node)
        true
      end

      def end_visit(node : ::Crystal::ModuleDef) : Nil
        pop_symbol(node)
      end

      def visit(node : ::Crystal::EnumDef) : Bool
        push_symbol(node.name.to_s, SymbolKind::Enum, node)
        true
      end

      def end_visit(node : ::Crystal::EnumDef) : Nil
        pop_symbol(node)
      end

      def visit(node : ::Crystal::Def) : Bool
        name = node.name
        name = "self.#{name}" if node.receiver.is_a?(::Crystal::Var) && node.receiver.as(::Crystal::Var).name == "self"
        add_symbol(name, SymbolKind::Method, node)
        false # don't visit children of def for symbols
      end

      def visit(node : ::Crystal::Macro) : Bool
        add_symbol(node.name, SymbolKind::Function, node)
        false
      end

      def visit(node : ::Crystal::Alias) : Bool
        add_symbol(node.name.to_s, SymbolKind::TypeParameter, node)
        false
      end

      def visit(node : ::Crystal::AnnotationDef) : Bool
        add_symbol(node.name.to_s, SymbolKind::Interface, node)
        false
      end

      def visit(node : ::Crystal::Assign) : Bool
        if node.target.is_a?(::Crystal::Path)
          name = node.target.as(::Crystal::Path).names.join("::")
          # Only treat as constant if name starts with uppercase
          if name[0]?.try(&.uppercase?)
            add_symbol(name, SymbolKind::Constant, node)
          end
        end
        false
      end

      def visit(node : ::Crystal::Call) : Bool
        # Detect property/getter/setter macro calls
        if Providers::MacroExpander.known_macro?(node.name)
          container = @scope_stack.last?.try(&.name)
          # Add the property symbol for each arg
          node.args.each do |arg|
            case arg
            when ::Crystal::Var
              add_symbol(arg.name, SymbolKind::Property, node)
            when ::Crystal::TypeDeclaration
              add_symbol(arg.var.to_s, SymbolKind::Property, node)
            end
          end
          # Add synthetic method symbols from macro expansion
          methods = Providers::MacroExpander.expand_from_call(node, container)
          methods.each do |m|
            case m.kind
            when .setter?
              add_symbol(m.name, SymbolKind::Method, node)
            when .constructor?
              add_symbol(m.name, SymbolKind::Method, node)
            end
          end
          return false
        end
        true
      end

      def visit(node : ::Crystal::ASTNode) : Bool
        true
      end

      private def push_symbol(name : String, kind : SymbolKind, node : ::Crystal::ASTNode) : Nil
        sym = make_symbol(name, kind, node)
        return unless sym
        if parent = @scope_stack.last?
          parent.children << sym
        else
          @root_symbols << sym
        end
        @scope_stack << sym
      end

      private def pop_symbol(node : ::Crystal::ASTNode) : Nil
        return if @scope_stack.empty?
        closed = @scope_stack.pop
        # Update range end from node's end_location
        if end_pos = AST.to_lsp_position(node.end_location)
          closed.range = Range.new(start: closed.range.start, end_pos: end_pos)
        end
      end

      private def add_symbol(name : String, kind : SymbolKind, node : ::Crystal::ASTNode) : Nil
        sym = make_symbol(name, kind, node)
        return unless sym
        if parent = @scope_stack.last?
          parent.children << sym
        else
          @root_symbols << sym
        end
      end

      private def make_symbol(name : String, kind : SymbolKind, node : ::Crystal::ASTNode) : HierarchicalSymbolInfo?
        range = AST.to_lsp_range(node)
        return nil unless range

        # Selection range is just the name portion
        sel_range = AST.name_range(node.location, name.size) || range

        HierarchicalSymbolInfo.new(
          name: name,
          kind: kind.value,
          range: range,
          selection_range: sel_range
        )
      end
    end
  end
end
