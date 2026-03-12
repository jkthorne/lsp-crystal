module Lsp::Crystal::Handlers
  module Configuration
    def self.did_change(server : Lsp::Crystal::Server, message : JSONRPC::Message) : String?
      if params = message.params
        if settings = params["settings"]?
          server.configuration.update(settings)
          Log.info { "Configuration updated" }
        end
      end
      nil
    end
  end
end
