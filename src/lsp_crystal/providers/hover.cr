module Lsp::Crystal::Providers
  module Hover
    struct HoverResult
      include JSON::Serializable

      property contents : MarkupContent

      def initialize(@contents)
      end
    end

    def self.run(document : Document, line : Int32, character : Int32) : HoverResult?
      file_path = document.path
      # Convert 0-based LSP to 1-based Crystal
      result = CrystalTool.context(file_path, line + 1, character + 1)
      return nil unless result.success

      begin
        json = JSON.parse(result.stdout)
      rescue
        return nil
      end

      return nil unless json["status"]?.try(&.as_s) == "ok"

      contexts = json["contexts"]?.try(&.as_a) || return nil
      return nil if contexts.empty?

      content = contexts.map { |c| c["context"].as_s }.join("\n")

      HoverResult.new(
        contents: MarkupContent.new(
          kind: "markdown",
          value: "```crystal\n#{content}\n```"
        )
      )
    end
  end
end
