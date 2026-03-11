require "json"
require "yaml"
require "log"

require "./lsp_crystal/version"
require "./lsp_crystal/logger"
require "./lsp_crystal/protocol/types"
require "./lsp_crystal/protocol/uri"
require "./lsp_crystal/jsonrpc/types"
require "./lsp_crystal/jsonrpc/message"
require "./lsp_crystal/transport/header_parser"
require "./lsp_crystal/transport/stdio"
require "./lsp_crystal/document_store"
require "./lsp_crystal/crystal_tool"
require "./lsp_crystal/providers/diagnostics"
require "./lsp_crystal/providers/formatting"
require "./lsp_crystal/providers/definition"
require "./lsp_crystal/providers/hover"
require "./lsp_crystal/providers/completion"
require "./lsp_crystal/providers/document_symbol"
require "./lsp_crystal/providers/signature_help"
require "./lsp_crystal/providers/document_highlight"
require "./lsp_crystal/providers/folding_range"
require "./lsp_crystal/providers/selection_range"
require "./lsp_crystal/providers/implementation"
require "./lsp_crystal/providers/references"
require "./lsp_crystal/providers/code_action"
require "./lsp_crystal/providers/rename"
require "./lsp_crystal/handlers/lifecycle"
require "./lsp_crystal/handlers/text_sync"
require "./lsp_crystal/handlers/formatting"
require "./lsp_crystal/handlers/definition"
require "./lsp_crystal/handlers/hover"
require "./lsp_crystal/handlers/completion"
require "./lsp_crystal/handlers/document_symbol"
require "./lsp_crystal/handlers/signature_help"
require "./lsp_crystal/handlers/document_highlight"
require "./lsp_crystal/handlers/folding_range"
require "./lsp_crystal/handlers/selection_range"
require "./lsp_crystal/handlers/implementation"
require "./lsp_crystal/handlers/references"
require "./lsp_crystal/handlers/code_action"
require "./lsp_crystal/handlers/rename"
require "./lsp_crystal/dispatcher"
require "./lsp_crystal/server"

module Lsp::Crystal
  def self.run
    setup_logging
    server = Server.new
    server.run
  end
end

Lsp::Crystal.run
