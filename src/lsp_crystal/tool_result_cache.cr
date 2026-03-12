module Lsp::Crystal
  class ToolResultCache
    struct CacheKey
      getter tool : String
      getter file_path : String
      getter line : Int32
      getter column : Int32
      getter content_hash : UInt64

      def initialize(@tool, @file_path, @line, @column, @content_hash)
      end

      def ==(other : CacheKey) : Bool
        tool == other.tool && file_path == other.file_path &&
          line == other.line && column == other.column &&
          content_hash == other.content_hash
      end

      def hash(hasher)
        hasher = tool.hash(hasher)
        hasher = file_path.hash(hasher)
        hasher = line.hash(hasher)
        hasher = column.hash(hasher)
        hasher = content_hash.hash(hasher)
        hasher
      end
    end

    struct CacheEntry
      getter result : CrystalTool::ToolResult
      getter created_at : Time::Instant
      getter key : CacheKey

      def initialize(@result, @key)
        @created_at = Time.instant
      end

      def expired?(ttl : Time::Span) : Bool
        (Time.instant - @created_at) > ttl
      end
    end

    def initialize(@max_entries : Int32 = 500, @ttl_seconds : Int32 = 60)
      @entries = Hash(CacheKey, CacheEntry).new
      @access_order = Array(CacheKey).new
      @mutex = Mutex.new
    end

    # Get a cached result, or nil if not found/expired
    def get(tool : String, file_path : String, line : Int32, column : Int32, content_hash : UInt64) : CrystalTool::ToolResult?
      key = CacheKey.new(tool, file_path, line, column, content_hash)
      @mutex.synchronize do
        if entry = @entries[key]?
          if entry.expired?(@ttl_seconds.seconds)
            @entries.delete(key)
            @access_order.delete(key)
            return nil
          end
          # Move to end of access order (most recently used)
          @access_order.delete(key)
          @access_order << key
          return entry.result
        end
      end
      nil
    end

    # Store a result in the cache
    def put(tool : String, file_path : String, line : Int32, column : Int32, content_hash : UInt64, result : CrystalTool::ToolResult) : Nil
      key = CacheKey.new(tool, file_path, line, column, content_hash)
      @mutex.synchronize do
        # Evict LRU entries if at capacity
        while @entries.size >= @max_entries && !@access_order.empty?
          evict_key = @access_order.shift
          @entries.delete(evict_key)
        end

        @entries[key] = CacheEntry.new(result, key)
        @access_order.delete(key)
        @access_order << key
      end
    end

    # Invalidate all entries for a given file path
    def invalidate(file_path : String) : Nil
      @mutex.synchronize do
        keys_to_remove = @entries.keys.select { |k| k.file_path == file_path }
        keys_to_remove.each do |key|
          @entries.delete(key)
          @access_order.delete(key)
        end
      end
    end

    # Invalidate all entries for a URI (converts URI to path first)
    def invalidate_uri(uri : String) : Nil
      path = URI.uri_to_path(uri)
      invalidate(path)
    end

    def clear : Nil
      @mutex.synchronize do
        @entries.clear
        @access_order.clear
      end
    end

    def size : Int32
      @mutex.synchronize { @entries.size }
    end

    # Convenience: get or fetch from crystal tool
    def get_or_fetch(tool : String, file_path : String, line : Int32, column : Int32, content_hash : UInt64, &block : -> CrystalTool::ToolResult) : CrystalTool::ToolResult
      cached = get(tool, file_path, line, column, content_hash)
      return cached if cached

      result = yield
      put(tool, file_path, line, column, content_hash, result) if result.success
      result
    end
  end
end
