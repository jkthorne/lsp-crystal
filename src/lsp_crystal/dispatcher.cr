module Lsp::Crystal
  class Dispatcher
    alias Handler = Proc(Server, JSONRPC::Message, String?)

    def initialize(@server : Server)
      @handlers = Hash(String, Handler).new
      register_handlers
    end

    def dispatch(message : JSONRPC::Message) : String?
      method = message.method
      return nil unless method

      if handler = @handlers[method]?
        begin
          handler.call(@server, message)
        rescue ex
          Log.error { "Handler error for #{method}: #{ex.message}" }
          if id = message.id
            JSONRPC::Response.error(id, JSONRPC::ErrorCode::InternalError, ex.message || "Internal error")
          end
        end
      else
        Log.debug { "Unhandled method: #{method}" }
        if id = message.id
          JSONRPC::Response.error(id, JSONRPC::ErrorCode::MethodNotFound, "Method not found: #{method}")
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
    end
  end
end
