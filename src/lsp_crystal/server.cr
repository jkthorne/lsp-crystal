require "yaml"

module Lsp::Crystal
  class Server
    property? initialized : Bool = false
    property? shutdown_requested : Bool = false
    getter transport : Transport::Stdio
    getter document_store : DocumentStore
    getter workspace_root : String?
    getter main_file : String?
    getter workspace_index : WorkspaceIndex
    getter configuration : Configuration
    getter workspace_folders : Array(String)
    getter request_tracker : RequestTracker
    getter ast_cache : AST::Cache
    @dispatcher : Dispatcher?
    @diagnostics_channel : Channel(String)
    @pending_diagnostics : Hash(String, Time::Instant)
    @pending_mutex : Mutex
    @diagnostics_hashes : Hash(String, UInt64)
    @diagnostics_hashes_mutex : Mutex
    @published_diagnostics : Hash(String, Array(Providers::Diagnostics::Diagnostic))
    @published_diagnostics_mutex : Mutex
    @last_diagnostics_files : Hash(String, Set(String))
    @last_diagnostics_files_mutex : Mutex
    @active_uri : String?
    @next_request_id : Atomic(Int64)

    def initialize(@transport : Transport::Stdio = Transport::Stdio.new)
      @document_store = DocumentStore.new
      @workspace_index = WorkspaceIndex.new
      @configuration = Configuration.new
      @workspace_folders = [] of String
      @request_tracker = RequestTracker.new
      @ast_cache = AST::Cache.new
      @diagnostics_channel = Channel(String).new(100)
      @pending_diagnostics = Hash(String, Time::Instant).new
      @pending_mutex = Mutex.new
      @diagnostics_hashes = Hash(String, UInt64).new
      @diagnostics_hashes_mutex = Mutex.new
      @published_diagnostics = Hash(String, Array(Providers::Diagnostics::Diagnostic)).new
      @published_diagnostics_mutex = Mutex.new
      @last_diagnostics_files = Hash(String, Set(String)).new
      @last_diagnostics_files_mutex = Mutex.new
      @next_request_id = Atomic(Int64).new(1_i64)
      @shutdown_channel = Channel(Nil).new(1)
      spawn_diagnostics_worker
      install_signal_handlers
    end

    private def dispatcher : Dispatcher
      @dispatcher ||= Dispatcher.new(self)
    end

    def run : Nil
      Log.info { "Crystal LSP server starting (v#{VERSION})" }
      loop do
        json = @transport.read_message
        message = begin
          JSONRPC::Message.from_json(json)
        rescue ex : JSON::ParseException
          Log.error { "JSON parse error: #{ex.message}" }
          error_response = JSONRPC::Response.error(nil, JSONRPC::ErrorCode::ParseError, "Parse error")
          @transport.write_message(error_response)
          next
        end

        response = dispatcher.dispatch(message)
        @transport.write_message(response) if response
      rescue ex : IO::EOFError
        Log.info { "Client disconnected" }
        break
      rescue ex
        Log.error { "Unexpected error: #{ex.message}" }
      end
    ensure
      graceful_shutdown
    end

    def graceful_shutdown : Nil
      Log.info { "Shutting down gracefully..." }
      @request_tracker.cancel_all
      @diagnostics_channel.close rescue nil
      Log.info { "Server stopped" }
    end

    def send_notification(method : String, params) : Nil
      json = JSONRPC::Response.notification(method, params)
      @transport.write_message(json)
    end

    def send_request(method : String, params) : Int64
      id = @next_request_id.add(1) - 1
      json = JSON.build do |j|
        j.object do
          j.field "jsonrpc", "2.0"
          j.field "id", id
          j.field "method", method
          j.field "params" do
            params.to_json(j)
          end
        end
      end
      @transport.write_message(json)
      id
    end

    def schedule_diagnostics(uri : String) : Nil
      debounce = @configuration.diagnostics_debounce
      @active_uri = uri
      @pending_mutex.synchronize do
        @pending_diagnostics[uri] = Time.instant + debounce
      end
      @diagnostics_channel.send(uri) rescue nil
    end

    def invalidate_diagnostics_cache(uri : String) : Nil
      @diagnostics_hashes_mutex.synchronize do
        @diagnostics_hashes.delete(uri)
      end
    end

    # Publish diagnostics only if they differ from last published set
    def publish_diagnostics_if_changed(uri : String, diagnostics : Array(Providers::Diagnostics::Diagnostic)) : Nil
      @published_diagnostics_mutex.synchronize do
        cached = @published_diagnostics[uri]?
        if cached && diagnostics_equal?(cached, diagnostics)
          Log.debug { "Skipping publish for #{uri} (diagnostics unchanged)" }
          return
        end
        @published_diagnostics[uri] = diagnostics
      end
      send_notification("textDocument/publishDiagnostics", {
        uri:         uri,
        diagnostics: diagnostics,
      })
    end

    def clear_published_diagnostics(uri : String) : Nil
      @published_diagnostics_mutex.synchronize do
        @published_diagnostics.delete(uri)
      end
    end

    private def diagnostics_equal?(a : Array(Providers::Diagnostics::Diagnostic), b : Array(Providers::Diagnostics::Diagnostic)) : Bool
      return false unless a.size == b.size
      a.each_with_index do |diag, i|
        other = b[i]
        return false unless diag.range.start.line == other.range.start.line &&
                            diag.range.start.character == other.range.start.character &&
                            diag.range.end_pos.line == other.range.end_pos.line &&
                            diag.range.end_pos.character == other.range.end_pos.character &&
                            diag.severity == other.severity &&
                            diag.source == other.source &&
                            diag.message == other.message
      end
      true
    end

    def detect_project(root_uri : String) : Nil
      @workspace_root = URI.uri_to_path(root_uri)
      root = @workspace_root.not_nil!
      shard_path = File.join(root, "shard.yml")

      if File.exists?(shard_path)
        yaml = YAML.parse(File.read(shard_path))
        if targets = yaml["targets"]?
          targets.as_h.each_value do |target|
            if main = target["main"]?
              @main_file = File.join(root, main.as_s)
              Log.info { "Detected main file: #{@main_file}" }
              break
            end
          end
        end
        @main_file ||= File.join(root, "src", "#{yaml["name"]}.cr")
      end

      Log.info { "Workspace root: #{root}" }

      # Background-index the workspace
      spawn do
        send_progress_begin("indexing", "Indexing workspace...")
        @workspace_index.index(root)
        send_progress_end("indexing")
      end
    end

    def add_workspace_folder(path : String) : Nil
      @workspace_folders << path unless @workspace_folders.includes?(path)
      # Re-index to include the new folder
      spawn { @workspace_index.index_folder(path) }
    end

    def remove_workspace_folder(path : String) : Nil
      @workspace_folders.delete(path)
      @workspace_index.remove_folder(path)
    end

    def send_progress_begin(token : String, title : String, message : String? = nil) : Nil
      send_notification("$/progress", {
        token: token,
        value: {kind: "begin", title: title, message: message},
      })
    end

    def send_progress_report(token : String, message : String? = nil, percentage : Int32? = nil) : Nil
      value = Hash(String, String | Int32).new
      value["kind"] = "report"
      value["message"] = message if message
      value["percentage"] = percentage if percentage
      send_notification("$/progress", {token: token, value: value})
    end

    def send_progress_end(token : String, message : String? = nil) : Nil
      send_notification("$/progress", {
        token: token,
        value: {kind: "end", message: message},
      })
    end

    private def install_signal_handlers
      Signal::TERM.trap do
        Log.info { "Received SIGTERM" }
        @shutdown_channel.send(nil) rescue nil
        graceful_shutdown
        ::exit(0)
      end
      Signal::INT.trap do
        Log.info { "Received SIGINT" }
        @shutdown_channel.send(nil) rescue nil
        graceful_shutdown
        ::exit(0)
      end
    end

    private def spawn_diagnostics_worker
      spawn do
        loop do
          uri = @diagnostics_channel.receive
          # Debounce: wait then check if this is still the latest request
          sleep @configuration.diagnostics_debounce
          # Drain any duplicate URIs from channel
          uris_to_run = Set(String).new
          uris_to_run << uri
          loop do
            select
            when more_uri = @diagnostics_channel.receive
              uris_to_run << more_uri
            else
              break
            end
          end

          # Sort so active URI runs first
          sorted_uris = uris_to_run.to_a
          if active = @active_uri
            sorted_uris.sort_by! { |u| u == active ? 0 : 1 }
          end

          # Only run diagnostics for URIs whose debounce has elapsed
          sorted_uris.each do |pending_uri|
            scheduled_at = @pending_mutex.synchronize { @pending_diagnostics[pending_uri]? }
            next unless scheduled_at
            next if Time.instant < scheduled_at
            run_diagnostics(pending_uri)
          end
        rescue Channel::ClosedError
          break
        rescue ex
          Log.error { "Diagnostics worker error: #{ex.message}" }
        end
      end
    end

    private def run_diagnostics(uri : String) : Nil
      doc = @document_store.get(uri)
      return unless doc

      # Content hash caching: skip if content unchanged since last run
      content_hash = doc.content.hash.to_u64
      cached_hash = @diagnostics_hashes_mutex.synchronize { @diagnostics_hashes[uri]? }
      if cached_hash == content_hash
        Log.debug { "Skipping diagnostics for #{uri} (content unchanged)" }
        return
      end

      file_path = doc.path
      Log.debug { "Running diagnostics for #{file_path}" }

      result = if File.exists?(file_path) && File.read(file_path) == doc.content
                 CrystalTool.check(file_path)
               else
                 CrystalTool.check_content(doc.content, file_path)
               end

      # Store hash after successful run
      @diagnostics_hashes_mutex.synchronize { @diagnostics_hashes[uri] = content_hash }

      if result.success
        # Clear diagnostics for triggering file
        publish_diagnostics_if_changed(uri, [] of Providers::Diagnostics::Diagnostic)
        # Clear diagnostics for files that had errors in the previous run
        clear_stale_file_diagnostics(uri, Set(String).new)
      else
        diags_by_file = Providers::Diagnostics.parse_output_by_file(result.stderr)

        # Publish diagnostics routed to each file
        new_files = Set(String).new
        diags_by_file.each do |diag_path, diags|
          diag_uri = URI.path_to_uri(diag_path)
          new_files << diag_uri
          publish_diagnostics_if_changed(diag_uri, diags)
        end

        # If the triggering file had no errors itself, clear it
        unless new_files.includes?(uri)
          publish_diagnostics_if_changed(uri, [] of Providers::Diagnostics::Diagnostic)
        end

        # Clear diagnostics for files that had errors last time but not now
        clear_stale_file_diagnostics(uri, new_files)
      end
    rescue ex
      Log.error { "Diagnostics error for #{uri}: #{ex.message}" }
    end

    private def clear_stale_file_diagnostics(trigger_uri : String, current_files : Set(String)) : Nil
      previous_files = @last_diagnostics_files_mutex.synchronize { @last_diagnostics_files[trigger_uri]? }
      if previous_files
        (previous_files - current_files).each do |stale_uri|
          publish_diagnostics_if_changed(stale_uri, [] of Providers::Diagnostics::Diagnostic)
        end
      end
      @last_diagnostics_files_mutex.synchronize { @last_diagnostics_files[trigger_uri] = current_files }
    end
  end
end
