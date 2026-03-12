module Lsp::Crystal
  module AST
    class IndexVisitor < ::Crystal::Visitor
      getter symbols : Array(IndexedSymbol)
      getter references : Array(SymbolReference)

      def initialize(@uri : String)
        @symbols = [] of IndexedSymbol
        @references = [] of SymbolReference
        @scope_stack = [] of String # FQN scope stack
        @include_stack = [] of Array(String) # includes per scope level
      end

      def visit(node : ::Crystal::ClassDef) : Bool
        name = node.name.to_s
        fqn = push_scope(name)
        kind = node.struct? ? Providers::DocumentSymbol::SymbolKind::Struct : Providers::DocumentSymbol::SymbolKind::Class
        superclass = node.superclass.try(&.to_s)
        @include_stack << [] of String

        range = AST.to_lsp_range(node)
        sel_range = AST.name_range(node.location, name.size)
        if range && sel_range
          @symbols << IndexedSymbol.new(
            name: name, fqn: fqn, kind: kind.value,
            range: range, selection_range: sel_range,
            container_fqn: container_fqn, superclass: superclass
          )
          add_reference(name, node, ReferenceKind::Definition)
        end
        true
      end

      def end_visit(node : ::Crystal::ClassDef) : Nil
        # Attach includes to the symbol we're closing
        includes = @include_stack.pop?
        if includes && !includes.empty?
          update_last_type_symbol_includes(includes)
        end
        pop_scope
      end

      def visit(node : ::Crystal::ModuleDef) : Bool
        name = node.name.to_s
        fqn = push_scope(name)
        @include_stack << [] of String

        range = AST.to_lsp_range(node)
        sel_range = AST.name_range(node.location, name.size)
        if range && sel_range
          @symbols << IndexedSymbol.new(
            name: name, fqn: fqn, kind: Providers::DocumentSymbol::SymbolKind::Module.value,
            range: range, selection_range: sel_range,
            container_fqn: container_fqn
          )
          add_reference(name, node, ReferenceKind::Definition)
        end
        true
      end

      def end_visit(node : ::Crystal::ModuleDef) : Nil
        includes = @include_stack.pop?
        if includes && !includes.empty?
          update_last_type_symbol_includes(includes)
        end
        pop_scope
      end

      def visit(node : ::Crystal::EnumDef) : Bool
        name = node.name.to_s
        fqn = push_scope(name)
        @include_stack << [] of String

        range = AST.to_lsp_range(node)
        sel_range = AST.name_range(node.location, name.size)
        if range && sel_range
          @symbols << IndexedSymbol.new(
            name: name, fqn: fqn, kind: Providers::DocumentSymbol::SymbolKind::Enum.value,
            range: range, selection_range: sel_range,
            container_fqn: container_fqn
          )
          add_reference(name, node, ReferenceKind::Definition)
        end
        true
      end

      def end_visit(node : ::Crystal::EnumDef) : Nil
        @include_stack.pop?
        pop_scope
      end

      def visit(node : ::Crystal::Def) : Bool
        name = node.name
        name = "self.#{name}" if node.receiver.is_a?(::Crystal::Var) && node.receiver.as(::Crystal::Var).name == "self"
        fqn = current_fqn.empty? ? name : "#{current_fqn}##{name}"

        params = node.args.map(&.name)

        range = AST.to_lsp_range(node)
        sel_range = AST.name_range(node.location, name.size)
        if range && sel_range
          @symbols << IndexedSymbol.new(
            name: name, fqn: fqn, kind: Providers::DocumentSymbol::SymbolKind::Method.value,
            range: range, selection_range: sel_range,
            container_fqn: container_fqn, params: params.empty? ? nil : params
          )
          add_reference(name, node, ReferenceKind::Definition)
        end

        # Visit args as write references
        node.args.each do |arg|
          add_reference(arg.name, arg, ReferenceKind::Write)
        end

        true # visit body for references
      end

      def visit(node : ::Crystal::Macro) : Bool
        name = node.name
        fqn = current_fqn.empty? ? name : "#{current_fqn}##{name}"

        range = AST.to_lsp_range(node)
        sel_range = AST.name_range(node.location, name.size)
        if range && sel_range
          @symbols << IndexedSymbol.new(
            name: name, fqn: fqn, kind: Providers::DocumentSymbol::SymbolKind::Function.value,
            range: range, selection_range: sel_range,
            container_fqn: container_fqn
          )
          add_reference(name, node, ReferenceKind::Definition)
        end
        false
      end

      def visit(node : ::Crystal::Alias) : Bool
        name = node.name.to_s
        fqn = current_fqn.empty? ? name : "#{current_fqn}::#{name}"

        range = AST.to_lsp_range(node)
        sel_range = AST.name_range(node.location, name.size)
        if range && sel_range
          @symbols << IndexedSymbol.new(
            name: name, fqn: fqn, kind: Providers::DocumentSymbol::SymbolKind::TypeParameter.value,
            range: range, selection_range: sel_range,
            container_fqn: container_fqn
          )
          add_reference(name, node, ReferenceKind::Definition)
        end
        false
      end

      def visit(node : ::Crystal::Assign) : Bool
        if node.target.is_a?(::Crystal::Path)
          name = node.target.as(::Crystal::Path).names.join("::")
          if name[0]?.try(&.uppercase?)
            fqn = current_fqn.empty? ? name : "#{current_fqn}::#{name}"
            range = AST.to_lsp_range(node)
            sel_range = AST.name_range(node.target.location, name.size)
            if range && sel_range
              @symbols << IndexedSymbol.new(
                name: name, fqn: fqn, kind: Providers::DocumentSymbol::SymbolKind::Constant.value,
                range: range, selection_range: sel_range,
                container_fqn: container_fqn
              )
            end
            add_reference(name, node.target, ReferenceKind::Write)
          end
        end
        # Visit value side for references
        case target = node.target
        when ::Crystal::Var
          add_reference(target.name, target, ReferenceKind::Write)
        when ::Crystal::InstanceVar
          add_reference(target.name, target, ReferenceKind::Write)
        end
        node.value.accept(self)
        false
      end

      def visit(node : ::Crystal::Include) : Bool
        if inc_list = @include_stack.last?
          inc_list << node.name.to_s
        end
        false
      end

      def visit(node : ::Crystal::Extend) : Bool
        if inc_list = @include_stack.last?
          inc_list << node.name.to_s
        end
        false
      end

      def visit(node : ::Crystal::Call) : Bool
        # Detect known macro calls for synthetic methods
        if Providers::MacroExpander.known_macro?(node.name)
          container = current_fqn.empty? ? nil : current_fqn
          methods = Providers::MacroExpander.expand_from_call(node, container)
          methods.each do |m|
            method_fqn = container ? "#{container}##{m.name}" : m.name
            range = AST.to_lsp_range(node)
            sel_range = AST.name_range(node.location, m.name.size)
            if range && sel_range
              @symbols << IndexedSymbol.new(
                name: m.name, fqn: method_fqn,
                kind: Providers::DocumentSymbol::SymbolKind::Method.value,
                range: range, selection_range: sel_range,
                container_fqn: container
              )
            end
          end
        end

        add_reference(node.name, node, ReferenceKind::Read)
        true
      end

      def visit(node : ::Crystal::Var) : Bool
        add_reference(node.name, node, ReferenceKind::Read)
        false
      end

      def visit(node : ::Crystal::InstanceVar) : Bool
        add_reference(node.name, node, ReferenceKind::Read)
        false
      end

      def visit(node : ::Crystal::ClassVar) : Bool
        add_reference(node.name, node, ReferenceKind::Read)
        false
      end

      def visit(node : ::Crystal::Path) : Bool
        name = node.names.last
        add_reference(name, node, ReferenceKind::Read)
        false
      end

      def visit(node : ::Crystal::TypeDeclaration) : Bool
        case var = node.var
        when ::Crystal::Var
          add_reference(var.name, var, ReferenceKind::Write)
        when ::Crystal::InstanceVar
          add_reference(var.name, var, ReferenceKind::Write)
        when ::Crystal::ClassVar
          add_reference(var.name, var, ReferenceKind::Write)
        end
        false
      end

      def visit(node : ::Crystal::ASTNode) : Bool
        true
      end

      private def push_scope(name : String) : String
        fqn = current_fqn.empty? ? name : "#{current_fqn}::#{name}"
        @scope_stack << fqn
        fqn
      end

      private def pop_scope : Nil
        @scope_stack.pop? if @scope_stack.any?
      end

      private def current_fqn : String
        @scope_stack.last? || ""
      end

      private def container_fqn : String?
        @scope_stack.last?
      end

      private def add_reference(name : String, node : ::Crystal::ASTNode, kind : ReferenceKind) : Nil
        pos = AST.to_lsp_position(node.location)
        return unless pos
        range = Range.new(
          start: pos,
          end_pos: Position.new(line: pos.line, character: pos.character + name.size)
        )
        @references << SymbolReference.new(name: name, uri: @uri, range: range, kind: kind)
      end

      private def update_last_type_symbol_includes(includes : Array(String)) : Nil
        # Find the most recent type symbol that matches the scope we're closing
        # Must replace entire element since IndexedSymbol is a struct (value type)
        fqn = current_fqn
        (@symbols.size - 1).downto(0) do |i|
          sym = @symbols[i]
          if sym.fqn == fqn
            updated = IndexedSymbol.new(
              name: sym.name, fqn: sym.fqn, kind: sym.kind,
              range: sym.range, selection_range: sym.selection_range,
              container_fqn: sym.container_fqn, superclass: sym.superclass,
              includes: includes, params: sym.params
            )
            @symbols[i] = updated
            break
          end
        end
      end
    end
  end
end
