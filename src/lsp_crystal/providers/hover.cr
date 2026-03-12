module Lsp::Crystal::Providers
  module Hover
    struct HoverResult
      include JSON::Serializable

      property contents : MarkupContent

      def initialize(@contents)
      end
    end

    def self.run(document : Document, line : Int32, character : Int32, ast_index : AST::Index? = nil) : HoverResult?
      # Check if cursor is on a known macro call — instant, no subprocess
      macro_hover = check_macro_hover(document, line, character)
      return macro_hover if macro_hover

      file_path = document.path
      # Convert 0-based LSP to 1-based Crystal
      result = CrystalTool.context(file_path, line + 1, character + 1)

      if result.success
        begin
          json = JSON.parse(result.stdout)
        rescue
          json = nil
        end

        if json && json["status"]?.try(&.as_s) == "ok"
          contexts = json["contexts"]?.try(&.as_a)
          if contexts && !contexts.empty?
            content = contexts.map { |c| c["context"].as_s }.join("\n")

            # Try AST index for doc comment lookup (faster than crystal tool)
            doc_comment = if idx = ast_index
                           find_doc_comment_via_index(document, line, character, idx)
                         end
            doc_comment ||= find_doc_comment(document, line, character)

            value = String.build do |str|
              str << "```crystal\n#{content}\n```"
              if doc_comment && !doc_comment.empty?
                str << "\n\n---\n\n#{doc_comment}"
              end
            end

            return HoverResult.new(
              contents: MarkupContent.new(kind: "markdown", value: value)
            )
          end
        end
      end

      nil
    end

    # Extract doc comments from definition site
    private def self.find_doc_comment(document : Document, line : Int32, character : Int32) : String?
      # Try to find where the symbol is defined
      impl_result = CrystalTool.implementations(document.path, line + 1, character + 1)
      return nil unless impl_result.success

      begin
        json = JSON.parse(impl_result.stdout)
      rescue
        return nil
      end

      return nil unless json["status"]?.try(&.as_s) == "ok"
      implementations = json["implementations"]?.try(&.as_a) || return nil
      return nil if implementations.empty?

      impl = implementations.first
      filename = impl["filename"]?.try(&.as_s) || return nil
      impl_line = impl["line"]?.try(&.as_i) || return nil

      extract_comments_above(filename, impl_line - 1)
    end

    # Check if the cursor is on a known macro call and show expansion info
    private def self.check_macro_hover(document : Document, line : Int32, character : Int32) : HoverResult?
      text = document.line_at(line)
      return nil unless text

      # Match macro calls: property, getter, setter, record, etc.
      match = text.match(/^\s*(property\?|property!|property|getter\?|getter!|getter|setter|record)\s+(.+)$/)
      return nil unless match

      macro_name = match[1]
      # Check if cursor is on the macro keyword
      macro_start = text.index(macro_name)
      return nil unless macro_start
      macro_end = macro_start + macro_name.size
      return nil unless character >= macro_start && character <= macro_end

      # Parse arguments
      args_str = match[2].strip
      args = [] of String
      type_hints = [] of String?

      args_str.split(",").each do |part|
        part = part.strip
        if part.includes?(":")
          name, type = part.split(":", 2)
          args << name.strip
          type_hints << type.strip
        else
          args << part
          type_hints << nil
        end
      end

      info = MacroExpander.hover_info(macro_name, args, type_hints)
      return nil unless info

      value = "```crystal\n#{macro_name} #{args_str}\n```\n\n---\n\n#{info}"
      HoverResult.new(contents: MarkupContent.new(kind: "markdown", value: value))
    end

    # Find doc comments using the AST index (avoids crystal tool subprocess)
    private def self.find_doc_comment_via_index(document : Document, line : Int32, character : Int32, ast_index : AST::Index) : String?
      text = document.line_at(line)
      return nil unless text

      # Extract word at cursor
      start_pos = character
      while start_pos > 0 && (text[start_pos - 1].alphanumeric? || text[start_pos - 1].in?('_', '?', '!'))
        start_pos -= 1
      end
      end_pos = character
      while end_pos < text.size && (text[end_pos].alphanumeric? || text[end_pos].in?('_', '?', '!'))
        end_pos += 1
      end
      return nil if start_pos == end_pos
      word = text[start_pos...end_pos]

      # Look up definitions in the AST index
      defs = ast_index.find_definitions(word)
      return nil if defs.empty?

      uri, range = defs.first
      path = URI.uri_to_path(uri)
      extract_comments_above(path, range.start.line)
    end

    # Read comments directly above a line in a file (0-based line number)
    def self.extract_comments_above(filename : String, line : Int32) : String?
      lines = begin
        File.read_lines(filename)
      rescue
        return nil
      end

      return nil if line <= 0 || line >= lines.size

      comments = [] of String
      idx = line - 1
      while idx >= 0
        stripped = lines[idx].strip
        if stripped.starts_with?("#")
          # Remove the # prefix and optional space
          comment_text = stripped.lchop("#").lstrip
          comments.unshift(comment_text)
        elsif stripped.empty?
          # Allow one blank line between comment blocks
          break if idx < line - 1 && !lines[idx + 1].strip.starts_with?("#")
        else
          break
        end
        idx -= 1
      end

      return nil if comments.empty?
      comments.join("\n")
    end
  end
end
