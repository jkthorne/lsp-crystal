module Lsp::Crystal
  module AST
    class Cache
      struct Entry
        getter result : ParseResult
        getter version : Int32

        def initialize(@result, @version)
        end
      end

      def initialize
        @entries = Hash(String, Entry).new
        @mutex = Mutex.new
      end

      # Get or parse AST for a document. Returns nil if document has no content.
      def get(document : Document) : ParseResult?
        @mutex.synchronize do
          if entry = @entries[document.uri]?
            return entry.result if entry.version == document.version
          end
        end

        # Parse outside the lock
        result = AST.parse(document.content, document.path)

        @mutex.synchronize do
          @entries[document.uri] = Entry.new(result: result, version: document.version)
        end

        result
      end

      # Invalidate cache for a URI (on didChange/didClose)
      def invalidate(uri : String) : Nil
        @mutex.synchronize do
          @entries.delete(uri)
        end
      end

      # Clear all cached entries
      def clear : Nil
        @mutex.synchronize do
          @entries.clear
        end
      end

      def size : Int32
        @mutex.synchronize { @entries.size }
      end
    end
  end
end
