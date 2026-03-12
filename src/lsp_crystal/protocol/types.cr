require "json"

module Lsp::Crystal
  struct Position
    include JSON::Serializable

    property line : Int32
    property character : Int32

    def initialize(@line, @character)
    end
  end

  struct Range
    include JSON::Serializable

    @[JSON::Field(key: "start")]
    property start : Position

    @[JSON::Field(key: "end")]
    property end_pos : Position

    def initialize(@start, @end_pos)
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "start" { @start.to_json(json) }
        json.field "end" { @end_pos.to_json(json) }
      end
    end
  end

  struct Location
    include JSON::Serializable

    property uri : String
    property range : Range

    def initialize(@uri, @range)
    end
  end

  struct TextEdit
    include JSON::Serializable

    property range : Range

    @[JSON::Field(key: "newText")]
    property new_text : String

    def initialize(@range, @new_text)
    end
  end

  struct MarkupContent
    include JSON::Serializable

    property kind : String
    property value : String

    def initialize(@kind, @value)
    end
  end

  struct ReferenceContext
    include JSON::Serializable

    @[JSON::Field(key: "includeDeclaration")]
    property include_declaration : Bool

    def initialize(@include_declaration = true)
    end
  end

  struct WorkspaceEdit
    include JSON::Serializable

    property changes : Hash(String, Array(TextEdit))

    @[JSON::Field(key: "documentChanges")]
    property document_changes : Array(JSON::Any)?

    def initialize(@changes = Hash(String, Array(TextEdit)).new, @document_changes = nil)
    end
  end

  struct Command
    include JSON::Serializable

    property title : String
    property command : String
    property arguments : Array(JSON::Any)?

    def initialize(@title, @command, @arguments = nil)
    end
  end

  struct CodeAction
    include JSON::Serializable

    property title : String
    property kind : String?
    property edit : WorkspaceEdit?
    property command : Command?

    def initialize(@title, @kind = nil, @edit = nil, @command = nil)
    end
  end
end
