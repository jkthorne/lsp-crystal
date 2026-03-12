module Lsp::Crystal
  module AST
    # Finds all Call nodes in a method body
    # Used for accurate outgoing call hierarchy
    struct CallInfo
      property name : String
      property range : Range

      def initialize(@name, @range)
      end
    end

    class CallVisitor < ::Crystal::Visitor
      getter calls : Array(CallInfo)

      def initialize(@skip_name : String? = nil)
        @calls = [] of CallInfo
        @seen = Set(String).new
      end

      def visit(node : ::Crystal::Call) : Bool
        name = node.name
        # Skip recursive calls and operators
        return true if name == @skip_name
        return true if name.size <= 1 && !name[0].letter?

        pos = AST.to_lsp_position(node.location)
        if pos
          range = Range.new(
            start: pos,
            end_pos: Position.new(line: pos.line, character: pos.character + name.size)
          )
          @calls << CallInfo.new(name: name, range: range)
        end
        true
      end

      def visit(node : ::Crystal::ASTNode) : Bool
        true
      end

      # Get unique call names
      def unique_calls : Array(CallInfo)
        seen = Set(String).new
        @calls.select { |c| seen.add?(c.name) ? true : false }
      end
    end
  end
end
