module Lsp::Crystal::Providers
  module Definition
    def self.run(document : Document, line : Int32, character : Int32) : Array(Location)
      file_path = document.path
      # Convert 0-based LSP to 1-based Crystal
      result = CrystalTool.implementations(file_path, line + 1, character + 1)
      return [] of Location unless result.success

      begin
        json = JSON.parse(result.stdout)
      rescue
        return [] of Location
      end

      return [] of Location unless json["status"]?.try(&.as_s) == "ok"

      implementations = json["implementations"]?.try(&.as_a) || return [] of Location
      implementations.compact_map do |impl|
        filename = impl["filename"]?.try(&.as_s) || next
        impl_line = impl["line"]?.try(&.as_i) || next
        impl_col = impl["column"]?.try(&.as_i) || next
        impl_size = impl["size"]?.try(&.as_i) || 0

        Location.new(
          uri: URI.path_to_uri(filename),
          range: Range.new(
            start: Position.new(line: impl_line - 1, character: impl_col - 1),
            end_pos: Position.new(line: impl_line - 1, character: impl_col - 1 + impl_size)
          )
        )
      end
    end
  end
end
