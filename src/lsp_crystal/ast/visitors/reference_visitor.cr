module Lsp::Crystal
  module AST
    # Represents a reference to an identifier in the source
    struct ReferenceInfo
      property name : String
      property range : Range
      property kind : ReferenceKind

      def initialize(@name, @range, @kind)
      end
    end

    enum ReferenceKind
      Definition
      Read
      Write
    end

    class ReferenceVisitor < ::Crystal::Visitor
      getter references : Array(ReferenceInfo)

      def initialize(@target_name : String? = nil)
        @references = [] of ReferenceInfo
      end

      def visit(node : ::Crystal::Var) : Bool
        add_ref(node.name, node, ReferenceKind::Read)
        false
      end

      def visit(node : ::Crystal::InstanceVar) : Bool
        add_ref(node.name, node, ReferenceKind::Read)
        false
      end

      def visit(node : ::Crystal::ClassVar) : Bool
        add_ref(node.name, node, ReferenceKind::Read)
        false
      end

      def visit(node : ::Crystal::Def) : Bool
        add_ref(node.name, node, ReferenceKind::Definition)
        # Visit args as writes
        node.args.each do |arg|
          add_ref(arg.name, arg, ReferenceKind::Write)
        end
        true
      end

      def visit(node : ::Crystal::Macro) : Bool
        add_ref(node.name, node, ReferenceKind::Definition)
        false
      end

      def visit(node : ::Crystal::ClassDef) : Bool
        name = node.name.to_s
        add_ref_with_name(name, node, ReferenceKind::Definition)
        true
      end

      def visit(node : ::Crystal::ModuleDef) : Bool
        name = node.name.to_s
        add_ref_with_name(name, node, ReferenceKind::Definition)
        true
      end

      def visit(node : ::Crystal::EnumDef) : Bool
        name = node.name.to_s
        add_ref_with_name(name, node, ReferenceKind::Definition)
        true
      end

      def visit(node : ::Crystal::Assign) : Bool
        # The target of assignment is a write
        case target = node.target
        when ::Crystal::Var
          add_ref(target.name, target, ReferenceKind::Write)
        when ::Crystal::InstanceVar
          add_ref(target.name, target, ReferenceKind::Write)
        when ::Crystal::ClassVar
          add_ref(target.name, target, ReferenceKind::Write)
        when ::Crystal::Path
          add_ref_with_name(target.names.join("::"), target, ReferenceKind::Write)
        end
        # Visit value side
        node.value.accept(self)
        false
      end

      def visit(node : ::Crystal::OpAssign) : Bool
        # target op= value — target is both read and write
        case target = node.target
        when ::Crystal::Var
          add_ref(target.name, target, ReferenceKind::Write)
        when ::Crystal::InstanceVar
          add_ref(target.name, target, ReferenceKind::Write)
        when ::Crystal::ClassVar
          add_ref(target.name, target, ReferenceKind::Write)
        end
        node.value.accept(self)
        false
      end

      def visit(node : ::Crystal::Call) : Bool
        add_ref(node.name, node, ReferenceKind::Read)
        true
      end

      def visit(node : ::Crystal::Path) : Bool
        name = node.names.last
        add_ref_with_name(name, node, ReferenceKind::Read)
        false
      end

      def visit(node : ::Crystal::TypeDeclaration) : Bool
        case var = node.var
        when ::Crystal::Var
          add_ref(var.name, var, ReferenceKind::Write)
        when ::Crystal::InstanceVar
          add_ref(var.name, var, ReferenceKind::Write)
        when ::Crystal::ClassVar
          add_ref(var.name, var, ReferenceKind::Write)
        end
        false
      end

      def visit(node : ::Crystal::ASTNode) : Bool
        true
      end

      # Get all references matching a specific name
      def references_for(name : String) : Array(ReferenceInfo)
        @references.select { |r| r.name == name }
      end

      private def add_ref(name : String, node : ::Crystal::ASTNode, kind : ReferenceKind) : Nil
        return if @target_name && name != @target_name
        pos = AST.to_lsp_position(node.location)
        return unless pos
        range = Range.new(
          start: pos,
          end_pos: Position.new(line: pos.line, character: pos.character + name.size)
        )
        @references << ReferenceInfo.new(name: name, range: range, kind: kind)
      end

      private def add_ref_with_name(name : String, node : ::Crystal::ASTNode, kind : ReferenceKind) : Nil
        return if @target_name && name != @target_name
        pos = AST.to_lsp_position(node.location)
        return unless pos
        range = Range.new(
          start: pos,
          end_pos: Position.new(line: pos.line, character: pos.character + name.size)
        )
        @references << ReferenceInfo.new(name: name, range: range, kind: kind)
      end
    end
  end
end
