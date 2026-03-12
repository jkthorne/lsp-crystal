module Lsp::Crystal
  class CrystalTool
    DEFAULT_TIMEOUT = 30.seconds

    struct ToolResult
      property success : Bool
      property stdout : String
      property stderr : String

      def initialize(@success, @stdout, @stderr)
      end
    end

    def self.run(args : Array(String), input : String? = nil, timeout : Time::Span = DEFAULT_TIMEOUT) : ToolResult
      stdout_io = IO::Memory.new
      stderr_io = IO::Memory.new

      begin
        process = Process.new(
          "crystal",
          args,
          output: stdout_io,
          error: stderr_io,
          input: input ? Process::Redirect::Pipe : Process::Redirect::Close
        )

        if input && (stdin = process.input?)
          stdin.print(input)
          stdin.close
        end

        timed_out = false
        done_channel = Channel(Nil).new(1)

        spawn do
          sleep timeout
          unless done_channel.closed?
            timed_out = true
            process.terminate rescue nil
            # Give it a moment to exit gracefully, then force kill
            spawn do
              sleep 2.seconds
              process.signal(Signal::KILL) rescue nil
            end
          end
        end

        status = process.wait
        done_channel.close

        if timed_out
          ToolResult.new(false, "", "Crystal tool timed out after #{timeout.total_seconds.to_i}s")
        else
          ToolResult.new(status.success?, stdout_io.to_s, stderr_io.to_s)
        end
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
      begin
        File.write(temp, content)
        result = check(temp)
        ToolResult.new(
          result.success,
          result.stdout.gsub(temp, filename),
          result.stderr.gsub(temp, filename)
        )
      ensure
        File.delete(temp) rescue nil
      end
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
