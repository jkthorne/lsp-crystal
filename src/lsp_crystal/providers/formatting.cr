module Lsp::Crystal::Providers
  module Formatting
    def self.run(document : Document) : Array(TextEdit)?
      result = CrystalTool.format(document.content)
      return nil unless result.success

      formatted = result.stdout
      return nil if formatted == document.content

      # Single edit replacing entire document
      [TextEdit.new(
        range: Range.new(
          start: Position.new(line: 0, character: 0),
          end_pos: document.end_position
        ),
        new_text: formatted
      )]
    end
  end
end
