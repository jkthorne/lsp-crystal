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

      def initialize(@label, @kind = nil, @detail = nil, @insert_text = nil,
                     @insert_text_format = nil, @sort_text = nil)
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

    def self.run(document : Document, line : Int32, character : Int32) : CompletionList
      items = [] of CompletionItem
      current_line = document.line_at(line) || ""
      prefix = character <= current_line.size ? current_line[0...character] : current_line

      if prefix.rstrip.ends_with?(".")
        # Dot completion — could use crystal tool context in the future
        # For now return empty
      else
        word = extract_word(prefix)
        unless word.empty?
          items.concat(keyword_completions(word))
          items.concat(snippet_completions(word))
          items.concat(document_symbol_completions(document, word))
        end
      end

      CompletionList.new(is_incomplete: false, items: items)
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

    private def self.document_symbol_completions(document : Document, word : String) : Array(CompletionItem)
      items = [] of CompletionItem
      seen = Set(String).new

      document.content.each_line do |line|
        line = line.strip
        if line =~ /^\s*def\s+(\w+[?!]?)/
          name = $1
          add_if_match(items, seen, name, word, CompletionItemKind::Method)
        elsif line =~ /^\s*(?:class|struct)\s+(\w+)/
          name = $1
          add_if_match(items, seen, name, word, CompletionItemKind::Class)
        elsif line =~ /^\s*module\s+(\w+)/
          name = $1
          add_if_match(items, seen, name, word, CompletionItemKind::Module)
        elsif line =~ /^\s*(?:property|getter|setter)[?!]?\s+(\w+)/
          name = $1
          add_if_match(items, seen, name, word, CompletionItemKind::Property)
        elsif line =~ /^\s*(\w+)\s*=/
          name = $1
          if name == name.upcase && name.size > 1
            add_if_match(items, seen, name, word, CompletionItemKind::Constant)
          end
        end
      end

      items
    end

    private def self.add_if_match(items : Array(CompletionItem), seen : Set(String),
                                  name : String, word : String, kind : CompletionItemKind)
      return if name == word
      return unless name.starts_with?(word)
      return if seen.includes?(name)
      seen.add(name)
      items << CompletionItem.new(
        label: name,
        kind: kind.value,
        sort_text: "3_#{name}"
      )
    end
  end
end
