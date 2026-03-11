module Lsp::Crystal
  class CrystalTool
    struct ToolResult
      property success : Bool
      property stdout : String
      property stderr : String

      def initialize(@success, @stdout, @stderr)
      end
    end

    def self.run(args : Array(String), input : String? = nil) : ToolResult
      stdout_io = IO::Memory.new
      stderr_io = IO::Memory.new

      begin
        status = Process.run(
          "crystal",
          args,
          output: stdout_io,
          error: stderr_io,
          input: input ? IO::Memory.new(input) : Process::Redirect::Close
        )
        ToolResult.new(status.success?, stdout_io.to_s, stderr_io.to_s)
      rescue ex
        ToolResult.new(false, "", ex.message || "Failed to run crystal")
      end
    end

    # Type-check a file without generating code
    def self.check(file_path : String) : ToolResult
      run(["build", "--no-codegen", "--no-color", "--error-trace", file_path])
    end

    # Type-check in-memory content using a temp file
    def self.check_content(content : String, filename : String) : ToolResult
      temp = File.tempname("crystal-lsp", ".cr")
      File.write(temp, content)
      result = check(temp)
      File.delete(temp) rescue nil
      ToolResult.new(
        result.success,
        result.stdout.gsub(temp, filename),
        result.stderr.gsub(temp, filename)
      )
    end

    # Get type context at cursor position
    def self.context(file_path : String, line : Int32, column : Int32) : ToolResult
      cursor = "#{file_path}:#{line}:#{column}"
      run(["tool", "context", "-c", cursor, "-f", "json", file_path])
    end

    # Find implementations/definitions
    def self.implementations(file_path : String, line : Int32, column : Int32) : ToolResult
      cursor = "#{file_path}:#{line}:#{column}"
      run(["tool", "implementations", "-c", cursor, "-f", "json", file_path])
    end

    # Format code via stdin
    def self.format(content : String) : ToolResult
      run(["tool", "format", "-"], input: content)
    end

    # Expand macros at cursor position
    def self.expand(file_path : String, line : Int32, column : Int32) : ToolResult
      cursor = "#{file_path}:#{line}:#{column}"
      run(["tool", "expand", "-c", cursor, "-f", "json", file_path])
    end
  end
end
