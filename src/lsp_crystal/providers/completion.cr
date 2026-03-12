module Lsp::Crystal::Providers
  module Completion
    KEYWORDS = %w[
      abstract alias annotation begin break case class def do else elsif end
      ensure enum extend for forall fun if in include instance_sizeof is_a?
      lib macro module next nil nil? of out pointerof private protected
      property property? property! getter getter? getter! setter
      raise record require rescue responds_to? return select self sizeof
      struct super then typeof uninitialized union unless until when while
      with yield
    ]

    SNIPPETS = {
      "def"    => {label: "def", insert: "def ${1:name}\n  $0\nend", detail: "Define method"},
      "class"  => {label: "class", insert: "class ${1:Name}\n  $0\nend", detail: "Define class"},
      "struct" => {label: "struct", insert: "struct ${1:Name}\n  $0\nend", detail: "Define struct"},
      "module" => {label: "module", insert: "module ${1:Name}\n  $0\nend", detail: "Define module"},
      "if"     => {label: "if", insert: "if ${1:condition}\n  $0\nend", detail: "If block"},
      "unless" => {label: "unless", insert: "unless ${1:condition}\n  $0\nend", detail: "Unless block"},
      "case"   => {label: "case", insert: "case ${1:value}\nwhen ${2:pattern}\n  $0\nend", detail: "Case expression"},
      "begin"  => {label: "begin", insert: "begin\n  $0\nrescue ex\n  raise ex\nend", detail: "Begin/rescue block"},
      "do"     => {label: "do", insert: "do |${1:var}|\n  $0\nend", detail: "Block with do/end"},
      "describe" => {label: "describe", insert: "describe \"${1:subject}\" do\n  $0\nend", detail: "Spec describe block"},
      "it"       => {label: "it", insert: "it \"${1:does something}\" do\n  $0\nend", detail: "Spec it block"},
      "property" => {label: "property", insert: "property ${1:name} : ${2:Type}", detail: "Property with type"},
      "getter"   => {label: "getter", insert: "getter ${1:name} : ${2:Type}", detail: "Getter with type"},
      "setter"   => {label: "setter", insert: "setter ${1:name} : ${2:Type}", detail: "Setter with type"},
      "enum"     => {label: "enum", insert: "enum ${1:Name}\n  ${2:Value}\n  $0\nend", detail: "Define enum"},
      "abstract" => {label: "abstract", insert: "abstract class ${1:Name}\n  abstract def ${2:method}\n  $0\nend", detail: "Abstract class"},
      "macro"    => {label: "macro", insert: "macro ${1:name}\n  $0\nend", detail: "Define macro"},
      "spawn"    => {label: "spawn", insert: "spawn do\n  $0\nend", detail: "Spawn fiber"},
      "record"   => {label: "record", insert: "record ${1:Name}, ${2:field} : ${3:Type}", detail: "Record macro"},
      "rescue"   => {label: "rescue", insert: "begin\n  ${1:code}\nrescue ${2:ex} : ${3:Exception}\n  $0\nensure\nend", detail: "Begin/rescue/ensure"},
      "json_serializable" => {label: "json_serializable", insert: "include JSON::Serializable\n\n@[JSON::Field(key: \"${1:jsonKey}\")]\nproperty ${2:name} : ${3:Type}", detail: "JSON::Serializable boilerplate"},
    }

    enum CompletionItemKind
      Text          =  1
      Method        =  2
      Function      =  3
      Constructor   =  4
      Field         =  5
      Variable      =  6
      Class         =  7
      Interface     =  8
      Module        =  9
      Property      = 10
      Unit          = 11
      Value         = 12
      Enum          = 13
      Keyword       = 14
      Snippet       = 15
      Color         = 16
      File          = 17
      Reference     = 18
      Folder        = 19
      EnumMember    = 20
      Constant      = 21
      Struct        = 22
      Event         = 23
      Operator      = 24
      TypeParameter = 25
    end

    # InsertTextFormat
    PLAIN_TEXT = 1
    SNIPPET    = 2

    struct CompletionItem
      include JSON::Serializable

      property label : String

      @[JSON::Field(key: "kind")]
      property kind : Int32?

      @[JSON::Field(key: "detail")]
      property detail : String?

      @[JSON::Field(key: "insertText")]
      property insert_text : String?

      @[JSON::Field(key: "insertTextFormat")]
      property insert_text_format : Int32?

      @[JSON::Field(key: "sortText")]
      property sort_text : String?

      property documentation : MarkupContent?

      property data : JSON::Any?

      def initialize(@label, @kind = nil, @detail = nil, @insert_text = nil,
                     @insert_text_format = nil, @sort_text = nil,
                     @documentation = nil, @data = nil)
      end
    end

    struct CompletionList
      include JSON::Serializable

      @[JSON::Field(key: "isIncomplete")]
      property is_incomplete : Bool

      property items : Array(CompletionItem)

      def initialize(@is_incomplete, @items)
      end
    end

    def self.run(document : Document, line : Int32, character : Int32, workspace_root : String? = nil, workspace_index : WorkspaceIndex? = nil, ast_cache : AST::Cache? = nil) : CompletionList
      items = [] of CompletionItem
      current_line = document.line_at(line) || ""
      prefix = character <= current_line.size ? current_line[0...character] : current_line
      uri = document.uri

      if prefix.rstrip.ends_with?(".")
        items.concat(context_completions(document, line, character, workspace_root, workspace_index, uri))
      else
        word = extract_word(prefix)
        unless word.empty?
          items.concat(keyword_completions(word))
          items.concat(snippet_completions(word))
          items.concat(document_symbol_completions(document, word, uri))
          # AST-based local var/param completions
          if cache = ast_cache
            items.concat(ast_context_completions(document, line, character, word, cache, uri))
          end
        end
      end

      CompletionList.new(is_incomplete: false, items: items)
    end

    private def self.context_completions(document : Document, line : Int32, character : Int32, workspace_root : String?, workspace_index : WorkspaceIndex?, uri : String = "") : Array(CompletionItem)
      items = [] of CompletionItem

      # Use crystal tool context to get the type of the expression before the dot
      file_path = document.path
      crystal_line = line + 1

      # Find the dot position in the prefix
      current_line = document.line_at(line) || ""
      dot_col = character - 1
      while dot_col >= 0 && current_line[dot_col]?.try(&.whitespace?)
        dot_col -= 1
      end
      return items if dot_col < 0

      # Write unsaved content to temp file for context lookup
      result = if File.exists?(file_path) && File.read(file_path) == document.content
                 CrystalTool.context(file_path, crystal_line, dot_col + 1)
               else
                 temp = File.tempname("crystal-lsp-completion", ".cr")
                 begin
                   File.write(temp, document.content)
                   CrystalTool.context(temp, crystal_line, dot_col + 1)
                 ensure
                   File.delete(temp) rescue nil
                 end
               end

      return items unless result.success

      begin
        json = JSON.parse(result.stdout)
      rescue
        return items
      end

      return items unless json["status"]?.try(&.as_s) == "ok"

      contexts = json["contexts"]?.try(&.as_a) || return items
      return items if contexts.empty?

      # Extract type name from context (e.g., "String", "Array(Int32)")
      type_name = contexts.first["context"]?.try(&.as_s) || return items
      # Extract the base type name (strip generics, union types)
      base_type = type_name.split("(").first.split("|").first.strip.split("::").last

      # Search for methods defined on this type in workspace
      seen = Set(String).new
      search_type_methods(document, base_type, items, seen, uri)

      if idx = workspace_index
        idx.search_type_methods(base_type) do |name, detail|
          next if seen.includes?(name)
          seen.add(name)
          items << CompletionItem.new(
            label: name,
            kind: CompletionItemKind::Method.value,
            detail: detail,
            sort_text: "1_#{name}",
            data: JSON::Any.new({"uri" => JSON::Any.new(uri), "name" => JSON::Any.new(name), "kind" => JSON::Any.new("method"), "container" => JSON::Any.new(base_type)})
          )
        end
      end

      items
    end

    private def self.search_type_methods(document : Document, type_name : String, items : Array(CompletionItem), seen : Set(String), uri : String = "")
      in_type = false
      depth = 0

      document.content.each_line do |line|
        stripped = line.strip
        if stripped =~ /^\s*(?:class|struct|module)\s+#{Regex.escape(type_name)}\b/
          in_type = true
          depth = 1
          next
        end

        if in_type
          if stripped =~ /^\s*(?:class|struct|module|def|if|unless|case|begin|do|while|until|macro|enum|lib|fun|annotation)\b/
            depth += 1
          end
          if stripped =~ /^\s*end\b/
            depth -= 1
            if depth <= 0
              in_type = false
              next
            end
          end

          if depth == 2 && stripped =~ /^\s*def\s+(\w+[?!]?)/
            name = $1
            unless seen.includes?(name)
              seen.add(name)
              items << CompletionItem.new(
                label: name,
                kind: CompletionItemKind::Method.value,
                detail: "#{type_name}##{name}",
                sort_text: "1_#{name}",
                data: JSON::Any.new({"uri" => JSON::Any.new(uri), "name" => JSON::Any.new(name), "kind" => JSON::Any.new("method"), "container" => JSON::Any.new(type_name)})
              )
            end
          elsif depth == 1 && stripped =~ /^\s*(property|property\?|property!|getter|getter\?|getter!|setter)\s+(\w+)/
            macro_name = $1
            name = $2
            unless seen.includes?(name)
              seen.add(name)
              # Add getter (except for setter-only)
              unless macro_name == "setter"
                items << CompletionItem.new(
                  label: name,
                  kind: CompletionItemKind::Property.value,
                  detail: "#{type_name}##{name}",
                  sort_text: "1_#{name}",
                  data: JSON::Any.new({"uri" => JSON::Any.new(uri), "name" => JSON::Any.new(name), "kind" => JSON::Any.new("property"), "container" => JSON::Any.new(type_name)})
                )
              end
            end
            # Add setter for property/property!/setter macros
            if macro_name.in?("property", "property!", "setter")
              setter_name = "#{name}="
              unless seen.includes?(setter_name)
                seen.add(setter_name)
                items << CompletionItem.new(
                  label: setter_name,
                  kind: CompletionItemKind::Method.value,
                  detail: "#{type_name}##{setter_name}",
                  sort_text: "1_#{setter_name}",
                  data: JSON::Any.new({"uri" => JSON::Any.new(uri), "name" => JSON::Any.new(name), "kind" => JSON::Any.new("method"), "container" => JSON::Any.new(type_name)})
                )
              end
            end
          end
        end
      end
    end

    # AST-based completions for local vars, params, and instance vars at cursor
    private def self.ast_context_completions(document : Document, line : Int32, character : Int32, word : String, ast_cache : AST::Cache, uri : String = "") : Array(CompletionItem)
      items = [] of CompletionItem
      result = ast_cache.get(document)
      return items unless result && result.success? && (node = result.node)

      visitor = AST::ContextVisitor.new(line, character)
      node.accept(visitor)
      ctx = visitor.context

      seen = Set(String).new

      ctx.method_params.each do |name|
        next unless name.starts_with?(word) && name != word
        next if seen.includes?(name)
        seen.add(name)
        items << CompletionItem.new(
          label: name,
          kind: CompletionItemKind::Variable.value,
          detail: "parameter",
          sort_text: "0_#{name}",
          data: JSON::Any.new({"uri" => JSON::Any.new(uri), "name" => JSON::Any.new(name), "kind" => JSON::Any.new("parameter")})
        )
      end

      ctx.local_vars.each do |name|
        next unless name.starts_with?(word) && name != word
        next if seen.includes?(name)
        seen.add(name)
        items << CompletionItem.new(
          label: name,
          kind: CompletionItemKind::Variable.value,
          detail: "local variable",
          sort_text: "0_#{name}",
          data: JSON::Any.new({"uri" => JSON::Any.new(uri), "name" => JSON::Any.new(name), "kind" => JSON::Any.new("local_variable")})
        )
      end

      ctx.instance_vars.each do |name|
        next unless name.starts_with?(word) && name != word
        next if seen.includes?(name)
        seen.add(name)
        items << CompletionItem.new(
          label: name,
          kind: CompletionItemKind::Field.value,
          detail: "instance variable",
          sort_text: "0_#{name}",
          data: JSON::Any.new({"uri" => JSON::Any.new(uri), "name" => JSON::Any.new(name), "kind" => JSON::Any.new("instance_variable")})
        )
      end

      items
    rescue
      [] of CompletionItem
    end

    private def self.extract_word(prefix : String) : String
      i = prefix.size - 1
      while i >= 0 && (prefix[i].alphanumeric? || prefix[i] == '_' || prefix[i] == '?' || prefix[i] == '!')
        i -= 1
      end
      prefix[(i + 1)..]
    end

    private def self.keyword_completions(word : String) : Array(CompletionItem)
      KEYWORDS.select(&.starts_with?(word)).map do |kw|
        CompletionItem.new(
          label: kw,
          kind: CompletionItemKind::Keyword.value,
          sort_text: "2_#{kw}"
        )
      end
    end

    private def self.snippet_completions(word : String) : Array(CompletionItem)
      SNIPPETS.select { |k, _| k.starts_with?(word) }.map do |_, snip|
        CompletionItem.new(
          label: snip[:label],
          kind: CompletionItemKind::Snippet.value,
          detail: snip[:detail],
          insert_text: snip[:insert],
          insert_text_format: SNIPPET,
          sort_text: "1_#{snip[:label]}"
        )
      end
    end

    private def self.document_symbol_completions(document : Document, word : String, uri : String = "") : Array(CompletionItem)
      items = [] of CompletionItem
      seen = Set(String).new

      document.content.each_line do |line|
        line = line.strip
        if line =~ /^\s*def\s+(\w+[?!]?)/
          name = $1
          add_if_match(items, seen, name, word, CompletionItemKind::Method, uri)
        elsif line =~ /^\s*(?:class|struct)\s+(\w+)/
          name = $1
          add_if_match(items, seen, name, word, CompletionItemKind::Class, uri)
        elsif line =~ /^\s*module\s+(\w+)/
          name = $1
          add_if_match(items, seen, name, word, CompletionItemKind::Module, uri)
        elsif line =~ /^\s*(property|property\?|property!|getter|getter\?|getter!|setter)\s+(\w+)/
          macro_name = $1
          name = $2
          add_if_match(items, seen, name, word, CompletionItemKind::Property, uri) unless macro_name == "setter"
          if macro_name.in?("property", "property!", "setter")
            add_if_match(items, seen, "#{name}=", word, CompletionItemKind::Method, uri)
          end
        elsif line =~ /^\s*(\w+)\s*=/
          name = $1
          if name == name.upcase && name.size > 1
            add_if_match(items, seen, name, word, CompletionItemKind::Constant, uri)
          end
        end
      end

      items
    end

    private def self.add_if_match(items : Array(CompletionItem), seen : Set(String),
                                  name : String, word : String, kind : CompletionItemKind, uri : String = "")
      return if name == word
      return unless name.starts_with?(word)
      return if seen.includes?(name)
      seen.add(name)
      kind_str = case kind
                 when .method?   then "method"
                 when .class?    then "class"
                 when .module?   then "module"
                 when .property? then "property"
                 when .constant? then "constant"
                 else                 "symbol"
                 end
      items << CompletionItem.new(
        label: name,
        kind: kind.value,
        sort_text: "3_#{name}",
        data: JSON::Any.new({"uri" => JSON::Any.new(uri), "name" => JSON::Any.new(name), "kind" => JSON::Any.new(kind_str)})
      )
    end
  end
end
