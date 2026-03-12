module Lsp::Crystal::Handlers
  module ExecuteCommand
    def self.handle(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      id = message.id.not_nil!
      params = message.params.not_nil!

      command = params["command"]?.try(&.as_s)
      unless command
        return JSONRPC::Response.error(id, JSONRPC::ErrorCode::InvalidParams, "Missing command")
      end

      case command
      when "crystal-lsp/expandMacro"
        Expand.handle(server, message)
      else
        JSONRPC::Response.error(id, JSONRPC::ErrorCode::InvalidParams, "Unknown command: #{command}")
      end
    end
  end
end
