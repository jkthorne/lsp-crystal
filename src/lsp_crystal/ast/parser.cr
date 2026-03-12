require "compiler/crystal/syntax"

module Lsp::Crystal
  module AST
    # Result of parsing — either a valid AST node or a syntax error
    class ParseResult
      getter node : ::Crystal::ASTNode?
      getter error : ::Crystal::SyntaxException?

      def initialize(@node : ::Crystal::ASTNode?, @error : ::Crystal::SyntaxException? = nil)
      end

      def success? : Bool
        !@node.nil?
      end
    end

    # Wraps Crystal::Parser, single import point for compiler/crystal/syntax
    def self.parse(source : String, filename : String = "") : ParseResult
      parser = ::Crystal::Parser.new(source)
      parser.filename = filename
      node = parser.parse
      ParseResult.new(node: node)
    rescue ex : ::Crystal::SyntaxException
      ParseResult.new(node: nil, error: ex)
    end

    # Convert Crystal 1-based location to LSP 0-based Position
    def self.to_lsp_position(location : ::Crystal::Location?) : Position?
      return nil unless location
      Position.new(
        line: location.line_number - 1,
        character: location.column_number - 1
      )
    end

    # Build an LSP Range from a node's location and end_location
    def self.to_lsp_range(node : ::Crystal::ASTNode) : Range?
      start_pos = to_lsp_position(node.location)
      end_pos = to_lsp_position(node.end_location)
      return nil unless start_pos && end_pos
      Range.new(start: start_pos, end_pos: end_pos)
    end

    # Build a selection range (just the name portion) given a location and name length
    def self.name_range(location : ::Crystal::Location?, name_length : Int32) : Range?
      start_pos = to_lsp_position(location)
      return nil unless start_pos
      end_pos = Position.new(line: start_pos.line, character: start_pos.character + name_length)
      Range.new(start: start_pos, end_pos: end_pos)
    end
  end
end
