module Lsp::Crystal
  class RequireGraph
    REQUIRE_REGEX = /^\s*require\s+"([^"]+)"\s*$/

    @dependencies : Hash(String, Set(String))  # file -> files it requires
    @dependents : Hash(String, Set(String))    # file -> files that require it
    @mutex : Mutex
    @built : Bool

    def initialize
      @dependencies = Hash(String, Set(String)).new
      @dependents = Hash(String, Set(String)).new
      @mutex = Mutex.new
      @built = false
    end

    def built? : Bool
      @mutex.synchronize { @built }
    end

    # Full workspace scan
    def build(workspace_root : String) : Nil
      @mutex.synchronize do
        @dependencies.clear
        @dependents.clear

        cr_files = Dir.glob(File.join(workspace_root, "**", "*.cr"))
        cr_files.each do |file_path|
          next unless File.file?(file_path)
          begin
            content = File.read(file_path)
            deps = resolve_requires(file_path, content, workspace_root)
            @dependencies[file_path] = deps
            deps.each do |dep|
              (@dependents[dep] ||= Set(String).new) << file_path
            end
          rescue
            # Skip files we can't read
          end
        end

        @built = true
      end
      Log.info { "Require graph built: #{@dependencies.size} files" }
    end

    # Update a single file's dependencies
    def update_file(path : String, content : String? = nil) : Nil
      @mutex.synchronize do
        return unless @built

        # Remove old edges
        if old_deps = @dependencies[path]?
          old_deps.each do |dep|
            @dependents[dep]?.try(&.delete(path))
          end
        end

        # Read content if not provided
        actual_content = content || begin
          File.read(path)
        rescue
          nil
        end

        if actual_content
          workspace_root = guess_workspace_root(path)
          deps = resolve_requires(path, actual_content, workspace_root)
          @dependencies[path] = deps
          deps.each do |dep|
            (@dependents[dep] ||= Set(String).new) << path
          end
        else
          @dependencies.delete(path)
        end
      end
    end

    def remove_file(path : String) : Nil
      @mutex.synchronize do
        return unless @built

        # Remove as dependency
        if old_deps = @dependencies.delete(path)
          old_deps.each do |dep|
            @dependents[dep]?.try(&.delete(path))
          end
        end

        # Remove as dependent
        if old_dependents = @dependents.delete(path)
          old_dependents.each do |dep|
            @dependencies[dep]?.try(&.delete(path))
          end
        end
      end
    end

    # BFS to find all files that transitively depend on the given path
    def transitive_dependents(path : String) : Set(String)
      result = Set(String).new
      queue = Deque(String).new

      @mutex.synchronize do
        if deps = @dependents[path]?
          deps.each { |d| queue << d }
        end

        while dep = queue.shift?
          next if result.includes?(dep)
          result << dep
          if more = @dependents[dep]?
            more.each { |d| queue << d unless result.includes?(d) }
          end
        end
      end

      result
    end

    # For testing: direct dependencies of a file
    def dependencies(path : String) : Set(String)
      @mutex.synchronize { @dependencies[path]? || Set(String).new }
    end

    # For testing: direct dependents of a file
    def direct_dependents(path : String) : Set(String)
      @mutex.synchronize { @dependents[path]? || Set(String).new }
    end

    private def resolve_requires(file_path : String, content : String, workspace_root : String?) : Set(String)
      deps = Set(String).new
      dir = File.dirname(file_path)

      content.each_line do |line|
        if m = REQUIRE_REGEX.match(line)
          req = m[1]
          resolved = resolve_require(req, dir, workspace_root)
          resolved.each { |r| deps << r }
        end
      end

      deps
    end

    private def resolve_require(req : String, dir : String, workspace_root : String?) : Array(String)
      if req.includes?("*")
        resolve_glob(req, dir, workspace_root)
      elsif req.starts_with?("./") || req.starts_with?("../")
        resolve_relative(req, dir)
      else
        resolve_absolute(req, dir, workspace_root)
      end
    end

    private def resolve_relative(req : String, dir : String) : Array(String)
      base = File.expand_path(req, dir)
      try_crystal_path(base)
    end

    private def resolve_absolute(req : String, dir : String, workspace_root : String?) : Array(String)
      results = [] of String

      if workspace_root
        # Try lib/<name>/src/<name>.cr (shard dependency)
        parts = req.split("/")
        shard_name = parts[0]
        lib_path = if parts.size > 1
                     File.join(workspace_root, "lib", shard_name, "src", parts[1..].join("/"))
                   else
                     File.join(workspace_root, "lib", shard_name, "src", "#{shard_name}.cr")
                   end
        results.concat(try_crystal_path(lib_path.rchop(".cr"))) if lib_path.ends_with?(".cr")
        results.concat(try_crystal_path(lib_path)) unless lib_path.ends_with?(".cr")

        # Try src/<req>.cr
        src_path = File.join(workspace_root, "src", req)
        results.concat(try_crystal_path(src_path))
      end

      # Try relative to current dir as fallback
      if results.empty?
        base = File.join(dir, req)
        results.concat(try_crystal_path(base))
      end

      results
    end

    private def resolve_glob(req : String, dir : String, workspace_root : String?) : Array(String)
      results = [] of String

      # Try relative glob first
      if req.starts_with?("./") || req.starts_with?("../")
        pattern = File.expand_path(req, dir)
      else
        pattern = File.join(dir, req)
      end

      # Expand ** to recursive glob, * to single-level
      glob_pattern = pattern.gsub("**", "DOUBLE_STAR").gsub("*", "*.cr").gsub("DOUBLE_STAR", "**/*.cr")

      # Also try without .cr extension change if pattern already has .cr
      Dir.glob(glob_pattern).each do |file|
        results << file if file.ends_with?(".cr") && File.file?(file)
      end

      # If nothing found, try with .cr appended differently
      if results.empty?
        alt_pattern = "#{pattern}.cr"
        Dir.glob(alt_pattern).each do |file|
          results << file if File.file?(file)
        end
      end

      results
    end

    # Try foo.cr, then foo/foo.cr (Crystal's resolution order)
    private def try_crystal_path(base : String) : Array(String)
      results = [] of String
      cr_path = base.ends_with?(".cr") ? base : "#{base}.cr"
      if File.exists?(cr_path) && File.file?(cr_path)
        results << cr_path
      end

      # Try directory form: foo/foo.cr
      dir_name = File.basename(base.rchop(".cr"))
      dir_path = File.join(base.rchop(".cr"), "#{dir_name}.cr")
      if File.exists?(dir_path) && File.file?(dir_path)
        results << dir_path
      end

      results
    end

    private def guess_workspace_root(path : String) : String?
      dir = File.dirname(path)
      while dir != "/" && dir != "."
        return dir if File.exists?(File.join(dir, "shard.yml"))
        dir = File.dirname(dir)
      end
      nil
    end
  end
end
