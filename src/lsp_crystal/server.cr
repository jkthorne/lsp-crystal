require "yaml"

module Lsp::Crystal
  class Server
    DIAGNOSTICS_DEBOUNCE = 500.milliseconds

    property? initialized : Bool = false
    property? shutdown_requested : Bool = false
    getter transport : Transport::Stdio
    getter document_store : DocumentStore
    getter workspace_root : String?
    getter main_file : String?
    getter workspace_index : WorkspaceIndex
    getter configuration : Configuration
    getter workspace_folders : Array(String)
    @dispatcher : Dispatcher?
    @diagnostics_channel : Channel(String)
    @pending_diagnostics : Hash(String, Time::Instant)
    @pending_mutex : Mutex

    def initialize(@transport : Transport::Stdio = Transport::Stdio.new)
      @document_store = DocumentStore.new
      @workspace_index = WorkspaceIndex.new
      @configuration = Configuration.new
      @workspace_folders = [] of String
      @diagnostics_channel = Channel(String).new(100)
      @pending_diagnostics = Hash(String, Time::Instant).new
      @pending_mutex = Mutex.new
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
      @diagnostics_channel.close rescue nil
      Log.info { "Server stopped" }
    end

    def send_notification(method : String, params) : Nil
      json = JSONRPC::Response.notification(method, params)
      @transport.write_message(json)
    end

    def schedule_diagnostics(uri : String) : Nil
      @pending_mutex.synchronize do
        @pending_diagnostics[uri] = Time.instant + DIAGNOSTICS_DEBOUNCE
      end
      @diagnostics_channel.send(uri) rescue nil
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
          sleep DIAGNOSTICS_DEBOUNCE
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

          # Only run diagnostics for URIs whose debounce has elapsed
          uris_to_run.each do |pending_uri|
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

      file_path = doc.path
      Log.debug { "Running diagnostics for #{file_path}" }

      diagnostics = if File.exists?(file_path) && File.read(file_path) == doc.content
                      Providers::Diagnostics.run(file_path)
                    else
                      Providers::Diagnostics.run_content(doc.content, file_path)
                    end

      send_notification("textDocument/publishDiagnostics", {
        uri:         uri,
        diagnostics: diagnostics,
      })
    rescue ex
      Log.error { "Diagnostics error for #{uri}: #{ex.message}" }
    end
  end
end
