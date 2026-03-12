module Lsp::Crystal::Providers
  module TypeDefinition
    def self.run(document : Document, line : Int32, character : Int32, workspace_root : String? = nil, workspace_index : WorkspaceIndex? = nil) : Array(Location)
      file_path = document.path

      # Use crystal tool context to get the type at cursor position
      result = CrystalTool.context(file_path, line + 1, character + 1)
      return [] of Location unless result.success

      begin
        json = JSON.parse(result.stdout)
      rescue
        return [] of Location
      end

      return [] of Location unless json["status"]?.try(&.as_s) == "ok"

      contexts = json["contexts"]?.try(&.as_a) || return [] of Location
      return [] of Location if contexts.empty?

      type_name = contexts.first["context"]?.try(&.as_s) || return [] of Location

      # Extract base type name (strip generics, unions, nilable)
      base_type = extract_base_type(type_name)
      return [] of Location if base_type.empty?

      # Search for the type definition in workspace
      find_type_definition(base_type, document, workspace_root, workspace_index)
    end

    private def self.extract_base_type(type_name : String) : String
      # Handle nilable: "String?" → "String"
      name = type_name.rstrip("?")
      # Handle generics: "Array(Int32)" → "Array"
      name = name.split("(").first
      # Handle unions: "String | Nil" → "String"
      name = name.split("|").first.strip
      # Handle namespaced: "Foo::Bar" → "Bar" (but keep for search)
      name
    end

    private def self.find_type_definition(type_name : String, document : Document, workspace_root : String?, workspace_index : WorkspaceIndex?) : Array(Location)
      locations = [] of Location
      # The short name for matching (last component after ::)
      short_name = type_name.split("::").last
      pattern = /^\s*(?:class|struct|module|enum|alias|annotation)\s+#{Regex.escape(short_name)}\b/

      # Search current document first
      document.content.each_line.with_index do |line_text, line_num|
        if pattern.match(line_text)
          col = line_text.index(short_name)
          next unless col
          locations << Location.new(
            uri: document.uri,
            range: Range.new(
              start: Position.new(line: line_num, character: col),
              end_pos: Position.new(line: line_num, character: col + short_name.size)
            )
          )
        end
      end

      # Search indexed workspace files
      if idx = workspace_index
        idx.search_type_definition(short_name) do |uri, line_num, col|
          next if uri == document.uri # Already searched
          locations << Location.new(
            uri: uri,
            range: Range.new(
              start: Position.new(line: line_num, character: col),
              end_pos: Position.new(line: line_num, character: col + short_name.size)
            )
          )
        end
      elsif root = workspace_root
        Dir.glob(File.join(root, "**", "*.cr")) do |file_path|
          next if file_path.includes?("/lib/") || file_path.includes?("/.crystal/")
          next if file_path == document.path

          content = File.read(file_path) rescue next
          uri = URI.path_to_uri(file_path)

          content.each_line.with_index do |line_text, line_num|
            if pattern.match(line_text)
              col = line_text.index(short_name)
              next unless col
              locations << Location.new(
                uri: uri,
                range: Range.new(
                  start: Position.new(line: line_num, character: col),
                  end_pos: Position.new(line: line_num, character: col + short_name.size)
                )
              )
            end
          end
        end
      end

      locations
    end
  end
end
