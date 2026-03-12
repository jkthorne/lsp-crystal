module Lsp::Crystal
  class Document
    property uri : String
    property language_id : String
    property version : Int32
    property content : String
    # Cached symbol results, invalidated on content change
    property cached_symbols : Array(Providers::DocumentSymbol::HierarchicalSymbolInfo)?
    property cached_flat_symbols : Array(Providers::DocumentSymbol::SymbolInfo)?
    @cached_version : Int32 = -1

    def initialize(@uri, @language_id, @version, @content)
    end

    def symbols_stale? : Bool
      @cached_version != @version
    end

    def cache_symbols(hierarchical : Array(Providers::DocumentSymbol::HierarchicalSymbolInfo),
                      flat : Array(Providers::DocumentSymbol::SymbolInfo)) : Nil
      @cached_symbols = hierarchical
      @cached_flat_symbols = flat
      @cached_version = @version
    end

    def apply_change(range : Range?, text : String) : Nil
      if range
        start_offset = offset_at(range.start)
        end_offset = offset_at(range.end_pos)
        @content = @content[0...start_offset] + text + @content[end_offset..]
      else
        @content = text
      end
    end

    def offset_at(position : Position) : Int32
      line = 0
      @content.each_char_with_index do |char, i|
        if line == position.line
          return i + position.character
        end
        if char == '\n'
          line += 1
        end
      end
      @content.size
    end

    def position_at(offset : Int32) : Position
      line = 0
      col = 0
      @content.each_char_with_index do |char, i|
        return Position.new(line: line, character: col) if i == offset
        if char == '\n'
          line += 1
          col = 0
        else
          col += 1
        end
      end
      Position.new(line: line, character: col)
    end

    def line_at(line_number : Int32) : String?
      @content.lines[line_number]?
    end

    def line_count : Int32
      @content.count('\n') + 1
    end

    def path : String
      URI.uri_to_path(@uri)
    end

    def end_position : Position
      lines = @content.lines
      if lines.empty?
        Position.new(line: 0, character: 0)
      else
        Position.new(line: lines.size - 1, character: lines.last.size)
      end
    end
  end

  class DocumentStore
    def initialize
      @documents = Hash(String, Document).new
      @mutex = Mutex.new
    end

    def open(uri : String, language_id : String, version : Int32, content : String) : Document
      doc = Document.new(uri, language_id, version, content)
      @mutex.synchronize { @documents[uri] = doc }
      doc
    end

    def close(uri : String) : Nil
      @mutex.synchronize { @documents.delete(uri) }
    end

    def get(uri : String) : Document?
      @mutex.synchronize { @documents[uri]? }
    end

    def update(uri : String, version : Int32, changes : Array(JSON::Any)) : Document?
      @mutex.synchronize do
        doc = @documents[uri]? || return nil
        doc.version = version
        changes.each do |change|
          range = if r = change["range"]?
                    Range.from_json(r.to_json)
                  end
          doc.apply_change(range, change["text"].as_s)
        end
        doc
      end
    end

    def each(&block : Document ->) : Nil
      @mutex.synchronize do
        @documents.each_value { |doc| block.call(doc) }
      end
    end

    def each_uri(&block : String ->) : Nil
      @mutex.synchronize do
        @documents.each_key { |uri| block.call(uri) }
      end
    end

    def size : Int32
      @mutex.synchronize { @documents.size }
    end
  end
end
