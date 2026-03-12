module Lsp::Crystal
  module AST
    # Determines AST context at a cursor position
    # Used by completion for better local variable and parameter suggestions
    struct CursorContext
      property in_class : String?
      property in_method : String?
      property local_vars : Array(String)
      property method_params : Array(String)
      property instance_vars : Array(String)

      def initialize
        @in_class = nil
        @in_method = nil
        @local_vars = [] of String
        @method_params = [] of String
        @instance_vars = [] of String
      end
    end

    class ContextVisitor < ::Crystal::Visitor
      getter context : CursorContext

      def initialize(@target_line : Int32, @target_col : Int32)
        @context = CursorContext.new
        @found = false
      end

      def visit(node : ::Crystal::ClassDef) : Bool
        return false if @found
        if contains_cursor?(node)
          @context.in_class = node.name.to_s
          true
        else
          false
        end
      end

      def visit(node : ::Crystal::ModuleDef) : Bool
        return false if @found
        contains_cursor?(node)
      end

      def visit(node : ::Crystal::Def) : Bool
        return false if @found
        if contains_cursor?(node)
          @context.in_method = node.name
          node.args.each do |arg|
            @context.method_params << arg.name
          end
          true
        else
          false
        end
      end

      def visit(node : ::Crystal::Var) : Bool
        return false if @found
        if before_cursor?(node)
          name = node.name
          unless @context.local_vars.includes?(name) || @context.method_params.includes?(name)
            @context.local_vars << name
          end
        end
        false
      end

      def visit(node : ::Crystal::InstanceVar) : Bool
        return false if @found
        if before_cursor?(node)
          name = node.name
          @context.instance_vars << name unless @context.instance_vars.includes?(name)
        end
        false
      end

      def visit(node : ::Crystal::Assign) : Bool
        return false if @found
        if before_cursor?(node)
          case target = node.target
          when ::Crystal::Var
            name = target.name
            unless @context.local_vars.includes?(name)
              @context.local_vars << name
            end
          when ::Crystal::InstanceVar
            name = target.name
            @context.instance_vars << name unless @context.instance_vars.includes?(name)
          end
        end
        true
      end

      def visit(node : ::Crystal::ASTNode) : Bool
        !@found
      end

      private def contains_cursor?(node : ::Crystal::ASTNode) : Bool
        start_loc = node.location
        end_loc = node.end_location
        return false unless start_loc && end_loc

        start_line = start_loc.line_number - 1
        end_line = end_loc.line_number - 1

        @target_line >= start_line && @target_line <= end_line
      end

      private def before_cursor?(node : ::Crystal::ASTNode) : Bool
        loc = node.location
        return false unless loc
        line = loc.line_number - 1
        col = loc.column_number - 1
        line < @target_line || (line == @target_line && col < @target_col)
      end
    end
  end
end
