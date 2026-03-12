module Lsp::Crystal::Providers
  module References
    MAX_RESULTS = 500

    # Find all references to the word at the given position across the workspace
    def self.run(document : Document, line : Int32, character : Int32, workspace_root : String?, include_declaration : Bool = true) : Array(Location)
      word = extract_word(document, line, character)
      return [] of Location if word.empty?

      results = [] of Location
      pattern = /\b#{Regex.escape(word)}\b/

      # Search current document first
      find_in_content(document.content, document.uri, pattern, results)

      # Search workspace files if we have a root
      if root = workspace_root
        current_path = URI.uri_to_path(document.uri)
        Dir.glob(File.join(root, "**", "*.cr")) do |file_path|
          break if results.size >= MAX_RESULTS
          next if file_path.includes?("/lib/") || file_path.includes?("/.crystal/")
          next if file_path == current_path # Already searched
          next if File.symlink?(file_path) && !URI.path_within_workspace?(file_path, root)

          content = begin
            File.read(file_path)
          rescue
            next
          end

          uri = URI.path_to_uri(file_path)
          find_in_content(content, uri, pattern, results)
        end
      end

      results
    end

    private def self.find_in_content(content : String, uri : String, pattern : Regex, results : Array(Location)) : Nil
      content.each_line.with_index do |text, line_num|
        return if results.size >= MAX_RESULTS
        offset = 0
        while match = pattern.match(text, offset)
          col = match.begin
          break unless col
          results << Location.new(
            uri: uri,
            range: Range.new(
              start: Position.new(line: line_num, character: col),
              end_pos: Position.new(line: line_num, character: col + match[0].size)
            )
          )
          offset = col + match[0].size
        end
      end
    end

    private def self.extract_word(document : Document, line : Int32, character : Int32) : String
      text = document.line_at(line)
      return "" unless text

      start_pos = character
      while start_pos > 0 && word_char?(text[start_pos - 1]?)
        start_pos -= 1
      end

      end_pos = character
      while end_pos < text.size && word_char?(text[end_pos]?)
        end_pos += 1
      end

      return "" if start_pos == end_pos
      text[start_pos...end_pos]
    end

    private def self.word_char?(char : Char?) : Bool
      return false unless char
      char.alphanumeric? || char == '_' || char == '?' || char == '!'
    end
  end
end
