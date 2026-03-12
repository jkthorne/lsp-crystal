module Lsp::Crystal
  class Dispatcher
    alias Handler = Proc(Server, JSONRPC::Message, String?)

    ASYNC_METHODS = Set{
      "textDocument/definition",
      "textDocument/typeDefinition",
      "textDocument/implementation",
      "textDocument/hover",
      "textDocument/formatting",
      "textDocument/rename",
      "textDocument/prepareCallHierarchy",
      "callHierarchy/incomingCalls",
      "callHierarchy/outgoingCalls",
    }

    def initialize(@server : Server)
      @handlers = Hash(String, Handler).new
      register_handlers
    end

    def dispatch(message : JSONRPC::Message) : String?
      method = message.method
      return nil unless method

      # Handle cancel request synchronously
      if method == "$/cancelRequest"
        handle_cancel_request(message)
        return nil
      end

      request_id = message.id

      if request_id && ASYNC_METHODS.includes?(method)
        dispatch_async(message, method, request_id.not_nil!)
        return nil
      end

      dispatch_sync(message, method, request_id)
    end

    private def dispatch_sync(message : JSONRPC::Message, method : String, request_id : JSONRPC::RequestId?) : String?
      start_time = Time.instant

      if handler = @handlers[method]?
        begin
          result = handler.call(@server, message)
          elapsed = Time.instant - start_time
          Log.info &.emit("Request handled", method: method, request_id: request_id.to_s, duration_ms: elapsed.total_milliseconds.to_s)
          result
        rescue ex
          elapsed = Time.instant - start_time
          Log.error &.emit("Handler error", method: method, request_id: request_id.to_s, duration_ms: elapsed.total_milliseconds.to_s, error: ex.message || "unknown")
          if id = request_id
            JSONRPC::Response.error(id, JSONRPC::ErrorCode::InternalError, ex.message || "Internal error")
          end
        end
      else
        Log.debug &.emit("Unhandled method", method: method)
        if id = request_id
          JSONRPC::Response.error(id, JSONRPC::ErrorCode::MethodNotFound, "Method not found: #{method}")
        end
      end
    end

    private def dispatch_async(message : JSONRPC::Message, method : String, id : JSONRPC::RequestId) : Nil
      handler = @handlers[method]?
      unless handler
        response = JSONRPC::Response.error(id, JSONRPC::ErrorCode::MethodNotFound, "Method not found: #{method}")
        @server.transport.write_message(response)
        return
      end

      token = CancellationToken.new
      tracker = @server.request_tracker

      fiber = spawn do
        start_time = Time.instant
        begin
          CrystalTool.set_cancellation(token)
          result = handler.call(@server, message)

          response_str = if token.cancelled?
                           JSONRPC::Response.error(id, JSONRPC::ErrorCode::RequestCancelled, "Request cancelled")
                         else
                           result
                         end

          elapsed = Time.instant - start_time
          Log.info &.emit("Async request handled", method: method, request_id: id.to_s, duration_ms: elapsed.total_milliseconds.to_s)

          if resp = response_str
            @server.transport.write_message(resp)
          end
        rescue ex
          elapsed = Time.instant - start_time
          Log.error &.emit("Async handler error", method: method, request_id: id.to_s, duration_ms: elapsed.total_milliseconds.to_s, error: ex.message || "unknown")
          response = JSONRPC::Response.error(id, JSONRPC::ErrorCode::InternalError, ex.message || "Internal error")
          @server.transport.write_message(response)
        ensure
          CrystalTool.clear_cancellation
          tracker.complete(id)
        end
      end

      tracker.track(id, method, token, fiber)
    end

    private def handle_cancel_request(message : JSONRPC::Message) : Nil
      if params = message.params
        if cancel_id = params["id"]?
          id = cancel_id.as_i64? || cancel_id.as_s?
          if id
            cancelled = @server.request_tracker.cancel(id)
            Log.info &.emit("Cancel request", request_id: id.to_s, found: cancelled.to_s)
          end
        end
      end
    end

    private def register_handlers
      # Phase 1: Lifecycle
      @handlers["initialize"] = Handler.new { |server, msg| Handlers::Lifecycle.initialize(server, msg) }
      @handlers["initialized"] = Handler.new { |server, msg| Handlers::Lifecycle.initialized(server, msg) }
      @handlers["shutdown"] = Handler.new { |server, msg| Handlers::Lifecycle.shutdown(server, msg) }
      @handlers["exit"] = Handler.new { |server, msg| Handlers::Lifecycle.exit(server, msg) }

      # Phase 2: Text document sync
      @handlers["textDocument/didOpen"] = Handler.new { |server, msg| Handlers::TextSync.did_open(server, msg) }
      @handlers["textDocument/didChange"] = Handler.new { |server, msg| Handlers::TextSync.did_change(server, msg) }
      @handlers["textDocument/didSave"] = Handler.new { |server, msg| Handlers::TextSync.did_save(server, msg) }
      @handlers["textDocument/didClose"] = Handler.new { |server, msg| Handlers::TextSync.did_close(server, msg) }

      # Phase 4-6: Formatting, Definition, Hover
      @handlers["textDocument/formatting"] = Handler.new { |server, msg| Handlers::Formatting.handle(server, msg) }
      @handlers["textDocument/definition"] = Handler.new { |server, msg| Handlers::Definition.handle(server, msg) }
      @handlers["textDocument/hover"] = Handler.new { |server, msg| Handlers::Hover.handle(server, msg) }

      # Phase 7-9: Completion, Document Symbols, Signature Help
      @handlers["textDocument/completion"] = Handler.new { |server, msg| Handlers::Completion.handle(server, msg) }
      @handlers["textDocument/documentSymbol"] = Handler.new { |server, msg| Handlers::DocumentSymbol.handle(server, msg) }
      @handlers["textDocument/signatureHelp"] = Handler.new { |server, msg| Handlers::SignatureHelp.handle(server, msg) }

      # Phase 10: Workspace Symbols
      @handlers["workspace/symbol"] = Handler.new { |server, msg| Handlers::WorkspaceSymbol.handle(server, msg) }

      # Document Highlight, Folding Range
      @handlers["textDocument/documentHighlight"] = Handler.new { |server, msg| Handlers::DocumentHighlight.handle(server, msg) }
      @handlers["textDocument/foldingRange"] = Handler.new { |server, msg| Handlers::FoldingRange.handle(server, msg) }
      @handlers["textDocument/selectionRange"] = Handler.new { |server, msg| Handlers::SelectionRange.handle(server, msg) }
      @handlers["textDocument/implementation"] = Handler.new { |server, msg| Handlers::Implementation.handle(server, msg) }

      # Phase 12: References
      @handlers["textDocument/references"] = Handler.new { |server, msg| Handlers::References.handle(server, msg) }
      @handlers["textDocument/codeAction"] = Handler.new { |server, msg| Handlers::CodeAction.handle(server, msg) }
      @handlers["textDocument/rename"] = Handler.new { |server, msg| Handlers::Rename.handle(server, msg) }
      @handlers["textDocument/prepareRename"] = Handler.new { |server, msg| Handlers::Rename.prepare(server, msg) }

      # Phase 14: Type Definition
      @handlers["textDocument/typeDefinition"] = Handler.new { |server, msg| Handlers::TypeDefinition.handle(server, msg) }

      # Phase 13: Semantic Tokens, Call Hierarchy, Inlay Hints, Code Lens
      @handlers["textDocument/semanticTokens/full"] = Handler.new { |server, msg| Handlers::SemanticTokens.full(server, msg) }
      @handlers["textDocument/prepareCallHierarchy"] = Handler.new { |server, msg| Handlers::CallHierarchy.prepare(server, msg) }
      @handlers["callHierarchy/incomingCalls"] = Handler.new { |server, msg| Handlers::CallHierarchy.incoming_calls(server, msg) }
      @handlers["callHierarchy/outgoingCalls"] = Handler.new { |server, msg| Handlers::CallHierarchy.outgoing_calls(server, msg) }
      @handlers["textDocument/inlayHint"] = Handler.new { |server, msg| Handlers::InlayHints.handle(server, msg) }
      @handlers["textDocument/codeLens"] = Handler.new { |server, msg| Handlers::CodeLens.handle(server, msg) }

      # Linked Editing Range
      @handlers["textDocument/linkedEditingRange"] = Handler.new { |server, msg| Handlers::LinkedEditingRange.handle(server, msg) }

      # Configuration
      @handlers["workspace/didChangeConfiguration"] = Handler.new { |server, msg| Handlers::Configuration.did_change(server, msg) }
      @handlers["workspace/didChangeWorkspaceFolders"] = Handler.new { |server, msg| Handlers::WorkspaceFolders.did_change(server, msg) }

      # File watching
      @handlers["workspace/didChangeWatchedFiles"] = Handler.new { |server, msg| Handlers::DidChangeWatchedFiles.handle(server, msg) }
    end
  end
end
