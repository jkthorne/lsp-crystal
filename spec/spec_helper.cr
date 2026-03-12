require "spec"
require "json"
require "file_utils"
require "../src/lsp_crystal/version"
require "../src/lsp_crystal/logger"
require "../src/lsp_crystal/protocol/types"
require "../src/lsp_crystal/protocol/uri"
require "../src/lsp_crystal/jsonrpc/types"
require "../src/lsp_crystal/jsonrpc/message"
require "../src/lsp_crystal/transport/header_parser"
require "../src/lsp_crystal/transport/stdio"
require "../src/lsp_crystal/document_store"
require "../src/lsp_crystal/cancellation_token"
require "../src/lsp_crystal/request_tracker"
require "../src/lsp_crystal/crystal_tool"
require "../src/lsp_crystal/ast/parser"
require "../src/lsp_crystal/ast/cache"
require "../src/lsp_crystal/ast/indexed_symbol"
require "../src/lsp_crystal/ast/lexer_tokenizer"
require "../src/lsp_crystal/providers/macro_expander"
require "../src/lsp_crystal/ast/visitors/symbol_visitor"
require "../src/lsp_crystal/ast/visitors/reference_visitor"
require "../src/lsp_crystal/ast/visitors/context_visitor"
require "../src/lsp_crystal/ast/visitors/call_visitor"
require "../src/lsp_crystal/ast/visitors/index_visitor"
require "../src/lsp_crystal/ast/index"
require "../src/lsp_crystal/providers/diagnostics"
require "../src/lsp_crystal/providers/formatting"
require "../src/lsp_crystal/providers/definition"
require "../src/lsp_crystal/providers/hover"
require "../src/lsp_crystal/providers/completion"
require "../src/lsp_crystal/providers/document_symbol"
require "../src/lsp_crystal/providers/workspace_symbol"
require "../src/lsp_crystal/providers/signature_help"
require "../src/lsp_crystal/providers/document_highlight"
require "../src/lsp_crystal/providers/folding_range"
require "../src/lsp_crystal/providers/selection_range"
require "../src/lsp_crystal/providers/implementation"
require "../src/lsp_crystal/providers/references"
require "../src/lsp_crystal/providers/code_action"
require "../src/lsp_crystal/providers/rename"
require "../src/lsp_crystal/providers/type_definition"
require "../src/lsp_crystal/providers/semantic_tokens"
require "../src/lsp_crystal/providers/call_hierarchy"
require "../src/lsp_crystal/providers/inlay_hints"
require "../src/lsp_crystal/providers/code_lens"
require "../src/lsp_crystal/providers/linked_editing_range"
require "../src/lsp_crystal/providers/type_hierarchy"
require "../src/lsp_crystal/workspace_index"
require "../src/lsp_crystal/require_graph"
require "../src/lsp_crystal/configuration"
require "../src/lsp_crystal/handlers/lifecycle"
require "../src/lsp_crystal/handlers/text_sync"
require "../src/lsp_crystal/handlers/formatting"
require "../src/lsp_crystal/handlers/definition"
require "../src/lsp_crystal/handlers/hover"
require "../src/lsp_crystal/handlers/completion"
require "../src/lsp_crystal/handlers/document_symbol"
require "../src/lsp_crystal/handlers/workspace_symbol"
require "../src/lsp_crystal/handlers/signature_help"
require "../src/lsp_crystal/handlers/document_highlight"
require "../src/lsp_crystal/handlers/folding_range"
require "../src/lsp_crystal/handlers/selection_range"
require "../src/lsp_crystal/handlers/implementation"
require "../src/lsp_crystal/handlers/references"
require "../src/lsp_crystal/handlers/code_action"
require "../src/lsp_crystal/handlers/rename"
require "../src/lsp_crystal/handlers/type_definition"
require "../src/lsp_crystal/handlers/semantic_tokens"
require "../src/lsp_crystal/handlers/call_hierarchy"
require "../src/lsp_crystal/handlers/inlay_hints"
require "../src/lsp_crystal/handlers/code_lens"
require "../src/lsp_crystal/handlers/linked_editing_range"
require "../src/lsp_crystal/handlers/type_hierarchy"
require "../src/lsp_crystal/handlers/configuration"
require "../src/lsp_crystal/handlers/workspace_folders"
require "../src/lsp_crystal/handlers/did_change_watched_files"
require "../src/lsp_crystal/dispatcher"
require "../src/lsp_crystal/server"

class TestClient
  getter server : Lsp::Crystal::Server

  def initialize
    input_read, @input_write = IO.pipe
    @output_read, output_write = IO.pipe
    transport = Lsp::Crystal::Transport::Stdio.new(input: input_read, output: output_write)
    @server = Lsp::Crystal::Server.new(transport)
    spawn { @server.run }
    Fiber.yield
  end

  def send_request(id, method, params = nil)
    msg = {jsonrpc: "2.0", id: id, method: method, params: params}.to_json
    @input_write << "Content-Length: #{msg.bytesize}\r\n\r\n"
    @input_write << msg
    @input_write.flush
  end

  def send_notification(method, params = nil)
    msg = {jsonrpc: "2.0", method: method, params: params}.to_json
    @input_write << "Content-Length: #{msg.bytesize}\r\n\r\n"
    @input_write << msg
    @input_write.flush
  end

  def read_raw_message : JSON::Any
    line = @output_read.read_line("\r\n")
    line = line.rstrip("\r\n")
    length = line.split(": ")[1].to_i
    @output_read.read_line("\r\n")
    body = Bytes.new(length)
    @output_read.read_fully(body)
    JSON.parse(String.new(body))
  end

  def read_response : JSON::Any
    loop do
      msg = read_raw_message
      # Skip notifications (no id field) — e.g. $/progress, publishDiagnostics
      # Also skip server→client requests (have both id and method) — e.g. client/registerCapability
      next unless msg["id"]?
      next if msg["method"]?
      return msg
    end
  end

  def try_read_response(timeout : Time::Span = 100.milliseconds) : JSON::Any?
    ch = Channel(JSON::Any?).new(1)
    spawn do
      ch.send(read_response)
    rescue
      ch.send(nil)
    end
    select
    when result = ch.receive
      result
    when timeout(timeout)
      nil
    end
  end

  def try_read_notification(timeout : Time::Span = 100.milliseconds) : JSON::Any?
    ch = Channel(JSON::Any?).new(1)
    spawn do
      ch.send(read_raw_message)
    rescue
      ch.send(nil)
    end
    select
    when result = ch.receive
      result
    when timeout(timeout)
      nil
    end
  end

  def send_raw(data : String)
    @input_write << data
    @input_write.flush
  end

  def initialize_server
    send_request(1, "initialize", {processId: 1, rootUri: "file:///tmp", capabilities: {} of String => String})
    read_response
    send_notification("initialized")
    # Consume the client/registerCapability request sent by the server
    Fiber.yield
  end

  def close
    @input_write.close
  end
end
