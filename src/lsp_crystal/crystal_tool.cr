module Lsp::Crystal
  class CrystalTool
    DEFAULT_TIMEOUT = 30.seconds

    @@fiber_tokens = Hash(Fiber, CancellationToken).new
    @@fiber_tokens_mutex = Mutex.new

    # Request coalescing: pending requests keyed by "tool:path:line:col"
    @@pending_requests = Hash(String, Array(Channel(ToolResult))).new
    @@pending_mutex = Mutex.new

    struct ToolResult
      property success : Bool
      property stdout : String
      property stderr : String

      def initialize(@success, @stdout, @stderr)
      end
    end

    # Structured expand output
    struct ExpandExpansion
      property original_source : String
      property expanded_sources : Array(String)

      def initialize(@original_source, @expanded_sources)
      end
    end

    struct ExpandOutput
      property status : String
      property expansions : Array(ExpandExpansion)

      def initialize(@status, @expansions)
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

    # Run with request coalescing: if another fiber is already running the same
    # tool invocation, wait for its result instead of spawning a duplicate process.
    def self.run_coalesced(coalesce_key : String, args : Array(String), input : String? = nil, timeout : Time::Span = DEFAULT_TIMEOUT) : ToolResult
      wait_channel : Channel(ToolResult)? = nil

      @@pending_mutex.synchronize do
        if waiters = @@pending_requests[coalesce_key]?
          # Another fiber is already running this — subscribe
          ch = Channel(ToolResult).new(1)
          waiters << ch
          wait_channel = ch
        else
          # We're the first — register ourselves
          @@pending_requests[coalesce_key] = [] of Channel(ToolResult)
        end
      end

      if ch = wait_channel
        # Wait for the leader to broadcast the result
        return ch.receive
      end

      # We're the leader: run the tool
      result = run(args, input, timeout)

      # Broadcast to all waiters and clean up
      waiters = @@pending_mutex.synchronize do
        @@pending_requests.delete(coalesce_key) || [] of Channel(ToolResult)
      end
      waiters.each { |w| w.send(result) rescue nil }

      result
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

    # Get type context at cursor position (with coalescing)
    def self.context(file_path : String, line : Int32, column : Int32) : ToolResult
      cursor = "#{file_path}:#{line}:#{column}"
      key = "context:#{cursor}"
      run_coalesced(key, ["tool", "context", "-c", cursor, "-f", "json", file_path])
    end

    # Find implementations/definitions (with coalescing)
    def self.implementations(file_path : String, line : Int32, column : Int32) : ToolResult
      cursor = "#{file_path}:#{line}:#{column}"
      key = "implementations:#{cursor}"
      run_coalesced(key, ["tool", "implementations", "-c", cursor, "-f", "json", file_path])
    end

    # Format code via stdin
    def self.format(content : String) : ToolResult
      run(["tool", "format", "-"], input: content)
    end

    # Expand macros at cursor position (with coalescing)
    def self.expand(file_path : String, line : Int32, column : Int32, timeout : Time::Span = DEFAULT_TIMEOUT) : ToolResult
      cursor = "#{file_path}:#{line}:#{column}"
      key = "expand:#{cursor}"
      run_coalesced(key, ["tool", "expand", "-c", cursor, "-f", "json", file_path], timeout: timeout)
    end

    # Expand macros for in-memory content using a temp file
    def self.expand_content(content : String, filename : String, line : Int32, column : Int32, timeout : Time::Span = DEFAULT_TIMEOUT) : ToolResult
      temp = File.tempname("crystal-lsp", ".cr")
      begin
        File.write(temp, content)
        result = expand(temp, line, column, timeout)
        ToolResult.new(
          result.success,
          result.stdout.gsub(temp, filename),
          result.stderr.gsub(temp, filename)
        )
      ensure
        File.delete(temp) rescue nil
      end
    end

    # Parse the JSON output of `crystal tool expand -f json`
    def self.parse_expand_result(result : ToolResult) : ExpandOutput?
      return nil unless result.success

      begin
        json = JSON.parse(result.stdout)
      rescue
        return nil
      end

      status = json["status"]?.try(&.as_s) || return nil
      return nil unless status == "ok"

      expansions = [] of ExpandExpansion
      if exps = json["expansions"]?.try(&.as_a)
        exps.each do |exp|
          original = exp["original_source"]?.try(&.as_s) || ""
          expanded = exp["expanded_source"]?.try(&.as_s)

          expanded_sources = if expanded
                               [expanded]
                             elsif exp_arr = exp["expanded_sources"]?.try(&.as_a)
                               exp_arr.compact_map(&.as_s?)
                             else
                               [] of String
                             end

          expansions << ExpandExpansion.new(original, expanded_sources)
        end
      end

      ExpandOutput.new(status, expansions)
    end
  end
end
