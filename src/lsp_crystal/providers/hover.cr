module Lsp::Crystal::Providers
  module Hover
    struct HoverResult
      include JSON::Serializable

      property contents : MarkupContent

      def initialize(@contents)
      end
    end

    def self.run(document : Document, line : Int32, character : Int32, ast_index : AST::Index? = nil, tool_cache : ToolResultCache? = nil, server : Server? = nil) : HoverResult?
      # Tier 1: Check if cursor is on a known macro call — instant, no subprocess
      macro_hover = check_macro_hover(document, line, character)
      return macro_hover if macro_hover

      # Tier 2: Check for expanded macro via crystal tool expand (cached, non-blocking)
      if srv = server
        if srv.macro_expand_available?
          expand_hover = check_expand_hover(document, line, character, tool_cache, srv)
          return expand_hover if expand_hover
        end
      end

      file_path = document.path
      # Convert 0-based LSP to 1-based Crystal
      crystal_line = line + 1
      crystal_col = character + 1
      content_hash = document.content.hash.to_u64

      # Parallel tool dispatch: run context and implementations concurrently
      parallel = server.try(&.configuration.parallel_tool_calls) != false

      context_result : CrystalTool::ToolResult? = nil
      impl_result : CrystalTool::ToolResult? = nil

      if parallel
        context_chan = Channel(CrystalTool::ToolResult).new(1)
        impl_chan = Channel(CrystalTool::ToolResult).new(1)

        spawn do
          r = if cache = tool_cache
                cache.get_or_fetch("context", file_path, crystal_line, crystal_col, content_hash) do
                  CrystalTool.context(file_path, crystal_line, crystal_col)
                end
              else
                CrystalTool.context(file_path, crystal_line, crystal_col)
              end
          context_chan.send(r)
        end

        spawn do
          r = if cache = tool_cache
                cache.get_or_fetch("implementations", file_path, crystal_line, crystal_col, content_hash) do
                  CrystalTool.implementations(file_path, crystal_line, crystal_col)
                end
              else
                CrystalTool.implementations(file_path, crystal_line, crystal_col)
              end
          impl_chan.send(r)
        end

        context_result = context_chan.receive
        impl_result = impl_chan.receive
      else
        context_result = if cache = tool_cache
                           cache.get_or_fetch("context", file_path, crystal_line, crystal_col, content_hash) do
                             CrystalTool.context(file_path, crystal_line, crystal_col)
                           end
                         else
                           CrystalTool.context(file_path, crystal_line, crystal_col)
                         end
      end

      result = context_result
      return nil unless result && result.success

      begin
        json = JSON.parse(result.stdout)
      rescue
        json = nil
      end

      if json && json["status"]?.try(&.as_s) == "ok"
        contexts = json["contexts"]?.try(&.as_a)
        if contexts && !contexts.empty?
          content = format_contexts(contexts)
          return nil if content.empty?

          # Try AST index for doc comment lookup (faster than crystal tool)
          doc_comment = if idx = ast_index
                         find_doc_comment_via_index(document, line, character, idx)
                       end

          # Use pre-fetched impl_result if available, otherwise fetch sequentially
          doc_comment ||= if ir = impl_result
                            find_doc_comment_from_result(ir)
                          else
                            find_doc_comment(document, line, character)
                          end

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

      nil
    end

    # Render the `contexts` array from `crystal tool context -f json` into hover text.
    # Recent Crystal versions emit each context as a `{name => type}` map rather than
    # a `{"context" => "..."}` object, so read the legacy key when present and otherwise
    # format the map. Returns "" when nothing renderable is found.
    def self.format_contexts(contexts : Array(JSON::Any)) : String
      lines = [] of String
      contexts.each do |ctx|
        obj = ctx.as_h?
        if obj
          legacy = obj["context"]?.try(&.as_s?)
          if legacy
            lines << legacy
          else
            obj.each do |name, type|
              lines << "#{name} : #{type.as_s? || type.to_s}"
            end
          end
        else
          str = ctx.as_s?
          lines << str if str
        end
      end
      lines.join("\n")
    end

    # Extract doc comments from definition site
    private def self.find_doc_comment(document : Document, line : Int32, character : Int32) : String?
      # Try to find where the symbol is defined
      impl_result = CrystalTool.implementations(document.path, line + 1, character + 1)
      find_doc_comment_from_result(impl_result)
    end

    # Extract doc comments from an implementations result
    private def self.find_doc_comment_from_result(impl_result : CrystalTool::ToolResult) : String?
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

    # Tier 2: Check expand cache for user-defined macros
    private def self.check_expand_hover(document : Document, line : Int32, character : Int32, tool_cache : ToolResultCache?, server : Server) : HoverResult?
      return nil unless tool_cache

      text = document.line_at(line)
      return nil unless text

      # Check if cursor is on a method/macro call (a word that could be a macro)
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

      # Skip known macros (handled by Tier 1) and common keywords
      return nil if MacroExpander.known_macro?(word)
      return nil if word.in?("def", "class", "module", "struct", "enum", "if", "else", "elsif",
        "end", "do", "require", "include", "extend", "return", "nil", "true", "false",
        "self", "super", "abstract", "private", "protected", "lib", "fun", "alias",
        "type", "typeof", "sizeof", "instance_sizeof", "pointerof", "offsetof",
        "begin", "rescue", "ensure", "raise", "yield", "with", "case", "when",
        "while", "until", "for", "break", "next", "in", "of", "as", "as?", "is_a?",
        "responds_to?", "nil?", "not_nil!", "uninitialized", "annotation", "macro",
        "select", "asm", "out", "spawn", "puts", "pp", "p", "print")

      file_path = document.path
      crystal_line = line + 1
      crystal_col = start_pos + 1
      content_hash = document.content.hash.to_u64

      # Check cache for a previous expand result
      cached = tool_cache.get("expand", file_path, crystal_line, crystal_col, content_hash)
      if cached
        return format_expand_hover(cached, word)
      end

      # No cache hit — kick off background expansion (non-blocking)
      spawn do
        timeout = server.configuration.macro_expand_timeout.seconds
        result = CrystalTool.expand_content(document.content, file_path, crystal_line, crystal_col, timeout)
        if result.success
          tool_cache.put("expand", file_path, crystal_line, crystal_col, content_hash, result)
          server.reset_expand_failures
        else
          server.record_expand_failure
        end
      end

      nil
    end

    # Format an expand result into hover markdown
    private def self.format_expand_hover(result : CrystalTool::ToolResult, word : String) : HoverResult?
      parsed = CrystalTool.parse_expand_result(result)
      return nil unless parsed
      return nil if parsed.expansions.empty?

      value = String.build do |str|
        str << "```crystal\n#{word}\n```\n\n---\n\nExpands to:\n"
        parsed.expansions.each do |exp|
          exp.expanded_sources.each do |src|
            str << "\n```crystal\n#{src.strip}\n```\n"
          end
        end
      end

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
