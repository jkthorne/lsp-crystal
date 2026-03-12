module Lsp::Crystal
  class CrystalTool
    DEFAULT_TIMEOUT = 30.seconds

    @@fiber_tokens = Hash(Fiber, CancellationToken).new
    @@fiber_tokens_mutex = Mutex.new

    struct ToolResult
      property success : Bool
      property stdout : String
      property stderr : String

      def initialize(@success, @stdout, @stderr)
      end
    end

    def self.set_cancellation(token : CancellationToken) : Nil
      @@fiber_tokens_mutex.synchronize { @@fiber_tokens[Fiber.current] = token }
    end

    def self.clear_cancellation : Nil
      @@fiber_tokens_mutex.synchronize { @@fiber_tokens.delete(Fiber.current) }
    end

    def self.current_cancellation : CancellationToken?
      @@fiber_tokens_mutex.synchronize { @@fiber_tokens[Fiber.current]? }
    end

    def self.run(args : Array(String), input : String? = nil, timeout : Time::Span = DEFAULT_TIMEOUT) : ToolResult
      stdout_io = IO::Memory.new
      stderr_io = IO::Memory.new
      cancel_token = current_cancellation

      if cancel_token && cancel_token.cancelled?
        return ToolResult.new(false, "", "Request was cancelled")
      end

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
        cancelled = false
        done_channel = Channel(Nil).new(1)

        spawn do
          loop do
            sleep 200.milliseconds
            if done_channel.closed?
              break
            end
            if cancel_token && cancel_token.cancelled?
              cancelled = true
              process.terminate rescue nil
              spawn do
                sleep 2.seconds
                process.signal(Signal::KILL) rescue nil
              end
              break
            end
          end
        end

        spawn do
          sleep timeout
          unless done_channel.closed?
            timed_out = true
            process.terminate rescue nil
            spawn do
              sleep 2.seconds
              process.signal(Signal::KILL) rescue nil
            end
          end
        end

        status = process.wait
        done_channel.close

        if cancelled
          ToolResult.new(false, "", "Request was cancelled")
        elsif timed_out
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
