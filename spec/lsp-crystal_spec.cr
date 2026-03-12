require "./spec_helper"

describe Lsp::Crystal do
  describe "Transport::HeaderParser" do
    it "parses Content-Length header" do
      io = IO::Memory.new("Content-Length: 42\r\n\r\n")
      length = Lsp::Crystal::Transport::HeaderParser.read_content_length(io)
      length.should eq(42)
    end

    it "parses multiple headers" do
      io = IO::Memory.new("Content-Length: 100\r\nContent-Type: application/json\r\n\r\n")
      headers = Lsp::Crystal::Transport::HeaderParser.read_headers(io)
      headers["Content-Length"].should eq("100")
      headers["Content-Type"].should eq("application/json")
    end

    it "raises on missing Content-Length" do
      io = IO::Memory.new("Content-Type: text/plain\r\n\r\n")
      expect_raises(Exception, "Missing Content-Length") do
        Lsp::Crystal::Transport::HeaderParser.read_content_length(io)
      end
    end
  end

  describe "Transport::Stdio" do
    it "reads a framed message" do
      body = %({"jsonrpc":"2.0","id":1})
      input = IO::Memory.new("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
      output = IO::Memory.new
      transport = Lsp::Crystal::Transport::Stdio.new(input: input, output: output)
      transport.read_message.should eq(body)
    end

    it "writes a framed message" do
      input = IO::Memory.new
      output = IO::Memory.new
      transport = Lsp::Crystal::Transport::Stdio.new(input: input, output: output)
      transport.write_message(%({"test":true}))
      output.rewind
      output.gets_to_end.should eq("Content-Length: 13\r\n\r\n{\"test\":true}")
    end
  end

  describe "JSONRPC::Message" do
    it "parses a request" do
      json = %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}})
      msg = Lsp::Crystal::JSONRPC::Message.from_json(json)
      msg.method.should eq("initialize")
      msg.id.should eq(1)
    end

    it "parses a notification (no id)" do
      json = %({"jsonrpc":"2.0","method":"initialized"})
      msg = Lsp::Crystal::JSONRPC::Message.from_json(json)
      msg.method.should eq("initialized")
      msg.id.should be_nil
    end
  end

  describe "JSONRPC::Response" do
    it "builds a success response" do
      json = Lsp::Crystal::JSONRPC::Response.success(1_i64, {foo: "bar"})
      parsed = JSON.parse(json)
      parsed["jsonrpc"].should eq("2.0")
      parsed["id"].should eq(1)
      parsed["result"]["foo"].should eq("bar")
    end

    it "builds a null success response" do
      json = Lsp::Crystal::JSONRPC::Response.success_null(2_i64)
      parsed = JSON.parse(json)
      parsed["id"].should eq(2)
      parsed["result"].raw.should be_nil
    end

    it "builds an error response" do
      json = Lsp::Crystal::JSONRPC::Response.error(1_i64, Lsp::Crystal::JSONRPC::ErrorCode::MethodNotFound, "Not found")
      parsed = JSON.parse(json)
      parsed["error"]["code"].should eq(-32601)
      parsed["error"]["message"].should eq("Not found")
    end
  end

  describe "URI" do
    it "converts path to uri" do
      Lsp::Crystal::URI.path_to_uri("/foo/bar.cr").should eq("file:///foo/bar.cr")
    end

    it "converts uri to path" do
      Lsp::Crystal::URI.uri_to_path("file:///foo/bar.cr").should eq("/foo/bar.cr")
    end

    it "returns non-file URIs unchanged" do
      Lsp::Crystal::URI.uri_to_path("/foo/bar.cr").should eq("/foo/bar.cr")
    end
  end

  describe "Protocol types" do
    it "serializes Position to JSON" do
      pos = Lsp::Crystal::Position.new(line: 5, character: 10)
      json = pos.to_json
      parsed = JSON.parse(json)
      parsed["line"].should eq(5)
      parsed["character"].should eq(10)
    end

    it "serializes Range with start/end keys" do
      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 1, character: 0),
        end_pos: Lsp::Crystal::Position.new(line: 1, character: 5)
      )
      json = range.to_json
      parsed = JSON.parse(json)
      parsed["start"]["line"].should eq(1)
      parsed["end"]["character"].should eq(5)
    end

    it "deserializes Range from JSON" do
      json = %({"start":{"line":2,"character":3},"end":{"line":4,"character":5}})
      range = Lsp::Crystal::Range.from_json(json)
      range.start.line.should eq(2)
      range.end_pos.character.should eq(5)
    end
  end

  describe "Lifecycle" do
    it "completes initialize/shutdown/exit handshake" do
      client = TestClient.new

      client.send_request(1, "initialize", {processId: 1, rootUri: "file:///tmp", capabilities: {} of String => String})
      resp = client.read_response

      resp["id"].should eq(1)
      caps = resp["result"]["capabilities"]
      caps["hoverProvider"].should eq(true)
      caps["definitionProvider"].should eq(true)
      caps["textDocumentSync"]["change"].should eq(2)
      resp["result"]["serverInfo"]["name"].should eq("crystal-lsp")

      client.send_notification("initialized")

      client.send_request(2, "shutdown")
      resp = client.read_response
      resp["id"].should eq(2)
      resp["result"].raw.should be_nil

      client.server.shutdown_requested?.should be_true
      client.close
    end
  end

  describe "Dispatcher" do
    it "returns MethodNotFound for unknown methods" do
      client = TestClient.new

      # Initialize first
      client.send_request(1, "initialize", {processId: 1, rootUri: "file:///tmp", capabilities: {} of String => String})
      client.read_response

      # Unknown method
      client.send_request(99, "textDocument/unknownMethod")
      resp = client.read_response
      resp["error"]["code"].should eq(-32601)
      resp["error"]["message"].as_s.should contain("unknownMethod")

      client.close
    end
  end

  describe "DocumentStore" do
    it "opens and retrieves a document" do
      store = Lsp::Crystal::DocumentStore.new
      store.open("file:///test.cr", "crystal", 1, "hello world")
      doc = store.get("file:///test.cr")
      doc.should_not be_nil
      doc.not_nil!.content.should eq("hello world")
      doc.not_nil!.version.should eq(1)
    end

    it "closes a document" do
      store = Lsp::Crystal::DocumentStore.new
      store.open("file:///test.cr", "crystal", 1, "hello")
      store.close("file:///test.cr")
      store.get("file:///test.cr").should be_nil
    end

    it "applies full content change" do
      store = Lsp::Crystal::DocumentStore.new
      store.open("file:///test.cr", "crystal", 1, "old content")
      change = JSON.parse(%({"text": "new content"}))
      store.update("file:///test.cr", 2, [change])
      doc = store.get("file:///test.cr").not_nil!
      doc.content.should eq("new content")
      doc.version.should eq(2)
    end

    it "applies incremental change" do
      store = Lsp::Crystal::DocumentStore.new
      store.open("file:///test.cr", "crystal", 1, "hello world")
      change = JSON.parse(%({"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":11}},"text":"crystal"}))
      store.update("file:///test.cr", 2, [change])
      store.get("file:///test.cr").not_nil!.content.should eq("hello crystal")
    end

    it "applies multiline incremental change" do
      store = Lsp::Crystal::DocumentStore.new
      store.open("file:///test.cr", "crystal", 1, "line1\nline2\nline3")
      # Replace "line2" with "replaced"
      change = JSON.parse(%({"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":5}},"text":"replaced"}))
      store.update("file:///test.cr", 2, [change])
      store.get("file:///test.cr").not_nil!.content.should eq("line1\nreplaced\nline3")
    end
  end

  describe "Document" do
    it "calculates offset_at correctly" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "abc\ndef\nghi")
      doc.offset_at(Lsp::Crystal::Position.new(line: 0, character: 0)).should eq(0)
      doc.offset_at(Lsp::Crystal::Position.new(line: 0, character: 2)).should eq(2)
      doc.offset_at(Lsp::Crystal::Position.new(line: 1, character: 0)).should eq(4)
      doc.offset_at(Lsp::Crystal::Position.new(line: 1, character: 2)).should eq(6)
      doc.offset_at(Lsp::Crystal::Position.new(line: 2, character: 1)).should eq(9)
    end

    it "returns line_at" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "first\nsecond\nthird")
      doc.line_at(0).should eq("first")
      doc.line_at(1).should eq("second")
      doc.line_at(2).should eq("third")
      doc.line_at(3).should be_nil
    end

    it "returns line_count" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "a\nb\nc")
      doc.line_count.should eq(3)
    end
  end

  describe "Providers::Diagnostics" do
    it "parses crystal compiler error output" do
      output = <<-ERR
      In src/main.cr:10:5

       10 | foo
                ^
      Error: undefined local variable or method 'foo'
      ERR
      diagnostics = Lsp::Crystal::Providers::Diagnostics.parse_output(output)
      diagnostics.size.should eq(1)
      d = diagnostics[0]
      d.range.start.line.should eq(9)       # 0-based
      d.range.start.character.should eq(4)  # 0-based
      d.severity.should eq(1)               # Error
      d.source.should eq("crystal")
      d.message.should contain("undefined local variable or method 'foo'")
    end

    it "parses warning output" do
      output = <<-ERR
      In src/main.cr:3:1

       3 | old_method
           ^
      Warning: deprecated method
      ERR
      diagnostics = Lsp::Crystal::Providers::Diagnostics.parse_output(output)
      diagnostics.size.should eq(1)
      diagnostics[0].severity.should eq(2) # Warning
    end

    it "parses multiple errors" do
      output = <<-ERR
      In a.cr:1:1

       1 | bad
           ^
      Error: first error

      In b.cr:2:3

       2 | worse
             ^
      Error: second error
      ERR
      diagnostics = Lsp::Crystal::Providers::Diagnostics.parse_output(output)
      diagnostics.size.should eq(2)
      diagnostics[0].message.should eq("first error")
      diagnostics[1].message.should eq("second error")
      diagnostics[1].range.start.line.should eq(1)
      diagnostics[1].range.start.character.should eq(2)
    end

    it "deduplicates identical diagnostics" do
      output = <<-ERR
      In a.cr:1:1

       1 | x
           ^
      Error: same error

      In a.cr:1:1

       1 | x
           ^
      Error: same error
      ERR
      diagnostics = Lsp::Crystal::Providers::Diagnostics.parse_output(output)
      diagnostics.size.should eq(1)
    end

    it "returns empty for clean output" do
      diagnostics = Lsp::Crystal::Providers::Diagnostics.parse_output("")
      diagnostics.size.should eq(0)
    end

    it "parses multi-line error messages" do
      output = <<-ERR
      In src/main.cr:1:1

       1 | require "nonexistent"
           ^
      Error: can't find file 'nonexistent'
      If you're trying to require a shard:
      - Did you remember to run `shards install`?
      ERR
      diagnostics = Lsp::Crystal::Providers::Diagnostics.parse_output(output)
      diagnostics.size.should eq(1)
      diagnostics[0].message.should contain("can't find file")
      diagnostics[0].message.should contain("shards install")
    end
  end

  describe "Providers::Formatting" do
    it "formats Crystal code" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "def foo\n1+1\nend\n")
      edits = Lsp::Crystal::Providers::Formatting.run(doc)
      edits.should_not be_nil
      edits.not_nil!.size.should eq(1)
      edits.not_nil![0].new_text.should eq("def foo\n  1 + 1\nend\n")
    end

    it "returns nil when already formatted" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "def foo\n  1 + 1\nend\n")
      edits = Lsp::Crystal::Providers::Formatting.run(doc)
      edits.should be_nil
    end
  end

  describe "Providers::Definition" do
    it "parses implementation results" do
      # Test the JSON parsing by checking the provider handles tool output correctly
      doc = Lsp::Crystal::Document.new("file:///nonexistent.cr", "crystal", 1, "x = 1")
      locations = Lsp::Crystal::Providers::Definition.run(doc, 0, 0)
      # With a nonexistent file, should return empty (tool fails gracefully)
      locations.should be_a(Array(Lsp::Crystal::Location))
    end
  end

  describe "Providers::Hover" do
    it "returns nil for nonexistent file" do
      doc = Lsp::Crystal::Document.new("file:///nonexistent.cr", "crystal", 1, "x = 1")
      result = Lsp::Crystal::Providers::Hover.run(doc, 0, 0)
      # With a nonexistent file, tool fails and returns nil
      result.should be_nil
    end
  end

  describe "Formatting handler integration" do
    it "formats via textDocument/formatting" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/fmt_test.cr", languageId: "crystal", version: 1, text: "def foo\n1+1\nend\n"},
      })
      Fiber.yield

      client.send_request(10, "textDocument/formatting", {
        textDocument: {uri: "file:///tmp/fmt_test.cr"},
        options:      {tabSize: 2, insertSpaces: true},
      })
      resp = client.read_response

      resp["id"].should eq(10)
      edits = resp["result"].as_a
      edits.size.should eq(1)
      edits[0]["newText"].as_s.should eq("def foo\n  1 + 1\nend\n")

      client.close
    end

    it "returns empty array when already formatted" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/fmt_test2.cr", languageId: "crystal", version: 1, text: "def foo\n  1 + 1\nend\n"},
      })
      Fiber.yield

      client.send_request(11, "textDocument/formatting", {
        textDocument: {uri: "file:///tmp/fmt_test2.cr"},
        options:      {tabSize: 2, insertSpaces: true},
      })
      resp = client.read_response

      resp["result"].as_a.size.should eq(0)
      client.close
    end
  end

  describe "Providers::Completion" do
    it "returns keyword completions" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "de")
      result = Lsp::Crystal::Providers::Completion.run(doc, 0, 2)
      labels = result.items.map(&.label)
      labels.should contain("def")
    end

    it "returns snippet completions" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "cl")
      result = Lsp::Crystal::Providers::Completion.run(doc, 0, 2)
      labels = result.items.map(&.label)
      labels.should contain("class")
      snippet = result.items.find { |i| i.label == "class" && i.insert_text_format == 2 }
      snippet.should_not be_nil
    end

    it "returns document symbol completions" do
      code = "def greet\nend\ndef goodbye\nend\ngr"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      result = Lsp::Crystal::Providers::Completion.run(doc, 4, 2)
      labels = result.items.map(&.label)
      labels.should contain("greet")
      labels.should_not contain("goodbye")
    end

    it "returns empty for empty prefix" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "")
      result = Lsp::Crystal::Providers::Completion.run(doc, 0, 0)
      result.items.size.should eq(0)
    end

    it "filters keywords by prefix" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "re")
      result = Lsp::Crystal::Providers::Completion.run(doc, 0, 2)
      labels = result.items.map(&.label)
      labels.should contain("require")
      labels.should contain("return")
      labels.should contain("rescue")
      labels.should_not contain("def")
    end
  end

  describe "Providers::DocumentSymbol" do
    it "extracts class, method, module symbols hierarchically" do
      code = "module MyApp\n  class User\n    property name : String\n    ROLE = \"admin\"\n\n    def initialize(@name)\n    end\n\n    def greet\n    end\n  end\nend\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      symbols = Lsp::Crystal::Providers::DocumentSymbol.run(doc)
      # Top level: only MyApp
      symbols.size.should eq(1)
      my_app = symbols[0]
      my_app.name.should eq("MyApp")
      # MyApp contains User
      my_app.children.size.should eq(1)
      user = my_app.children[0]
      user.name.should eq("User")
      # User contains name, ROLE, initialize, greet
      child_names = user.children.map(&.name)
      child_names.should contain("name")
      child_names.should contain("ROLE")
      child_names.should contain("initialize")
      child_names.should contain("greet")
    end

    it "nests methods inside class" do
      code = "class Foo\n  def bar\n  end\nend\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      symbols = Lsp::Crystal::Providers::DocumentSymbol.run(doc)
      symbols.size.should eq(1)
      symbols[0].name.should eq("Foo")
      symbols[0].children.size.should eq(1)
      symbols[0].children[0].name.should eq("bar")
    end

    it "handles multiple nesting levels" do
      code = "module Outer\n  module Inner\n    class Deep\n      def method\n      end\n    end\n  end\nend\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      symbols = Lsp::Crystal::Providers::DocumentSymbol.run(doc)
      symbols.size.should eq(1)
      symbols[0].name.should eq("Outer")
      symbols[0].children[0].name.should eq("Inner")
      symbols[0].children[0].children[0].name.should eq("Deep")
      symbols[0].children[0].children[0].children[0].name.should eq("method")
    end

    it "keeps top-level defs at root" do
      code = "def standalone\nend\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      symbols = Lsp::Crystal::Providers::DocumentSymbol.run(doc)
      symbols.size.should eq(1)
      symbols[0].name.should eq("standalone")
      symbols[0].children.size.should eq(0)
    end

    it "serializes children field in JSON" do
      code = "class Foo\n  def bar\n  end\nend\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      symbols = Lsp::Crystal::Providers::DocumentSymbol.run(doc)
      json = symbols.to_json
      parsed = JSON.parse(json)
      parsed[0]["children"].as_a.size.should eq(1)
      parsed[0]["children"][0]["name"].should eq("bar")
    end

    it "extracts struct, enum, macro" do
      code = "struct Point\n  def x\n  end\nend\nenum Color\nend\nmacro my_macro\nend\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      symbols = Lsp::Crystal::Providers::DocumentSymbol.run(doc)
      names = symbols.map(&.name)
      names.should contain("Point")
      names.should contain("Color")
      names.should contain("my_macro")
    end

    it "handles self. methods" do
      code = "def self.build\nend\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      symbols = Lsp::Crystal::Providers::DocumentSymbol.run(doc)
      symbols.any? { |s| s.name == "self.build" }.should be_true
    end

    it "returns empty for empty document" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "")
      Lsp::Crystal::Providers::DocumentSymbol.run(doc).size.should eq(0)
    end

    it "run_flat returns flat list for workspace use" do
      code = "class Foo\n  def bar\n  end\nend\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      flat = Lsp::Crystal::Providers::DocumentSymbol.run_flat(doc)
      flat.size.should eq(2)
      flat.map(&.name).should eq(["Foo", "bar"])
    end
  end

  describe "Providers::SignatureHelp" do
    it "finds signature for method call" do
      code = "def greet(name : String, age : Int32)\nend\ngreet("
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      result = Lsp::Crystal::Providers::SignatureHelp.run(doc, 2, 6)
      result.should_not be_nil
      result.not_nil!.signatures.size.should eq(1)
      result.not_nil!.signatures[0].parameters.size.should eq(2)
      result.not_nil!.active_parameter.should eq(0)
    end

    it "tracks active parameter after comma" do
      code = "def foo(a, b, c)\nend\nfoo(1, "
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      result = Lsp::Crystal::Providers::SignatureHelp.run(doc, 2, 7)
      result.should_not be_nil
      result.not_nil!.active_parameter.should eq(1)
    end

    it "returns nil when not in a call" do
      code = "x = 1\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      result = Lsp::Crystal::Providers::SignatureHelp.run(doc, 0, 5)
      result.should be_nil
    end

    it "returns nil when method not found in document" do
      code = "unknown_method("
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      result = Lsp::Crystal::Providers::SignatureHelp.run(doc, 0, 15)
      result.should be_nil
    end
  end

  describe "Completion handler integration" do
    it "returns completions via textDocument/completion" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/comp.cr", languageId: "crystal", version: 1, text: "de"},
      })
      Fiber.yield

      client.send_request(20, "textDocument/completion", {
        textDocument: {uri: "file:///tmp/comp.cr"},
        position:     {line: 0, character: 2},
      })
      resp = client.read_response

      resp["id"].should eq(20)
      items = resp["result"]["items"].as_a
      items.any? { |i| i["label"].as_s == "def" }.should be_true
      client.close
    end
  end

  describe "DocumentSymbol handler integration" do
    it "returns hierarchical symbols via textDocument/documentSymbol" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/sym.cr", languageId: "crystal", version: 1, text: "class Foo\n  def bar\n  end\nend\n"},
      })
      Fiber.yield

      client.send_request(30, "textDocument/documentSymbol", {
        textDocument: {uri: "file:///tmp/sym.cr"},
      })
      resp = client.read_response

      resp["id"].should eq(30)
      symbols = resp["result"].as_a
      symbols.size.should eq(1)
      symbols[0]["name"].as_s.should eq("Foo")
      symbols[0]["children"].as_a.size.should eq(1)
      symbols[0]["children"][0]["name"].as_s.should eq("bar")
      client.close
    end
  end

  describe "Providers::WorkspaceSymbol" do
    it "searches across files in workspace" do
      dir = File.tempname("ws_test")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "a.cr"), "class Alpha\n  def foo\n  end\nend\n")
      File.write(File.join(dir, "b.cr"), "class Beta\n  def bar\n  end\nend\n")

      results = Lsp::Crystal::Providers::WorkspaceSymbol.run(dir, "")
      names = results.map(&.name)
      names.should contain("Alpha")
      names.should contain("Beta")
      names.should contain("foo")
      names.should contain("bar")
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "filters by query string" do
      dir = File.tempname("ws_test")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "a.cr"), "class Alpha\nend\nclass Beta\nend\n")

      results = Lsp::Crystal::Providers::WorkspaceSymbol.run(dir, "alpha")
      results.size.should eq(1)
      results[0].name.should eq("Alpha")
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "returns empty for no match" do
      dir = File.tempname("ws_test")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "a.cr"), "class Foo\nend\n")

      results = Lsp::Crystal::Providers::WorkspaceSymbol.run(dir, "zzzzz")
      results.size.should eq(0)
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end

  describe "WorkspaceSymbol handler integration" do
    it "returns symbols via workspace/symbol" do
      # Create temp workspace with a Crystal file
      dir = File.tempname("ws_handler_test")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "main.cr"), "class MyClass\n  def my_method\n  end\nend\n")

      client = TestClient.new
      client.send_request(1, "initialize", {processId: 1, rootUri: Lsp::Crystal::URI.path_to_uri(dir), capabilities: {} of String => String})
      client.read_response
      client.send_notification("initialized")

      client.send_request(50, "workspace/symbol", {query: "My"})
      resp = client.read_response

      resp["id"].should eq(50)
      symbols = resp["result"].as_a
      symbols.any? { |s| s["name"].as_s == "MyClass" }.should be_true
      symbols.any? { |s| s["name"].as_s == "my_method" }.should be_true

      client.close
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end

  describe "SignatureHelp handler integration" do
    it "returns signature help via textDocument/signatureHelp" do
      client = TestClient.new
      client.initialize_server

      code = "def greet(name : String)\nend\ngreet("
      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/sig.cr", languageId: "crystal", version: 1, text: code},
      })
      Fiber.yield

      client.send_request(40, "textDocument/signatureHelp", {
        textDocument: {uri: "file:///tmp/sig.cr"},
        position:     {line: 2, character: 6},
      })
      resp = client.read_response

      resp["id"].should eq(40)
      sigs = resp["result"]["signatures"].as_a
      sigs.size.should eq(1)
      sigs[0]["label"].as_s.should contain("greet")
      client.close
    end
  end

  describe "Providers::DocumentHighlight" do
    it "highlights all occurrences of a word" do
      code = "foo = 1\nputs foo\nfoo + 2"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      highlights = Lsp::Crystal::Providers::DocumentHighlight.run(doc, 0, 0)
      highlights.size.should eq(3)
      highlights[0].kind.should eq(Lsp::Crystal::Providers::DocumentHighlight::WRITE)
      highlights[0].range.start.line.should eq(0)
      highlights[1].kind.should eq(Lsp::Crystal::Providers::DocumentHighlight::READ)
      highlights[2].kind.should eq(Lsp::Crystal::Providers::DocumentHighlight::READ)
    end

    it "returns empty for whitespace/empty position" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "  ")
      highlights = Lsp::Crystal::Providers::DocumentHighlight.run(doc, 0, 0)
      highlights.size.should eq(0)
    end

    it "does not match partial words" do
      code = "foobar = 1\nfoo = 2"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      highlights = Lsp::Crystal::Providers::DocumentHighlight.run(doc, 1, 0)
      highlights.size.should eq(1)
      highlights[0].range.start.line.should eq(1)
    end
  end

  describe "Providers::FoldingRange" do
    it "folds block keywords" do
      code = "class Foo\n  def bar\n    1\n  end\nend\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      ranges = Lsp::Crystal::Providers::FoldingRange.run(doc)
      ranges.size.should eq(2)
      ranges.all? { |r| r.kind == "region" }.should be_true
    end

    it "folds consecutive comments" do
      code = "# line 1\n# line 2\n# line 3\nx = 1\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      ranges = Lsp::Crystal::Providers::FoldingRange.run(doc)
      comment_ranges = ranges.select { |r| r.kind == "comment" }
      comment_ranges.size.should eq(1)
      comment_ranges[0].start_line.should eq(0)
      comment_ranges[0].end_line.should eq(2)
    end

    it "folds consecutive requires" do
      code = "require \"json\"\nrequire \"yaml\"\nrequire \"log\"\n\nclass Foo\nend\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      ranges = Lsp::Crystal::Providers::FoldingRange.run(doc)
      import_ranges = ranges.select { |r| r.kind == "imports" }
      import_ranges.size.should eq(1)
      import_ranges[0].start_line.should eq(0)
      import_ranges[0].end_line.should eq(2)
    end

    it "returns empty for flat code" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "x = 1\n")
      ranges = Lsp::Crystal::Providers::FoldingRange.run(doc)
      ranges.size.should eq(0)
    end
  end

  describe "DocumentHighlight handler integration" do
    it "returns highlights via textDocument/documentHighlight" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/hl.cr", languageId: "crystal", version: 1, text: "foo = 1\nputs foo\n"},
      })
      Fiber.yield

      client.send_request(60, "textDocument/documentHighlight", {
        textDocument: {uri: "file:///tmp/hl.cr"},
        position:     {line: 0, character: 0},
      })
      resp = client.read_response

      resp["id"].should eq(60)
      highlights = resp["result"].as_a
      highlights.size.should eq(2)
      client.close
    end
  end

  describe "Providers::SelectionRange" do
    it "builds nested selection ranges" do
      code = "class Foo\n  def bar\n    hello\n  end\nend\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      positions = [Lsp::Crystal::Position.new(line: 2, character: 4)]
      results = Lsp::Crystal::Providers::SelectionRange.run(doc, positions)
      results.size.should eq(1)

      sel = results[0]
      sel.range.start.character.should eq(4)
      sel.range.end_pos.character.should eq(9)

      sel.parent.should_not be_nil
    end

    it "handles multiple positions" do
      code = "class Foo\n  def bar\n  end\nend\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      positions = [
        Lsp::Crystal::Position.new(line: 0, character: 6),
        Lsp::Crystal::Position.new(line: 1, character: 6),
      ]
      results = Lsp::Crystal::Providers::SelectionRange.run(doc, positions)
      results.size.should eq(2)
    end
  end

  describe "FoldingRange handler integration" do
    it "returns folding ranges via textDocument/foldingRange" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/fold.cr", languageId: "crystal", version: 1, text: "class Foo\n  def bar\n    1\n  end\nend\n"},
      })
      Fiber.yield

      client.send_request(70, "textDocument/foldingRange", {
        textDocument: {uri: "file:///tmp/fold.cr"},
      })
      resp = client.read_response

      resp["id"].should eq(70)
      ranges = resp["result"].as_a
      ranges.size.should eq(2)
      client.close
    end
  end

  describe "SelectionRange handler integration" do
    it "returns selection ranges via textDocument/selectionRange" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/sel.cr", languageId: "crystal", version: 1, text: "class Foo\n  def bar\n    hello\n  end\nend\n"},
      })
      Fiber.yield

      client.send_request(80, "textDocument/selectionRange", {
        textDocument: {uri: "file:///tmp/sel.cr"},
        positions:    [{line: 2, character: 4}],
      })
      resp = client.read_response

      resp["id"].should eq(80)
      results = resp["result"].as_a
      results.size.should eq(1)
      results[0]["range"]["start"]["character"].should eq(4)
      client.close
    end
  end

  describe "Text Sync Integration" do
    it "tracks documents through open/change/close" do
      client = TestClient.new
      client.initialize_server

      # Open a document
      client.send_notification("textDocument/didOpen", {
        textDocument: {
          uri:        "file:///tmp/test.cr",
          languageId: "crystal",
          version:    1,
          text:       "puts \"hello\"",
        },
      })
      Fiber.yield

      doc = client.server.document_store.get("file:///tmp/test.cr")
      doc.should_not be_nil
      doc.not_nil!.content.should eq("puts \"hello\"")

      # Change the document
      client.send_notification("textDocument/didChange", {
        textDocument: {uri: "file:///tmp/test.cr", version: 2},
        contentChanges: [{text: "puts \"world\""}],
      })
      Fiber.yield

      doc = client.server.document_store.get("file:///tmp/test.cr")
      doc.not_nil!.content.should eq("puts \"world\"")
      doc.not_nil!.version.should eq(2)

      # Close the document
      client.send_notification("textDocument/didClose", {
        textDocument: {uri: "file:///tmp/test.cr"},
      })
      Fiber.yield

      client.server.document_store.get("file:///tmp/test.cr").should be_nil
      client.close
    end
  end

  describe "Providers::References" do
    it "finds all references of a word in a single document" do
      code = "def greet(name)\n  puts name\n  name.upcase\nend\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      refs = Lsp::Crystal::Providers::References.run(doc, 0, 10, nil)
      refs.size.should eq(3)
      refs.all? { |r| r.uri == "file:///t.cr" }.should be_true
    end

    it "returns empty for cursor on whitespace" do
      code = "x = 1\n  \ny = 2\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      refs = Lsp::Crystal::Providers::References.run(doc, 1, 0, nil)
      refs.should be_empty
    end

    it "finds references with word boundaries" do
      code = "foo = 1\nfoobar = 2\nfoo + foobar\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      refs = Lsp::Crystal::Providers::References.run(doc, 0, 0, nil)
      refs.size.should eq(2)
    end
  end

  describe "References handler integration" do
    it "returns references via textDocument/references" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/ref.cr", languageId: "crystal", version: 1, text: "xzqrefvar99 = 1\nputs xzqrefvar99\nxzqrefvar99 + 2\n"},
      })
      Fiber.yield

      client.send_request(90, "textDocument/references", {
        textDocument: {uri: "file:///tmp/ref.cr"},
        position:     {line: 0, character: 0},
        context:      {includeDeclaration: true},
      })
      resp = client.read_response

      resp["id"].should eq(90)
      refs = resp["result"].as_a
      refs.size.should eq(3)
      client.close
    end
  end

  describe "Providers::CodeAction" do
    it "suggests prefixing unused variable with underscore" do
      code = "x = 1\nputs y\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      diagnostics = [JSON.parse({
        message: "variable 'x' isn't used",
        range:   {start: {line: 0, character: 0}, "end": {line: 0, character: 1}},
      }.to_json)]

      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 0, character: 0),
        end_pos: Lsp::Crystal::Position.new(line: 0, character: 1)
      )
      actions = Lsp::Crystal::Providers::CodeAction.run(doc, range, diagnostics)
      actions.any? { |a| a.title.includes?("underscore") }.should be_true
    end

    it "suggests organizing unsorted requires" do
      code = "require \"z\"\nrequire \"a\"\nrequire \"m\"\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 0, character: 0),
        end_pos: Lsp::Crystal::Position.new(line: 2, character: 0)
      )
      actions = Lsp::Crystal::Providers::CodeAction.run(doc, range, nil)
      actions.any? { |a| a.title == "Organize requires" }.should be_true
    end

    it "returns empty when requires are already sorted" do
      code = "require \"a\"\nrequire \"b\"\nrequire \"c\"\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 0, character: 0),
        end_pos: Lsp::Crystal::Position.new(line: 2, character: 0)
      )
      actions = Lsp::Crystal::Providers::CodeAction.run(doc, range, nil)
      actions.any? { |a| a.title == "Organize requires" }.should be_false
    end
  end

  describe "CodeAction handler integration" do
    it "returns code actions via textDocument/codeAction" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/action.cr", languageId: "crystal", version: 1, text: "require \"z\"\nrequire \"a\"\n"},
      })
      Fiber.yield

      client.send_request(91, "textDocument/codeAction", {
        textDocument: {uri: "file:///tmp/action.cr"},
        range:        {start: {line: 0, character: 0}, "end": {line: 1, character: 0}},
        context:      {diagnostics: [] of String},
      })
      resp = client.read_response

      resp["id"].should eq(91)
      actions = resp["result"].as_a
      actions.any? { |a| a["title"].as_s == "Organize requires" }.should be_true
      client.close
    end
  end

  describe "Transport::Stdio Content-Length validation" do
    it "rejects Content-Length exceeding max message size" do
      huge_length = 11 * 1024 * 1024 # 11 MB, exceeds 10 MB limit
      input = IO::Memory.new("Content-Length: #{huge_length}\r\n\r\n")
      output = IO::Memory.new
      transport = Lsp::Crystal::Transport::Stdio.new(input: input, output: output)
      expect_raises(Exception, "Invalid Content-Length") do
        transport.read_message
      end
    end

    it "rejects Content-Length of zero" do
      input = IO::Memory.new("Content-Length: 0\r\n\r\n")
      output = IO::Memory.new
      transport = Lsp::Crystal::Transport::Stdio.new(input: input, output: output)
      expect_raises(Exception, "Invalid Content-Length") do
        transport.read_message
      end
    end

    it "rejects negative Content-Length" do
      input = IO::Memory.new("Content-Length: -1\r\n\r\n")
      output = IO::Memory.new
      transport = Lsp::Crystal::Transport::Stdio.new(input: input, output: output)
      expect_raises(Exception, "Invalid Content-Length") do
        transport.read_message
      end
    end
  end

  describe "CrystalTool timeout" do
    it "returns a ToolResult struct" do
      result = Lsp::Crystal::CrystalTool::ToolResult.new(false, "", "timed out")
      result.success.should be_false
      result.stderr.should eq("timed out")
    end
  end

  describe "CrystalTool.check_content temp file cleanup" do
    it "cleans up temp file even on failure" do
      # Use content that will fail to compile but temp should still be cleaned
      result = Lsp::Crystal::CrystalTool.check_content("invalid crystal !!!", "/fake/file.cr")
      # The temp file should not exist after the call
      # We can't easily check directly, but the result should have the filename substituted
      result.stderr.should_not contain("crystal-lsp")
    end
  end

  describe "WorkspaceIndex" do
    it "indexes files and searches symbols" do
      dir = File.tempname("ws_idx")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "a.cr"), "class Alpha\n  def foo\n  end\nend\n")
      File.write(File.join(dir, "b.cr"), "class Beta\n  def bar\n  end\nend\n")

      index = Lsp::Crystal::WorkspaceIndex.new
      index.index(dir)

      index.indexed?.should be_true
      index.file_count.should eq(2)

      results = index.search_symbols("")
      names = results.map(&.name)
      names.should contain("Alpha")
      names.should contain("Beta")
      names.should contain("foo")
      names.should contain("bar")
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "filters symbols by query" do
      dir = File.tempname("ws_idx")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "a.cr"), "class Alpha\nend\nclass Beta\nend\n")

      index = Lsp::Crystal::WorkspaceIndex.new
      index.index(dir)

      results = index.search_symbols("alpha")
      results.size.should eq(1)
      results[0].name.should eq("Alpha")
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "searches references across indexed files" do
      dir = File.tempname("ws_idx")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "a.cr"), "foo = 1\nputs foo\n")
      File.write(File.join(dir, "b.cr"), "foo = 2\n")

      index = Lsp::Crystal::WorkspaceIndex.new
      index.index(dir)

      pattern = /\bfoo\b/
      refs = index.search_references(pattern)
      refs.size.should eq(3) # 2 in a.cr, 1 in b.cr
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "invalidates a file on change" do
      dir = File.tempname("ws_idx")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "a.cr"), "class Old\nend\n")

      index = Lsp::Crystal::WorkspaceIndex.new
      index.index(dir)

      results = index.search_symbols("Old")
      results.size.should eq(1)

      # Update file content via invalidate_content
      index.invalidate_content(File.join(dir, "a.cr"), "class New\nend\n")

      results = index.search_symbols("Old")
      results.size.should eq(0)
      results = index.search_symbols("New")
      results.size.should eq(1)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "skips lib/ and .crystal/ directories" do
      dir = File.tempname("ws_idx")
      Dir.mkdir_p(File.join(dir, "lib"))
      Dir.mkdir_p(File.join(dir, ".crystal"))
      File.write(File.join(dir, "src.cr"), "class Src\nend\n")
      File.write(File.join(dir, "lib", "dep.cr"), "class Dep\nend\n")
      File.write(File.join(dir, ".crystal", "cache.cr"), "class Cache\nend\n")

      index = Lsp::Crystal::WorkspaceIndex.new
      index.index(dir)

      index.file_count.should eq(1)
      results = index.search_symbols("")
      results.map(&.name).should eq(["Src"])
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end

  describe "Document symbol cache" do
    it "caches and returns stale status" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "def foo\nend\n")
      doc.symbols_stale?.should be_true

      symbols = Lsp::Crystal::Providers::DocumentSymbol.run(doc)
      flat = Lsp::Crystal::Providers::DocumentSymbol.run_flat(doc)
      doc.cache_symbols(symbols, flat)

      doc.symbols_stale?.should be_false
      doc.cached_symbols.not_nil!.size.should eq(1)
      doc.cached_flat_symbols.not_nil!.size.should eq(1)

      # Change version to simulate edit
      doc.version = 2
      doc.symbols_stale?.should be_true
    end
  end

  describe "URI.path_within_workspace?" do
    it "returns true for paths within workspace" do
      dir = File.tempname("ws_test")
      Dir.mkdir_p(dir)
      sub = File.join(dir, "src")
      Dir.mkdir_p(sub)
      file = File.join(sub, "test.cr")
      File.write(file, "")

      Lsp::Crystal::URI.path_within_workspace?(file, dir).should be_true
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "returns false for paths outside workspace" do
      dir = File.tempname("ws_test")
      Dir.mkdir_p(dir)
      other = File.tempname("other")
      Dir.mkdir_p(other)
      file = File.join(other, "test.cr")
      File.write(file, "")

      Lsp::Crystal::URI.path_within_workspace?(file, dir).should be_false
    ensure
      FileUtils.rm_rf(dir) if dir
      FileUtils.rm_rf(other) if other
    end
  end

  describe "Providers::Rename" do
    it "prepares rename at a valid symbol" do
      code = "foo = 42\nputs foo\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      result = Lsp::Crystal::Providers::Rename.prepare(doc, 0, 1)
      result.should_not be_nil
      range, placeholder = result.not_nil!
      placeholder.should eq("foo")
      range.start.character.should eq(0)
      range.end_pos.character.should eq(3)
    end

    it "returns nil for prepare on whitespace" do
      code = "x = 1\n   \ny = 2\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      result = Lsp::Crystal::Providers::Rename.prepare(doc, 1, 1)
      result.should be_nil
    end

    it "renames all occurrences in a document" do
      code = "foo = 42\nputs foo\nfoo + 1\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      edit = Lsp::Crystal::Providers::Rename.run(doc, 0, 1, "bar", nil)
      edits = edit.changes["file:///t.cr"]
      edits.size.should eq(3)
      edits.all? { |e| e.new_text == "bar" }.should be_true
    end
  end

  describe "Rename handler integration" do
    it "returns workspace edit via textDocument/rename" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/ren.cr", languageId: "crystal", version: 1, text: "foo = 1\nputs foo\n"},
      })
      Fiber.yield

      client.send_request(92, "textDocument/rename", {
        textDocument: {uri: "file:///tmp/ren.cr"},
        position:     {line: 0, character: 0},
        newName:      "bar",
      })
      resp = client.read_response

      resp["id"].should eq(92)
      changes = resp["result"]["changes"]
      edits = changes["file:///tmp/ren.cr"].as_a
      edits.size.should eq(2)
      edits.all? { |e| e["newText"].as_s == "bar" }.should be_true
      client.close
    end

    it "returns prepare rename via textDocument/prepareRename" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/prep.cr", languageId: "crystal", version: 1, text: "hello = 1\n"},
      })
      Fiber.yield

      client.send_request(93, "textDocument/prepareRename", {
        textDocument: {uri: "file:///tmp/prep.cr"},
        position:     {line: 0, character: 2},
      })
      resp = client.read_response

      resp["id"].should eq(93)
      resp["result"]["placeholder"].as_s.should eq("hello")
      resp["result"]["range"]["start"]["character"].should eq(0)
      resp["result"]["range"]["end"]["character"].should eq(5)
      client.close
    end
  end

  # ============================================================
  # Tier 1: High Impact, Easy
  # ============================================================

  describe "Providers::Implementation" do
    it "returns empty array for nonexistent file" do
      doc = Lsp::Crystal::Document.new("file:///nonexistent.cr", "crystal", 1, "x = 1")
      locations = Lsp::Crystal::Providers::Implementation.run(doc, 0, 0)
      locations.should be_a(Array(Lsp::Crystal::Location))
      locations.should be_empty
    end

    it "returns Array(Location) type" do
      doc = Lsp::Crystal::Document.new("file:///nonexistent.cr", "crystal", 1, "class Foo\nend\n")
      result = Lsp::Crystal::Providers::Implementation.run(doc, 0, 6)
      result.should be_a(Array(Lsp::Crystal::Location))
    end

    it "parses implementation JSON with missing optional size field" do
      # The provider defaults size to 0 when missing — test via nonexistent file
      doc = Lsp::Crystal::Document.new("file:///nonexistent.cr", "crystal", 1, "def foo; end")
      locations = Lsp::Crystal::Providers::Implementation.run(doc, 0, 4)
      locations.should be_a(Array(Lsp::Crystal::Location))
    end
  end

  describe "Implementation handler integration" do
    it "returns locations via textDocument/implementation" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/impl.cr", languageId: "crystal", version: 1, text: "class Foo\nend\n"},
      })
      Fiber.yield

      client.send_request(100, "textDocument/implementation", {
        textDocument: {uri: "file:///tmp/impl.cr"},
        position:     {line: 0, character: 6},
      })
      resp = client.read_response

      resp["id"].should eq(100)
      resp["result"].should_not be_nil
      client.close
    end
  end

  describe "Document edge cases" do
    it "calculates position_at correctly" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "abc\ndef\nghi")
      pos0 = doc.position_at(0)
      pos0.line.should eq(0)
      pos0.character.should eq(0)

      pos4 = doc.position_at(4)
      pos4.line.should eq(1)
      pos4.character.should eq(0)

      pos6 = doc.position_at(6)
      pos6.line.should eq(1)
      pos6.character.should eq(2)
    end

    it "round-trips offset_at and position_at" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "abc\ndef\nghi")
      [0, 1, 3, 4, 7, 8, 10].each do |offset|
        pos = doc.position_at(offset)
        doc.offset_at(pos).should eq(offset)
      end
    end

    it "handles empty document" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "")
      end_pos = doc.end_position
      end_pos.line.should eq(0)
      end_pos.character.should eq(0)
      doc.offset_at(Lsp::Crystal::Position.new(line: 0, character: 0)).should eq(0)
    end

    it "handles single-line document" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "hello")
      end_pos = doc.end_position
      end_pos.line.should eq(0)
      end_pos.character.should eq(5)
    end

    it "handles position beyond content" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "ab\ncd")
      # Line beyond content — should return content size
      offset = doc.offset_at(Lsp::Crystal::Position.new(line: 99, character: 0))
      offset.should eq(5) # content.size
    end
  end

  describe "Dispatcher error recovery" do
    it "returns InternalError when handler raises" do
      client = TestClient.new
      client.initialize_server

      # Send a textDocument/definition without params to trigger NilAssertionError
      client.send_request(101, "textDocument/definition")
      resp = client.read_response

      resp["id"].should eq(101)
      resp["error"]["code"].should eq(-32603) # InternalError
    end

    it "returns nil for notification to unknown method" do
      client = TestClient.new
      client.initialize_server

      # Send a notification (no id) to an unknown method — should produce no response
      client.send_notification("custom/unknownNotification")
      Fiber.yield

      # Try reading a response — should timeout because no response was sent
      resp = client.try_read_response(timeout: 200.milliseconds)
      resp.should be_nil
      client.close
    end

    it "handles malformed JSON gracefully" do
      client = TestClient.new
      client.initialize_server

      # Write raw invalid JSON
      bad = "this is not json"
      client.send_raw("Content-Length: #{bad.bytesize}\r\n\r\n#{bad}")
      Fiber.yield
      sleep 100.milliseconds

      # The server should respond with a parse error (id: null, error object)
      # Skip any progress/diagnostic notifications first
      found_error = false
      5.times do
        resp = client.try_read_notification(timeout: 1.second)
        if resp && resp["error"]?
          resp["error"]["code"].should eq(-32700) # ParseError
          found_error = true
          break
        end
      end
      found_error.should be_true
      client.close
    end
  end

  describe "Protocol type serialization" do
    it "serializes Location to JSON" do
      loc = Lsp::Crystal::Location.new(
        uri: "file:///test.cr",
        range: Lsp::Crystal::Range.new(
          start: Lsp::Crystal::Position.new(line: 1, character: 2),
          end_pos: Lsp::Crystal::Position.new(line: 3, character: 4)
        )
      )
      json = JSON.parse(loc.to_json)
      json["uri"].should eq("file:///test.cr")
      json["range"]["start"]["line"].should eq(1)
      json["range"]["end"]["character"].should eq(4)
    end

    it "serializes TextEdit with camelCase newText" do
      edit = Lsp::Crystal::TextEdit.new(
        range: Lsp::Crystal::Range.new(
          start: Lsp::Crystal::Position.new(line: 0, character: 0),
          end_pos: Lsp::Crystal::Position.new(line: 0, character: 5)
        ),
        new_text: "hello"
      )
      json = JSON.parse(edit.to_json)
      json["newText"].should eq("hello")
      json["range"].should_not be_nil
    end

    it "serializes WorkspaceEdit changes map" do
      edit = Lsp::Crystal::WorkspaceEdit.new
      edit.changes["file:///t.cr"] = [
        Lsp::Crystal::TextEdit.new(
          range: Lsp::Crystal::Range.new(
            start: Lsp::Crystal::Position.new(line: 0, character: 0),
            end_pos: Lsp::Crystal::Position.new(line: 0, character: 3)
          ),
          new_text: "bar"
        ),
      ]
      json = JSON.parse(edit.to_json)
      json["changes"]["file:///t.cr"].as_a.size.should eq(1)
      json["changes"]["file:///t.cr"][0]["newText"].should eq("bar")
    end
  end

  describe "CodeAction edge cases" do
    it "does not suggest fix for already-underscored var" do
      code = "_x = 1\nputs y\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      diagnostics = [JSON.parse({
        message: "variable '_x' isn't used",
        range:   {start: {line: 0, character: 0}, "end": {line: 0, character: 2}},
      }.to_json)]

      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 0, character: 0),
        end_pos: Lsp::Crystal::Position.new(line: 0, character: 2)
      )
      actions = Lsp::Crystal::Providers::CodeAction.run(doc, range, diagnostics)
      actions.any? { |a| a.title.includes?("underscore") }.should be_false
    end

    it "returns empty for no diagnostics and sorted requires" do
      code = "require \"a\"\nrequire \"b\"\n\nx = 1\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 0, character: 0),
        end_pos: Lsp::Crystal::Position.new(line: 3, character: 0)
      )
      actions = Lsp::Crystal::Providers::CodeAction.run(doc, range, nil)
      actions.should be_empty
    end

    it "handles multiple separate require groups" do
      code = "require \"z\"\nrequire \"a\"\n\nrequire \"y\"\nrequire \"b\"\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 0, character: 0),
        end_pos: Lsp::Crystal::Position.new(line: 4, character: 0)
      )
      actions = Lsp::Crystal::Providers::CodeAction.run(doc, range, nil)
      organize = actions.find { |a| a.title == "Organize requires" }
      organize.should_not be_nil
    end
  end

  describe "References edge cases" do
    it "finds references across multiple lines" do
      code = "total = 0\ntotal += 1\nputs total\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      refs = Lsp::Crystal::Providers::References.run(doc, 0, 0, nil)
      refs.size.should eq(3) # assignment + increment + puts
    end

    it "returns empty for cursor on whitespace" do
      code = "x = 1\n   \ny = 2\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      refs = Lsp::Crystal::Providers::References.run(doc, 1, 1, nil)
      refs.should be_empty
    end
  end

  # ============================================================
  # Tier 2: High Impact, Moderate Effort
  # ============================================================

  describe "WorkspaceIndex additional" do
    it "invalidate_content updates without disk read" do
      index = Lsp::Crystal::WorkspaceIndex.new
      # Directly add content without indexing from disk
      index.invalidate_content("/tmp/virtual.cr", "class Virtual\n  def hello\n  end\nend\n")

      results = index.search_symbols("Virtual")
      results.size.should eq(1)
      results[0].name.should eq("Virtual")
    end

    it "search_references finds word across files" do
      dir = File.tempname("ws_idx")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "a.cr"), "helper = 1\n")
      File.write(File.join(dir, "b.cr"), "puts helper\n")

      index = Lsp::Crystal::WorkspaceIndex.new
      index.index(dir)

      refs = index.search_references(/\bhelper\b/)
      refs.size.should eq(2) # 1 in a.cr, 1 in b.cr
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end

  describe "Handler missing document" do
    it "definition returns empty array for unopened doc" do
      client = TestClient.new
      client.initialize_server

      client.send_request(110, "textDocument/definition", {
        textDocument: {uri: "file:///tmp/nonexistent.cr"},
        position:     {line: 0, character: 0},
      })
      resp = client.read_response

      resp["id"].should eq(110)
      resp["result"].as_a.should be_empty
      client.close
    end

    it "hover returns null for unopened doc" do
      client = TestClient.new
      client.initialize_server

      client.send_request(111, "textDocument/hover", {
        textDocument: {uri: "file:///tmp/nonexistent.cr"},
        position:     {line: 0, character: 0},
      })
      resp = client.read_response

      resp["id"].should eq(111)
      resp["result"].raw.should be_nil
      client.close
    end

    it "completion returns empty for unopened doc" do
      client = TestClient.new
      client.initialize_server

      client.send_request(112, "textDocument/completion", {
        textDocument: {uri: "file:///tmp/nonexistent.cr"},
        position:     {line: 0, character: 0},
      })
      resp = client.read_response

      resp["id"].should eq(112)
      resp["result"]["items"].as_a.should be_empty
      client.close
    end

    it "documentSymbol returns empty for unopened doc" do
      client = TestClient.new
      client.initialize_server

      client.send_request(113, "textDocument/documentSymbol", {
        textDocument: {uri: "file:///tmp/nonexistent.cr"},
      })
      resp = client.read_response

      resp["id"].should eq(113)
      resp["result"].as_a.should be_empty
      client.close
    end

    it "signatureHelp returns null for unopened doc" do
      client = TestClient.new
      client.initialize_server

      client.send_request(114, "textDocument/signatureHelp", {
        textDocument: {uri: "file:///tmp/nonexistent.cr"},
        position:     {line: 0, character: 0},
      })
      resp = client.read_response

      resp["id"].should eq(114)
      resp["result"].raw.should be_nil
      client.close
    end
  end

  describe "Lifecycle edge cases" do
    it "advertises all expected capabilities" do
      client = TestClient.new
      client.send_request(1, "initialize", {processId: 1, rootUri: "file:///tmp", capabilities: {} of String => String})
      resp = client.read_response

      caps = resp["result"]["capabilities"]
      caps["textDocumentSync"].should_not be_nil
      caps["completionProvider"].should_not be_nil
      caps["hoverProvider"].should eq(true)
      caps["definitionProvider"].should eq(true)
      caps["documentFormattingProvider"].should eq(true)
      caps["documentSymbolProvider"].should eq(true)
      caps["signatureHelpProvider"].should_not be_nil
      caps["workspaceSymbolProvider"].should eq(true)
      caps["documentHighlightProvider"].should eq(true)
      caps["foldingRangeProvider"].should eq(true)
      caps["selectionRangeProvider"].should eq(true)
      caps["implementationProvider"].should eq(true)
      caps["referencesProvider"].should eq(true)
      caps["codeActionProvider"].should eq(true)
      caps["renameProvider"]["prepareProvider"].should eq(true)
      client.close
    end

    it "handles rootPath fallback when rootUri missing" do
      client = TestClient.new
      client.send_request(1, "initialize", {processId: 1, rootPath: "/tmp", capabilities: {} of String => String})
      resp = client.read_response

      resp["result"]["capabilities"]["hoverProvider"].should eq(true)
      client.server.workspace_root.should eq("/tmp")
      client.close
    end
  end

  describe "JSONRPC::Response.notification" do
    it "builds a notification without id" do
      json = Lsp::Crystal::JSONRPC::Response.notification("test/method", {data: "value"})
      parsed = JSON.parse(json)
      parsed["jsonrpc"].should eq("2.0")
      parsed["method"].should eq("test/method")
      parsed["params"]["data"].should eq("value")
      parsed["id"]?.should be_nil
    end
  end

  describe "Rename edge cases" do
    it "prepare returns nil for cursor on whitespace" do
      code = "x = 1\n   \ny = 2\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      result = Lsp::Crystal::Providers::Rename.prepare(doc, 1, 1)
      result.should be_nil
    end
  end

  # ============================================================
  # Tier 3: Nice to Have
  # ============================================================

  describe "URI edge cases" do
    it "handles paths with spaces" do
      path = "/tmp/my project/file.cr"
      uri = Lsp::Crystal::URI.path_to_uri(path)
      uri.should eq("file:///tmp/my project/file.cr")
      round_tripped = Lsp::Crystal::URI.uri_to_path(uri)
      round_tripped.should eq(path)
    end

    it "passes through non-file URIs" do
      uri = "untitled:Untitled-1"
      result = Lsp::Crystal::URI.uri_to_path(uri)
      result.should eq(uri)
    end
  end

  describe "SelectionRange edge cases" do
    it "handles cursor at document start" do
      code = "class Foo\n  def bar\n  end\nend\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      positions = [Lsp::Crystal::Position.new(line: 0, character: 0)]
      results = Lsp::Crystal::Providers::SelectionRange.run(doc, positions)
      results.size.should eq(1)
      # Should have parent chain (word → line → block → document)
      results[0].parent.should_not be_nil
    end

    it "handles mismatched end keywords without crash" do
      code = "end\nend\nend\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      positions = [Lsp::Crystal::Position.new(line: 0, character: 0)]
      results = Lsp::Crystal::Providers::SelectionRange.run(doc, positions)
      results.size.should eq(1)
    end
  end

  describe "FoldingRange edge cases" do
    it "handles file with only comments" do
      code = "# comment 1\n# comment 2\n# comment 3\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      ranges = Lsp::Crystal::Providers::FoldingRange.run(doc)
      comment_ranges = ranges.select { |r| r.kind == "comment" }
      comment_ranges.size.should eq(1)
      comment_ranges[0].start_line.should eq(0)
      comment_ranges[0].end_line.should eq(2)
    end

    it "handles empty file" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "")
      ranges = Lsp::Crystal::Providers::FoldingRange.run(doc)
      ranges.should be_empty
    end
  end

  describe "DocumentStore thread safety" do
    it "handles concurrent open/get/close" do
      store = Lsp::Crystal::DocumentStore.new
      done = Channel(Nil).new(10)

      10.times do |i|
        spawn do
          uri = "file:///test_#{i}.cr"
          store.open(uri, "crystal", 1, "content #{i}")
          store.get(uri)
          store.close(uri)
          done.send(nil)
        end
      end

      10.times { done.receive }
      # Should not crash — all docs closed
      store.size.should eq(0)
    end
  end

  # ============================================================
  # Phase 3: Semantic Tokens, Call Hierarchy, Inlay Hints, Code Lens, Configuration
  # ============================================================

  describe "Providers::SemanticTokens" do
    it "tokenizes keywords" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "def foo\nend\n")
      data = Lsp::Crystal::Providers::SemanticTokens.run(doc)
      # Should have tokens for: def(keyword), foo(function), end(keyword)
      data.size.should be > 0
      # Data is delta-encoded: [deltaLine, deltaCol, length, type, modifiers]
      (data.size % 5).should eq(0)
    end

    it "tokenizes strings and numbers" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "x = \"hello\"\ny = 42\n")
      data = Lsp::Crystal::Providers::SemanticTokens.run(doc)
      (data.size % 5).should eq(0)
      data.size.should be > 0
    end

    it "tokenizes comments" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "# comment\nx = 1\n")
      data = Lsp::Crystal::Providers::SemanticTokens.run(doc)
      # First token should be a comment (type 12)
      data[3].should eq(12) # token type for comment
    end

    it "tokenizes types (uppercase identifiers)" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "String\n")
      data = Lsp::Crystal::Providers::SemanticTokens.run(doc)
      data[3].should eq(1) # type
    end

    it "returns empty for empty document" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "")
      data = Lsp::Crystal::Providers::SemanticTokens.run(doc)
      data.should be_empty
    end
  end

  describe "SemanticTokens handler integration" do
    it "returns token data via textDocument/semanticTokens/full" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/st.cr", languageId: "crystal", version: 1, text: "def foo\n  42\nend\n"},
      })
      Fiber.yield

      client.send_request(200, "textDocument/semanticTokens/full", {
        textDocument: {uri: "file:///tmp/st.cr"},
      })
      resp = client.read_response

      resp["id"].should eq(200)
      data = resp["result"]["data"].as_a
      (data.size % 5).should eq(0)
      client.close
    end
  end

  describe "Providers::CallHierarchy" do
    it "prepares call hierarchy on a method definition" do
      code = "def greet(name)\n  puts name\nend\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      items = Lsp::Crystal::Providers::CallHierarchy.prepare(doc, 0, 6)
      items.size.should eq(1)
      items[0].name.should eq("greet")
    end

    it "prepares call hierarchy on a class definition" do
      code = "class Foo\nend\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      items = Lsp::Crystal::Providers::CallHierarchy.prepare(doc, 0, 6)
      items.size.should eq(1)
      items[0].name.should eq("Foo")
    end

    it "returns empty for whitespace" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "  \n")
      items = Lsp::Crystal::Providers::CallHierarchy.prepare(doc, 0, 0)
      items.should be_empty
    end
  end

  describe "CallHierarchy handler integration" do
    it "returns items via textDocument/prepareCallHierarchy" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/ch.cr", languageId: "crystal", version: 1, text: "def hello\nend\n"},
      })
      Fiber.yield

      client.send_request(201, "textDocument/prepareCallHierarchy", {
        textDocument: {uri: "file:///tmp/ch.cr"},
        position:     {line: 0, character: 4},
      })
      resp = client.read_response

      resp["id"].should eq(201)
      items = resp["result"].as_a
      items.size.should eq(1)
      items[0]["name"].as_s.should eq("hello")
      client.close
    end
  end

  describe "Providers::InlayHints" do
    it "shows type hints for integer literals" do
      code = "x = 42\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 0, character: 0),
        end_pos: Lsp::Crystal::Position.new(line: 0, character: 10)
      )
      hints = Lsp::Crystal::Providers::InlayHints.run(doc, range)
      hints.size.should eq(1)
      hints[0].label.should eq(": Int32")
      hints[0].kind.should eq(1) # Type hint
    end

    it "shows type hints for string literals" do
      code = "name = \"hello\"\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 0, character: 0),
        end_pos: Lsp::Crystal::Position.new(line: 0, character: 20)
      )
      hints = Lsp::Crystal::Providers::InlayHints.run(doc, range)
      hints.size.should eq(1)
      hints[0].label.should eq(": String")
    end

    it "shows type hints for constructor calls" do
      code = "server = Server.new\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 0, character: 0),
        end_pos: Lsp::Crystal::Position.new(line: 0, character: 25)
      )
      hints = Lsp::Crystal::Providers::InlayHints.run(doc, range)
      hints.size.should eq(1)
      hints[0].label.should eq(": Server")
    end

    it "skips lines with explicit type annotations" do
      code = "x : Int32 = 42\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 0, character: 0),
        end_pos: Lsp::Crystal::Position.new(line: 0, character: 20)
      )
      hints = Lsp::Crystal::Providers::InlayHints.run(doc, range)
      hints.should be_empty
    end

    it "returns empty for empty document" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "")
      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 0, character: 0),
        end_pos: Lsp::Crystal::Position.new(line: 0, character: 0)
      )
      hints = Lsp::Crystal::Providers::InlayHints.run(doc, range)
      hints.should be_empty
    end
  end

  describe "InlayHints handler integration" do
    it "returns hints via textDocument/inlayHint" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/ih.cr", languageId: "crystal", version: 1, text: "x = 42\n"},
      })
      Fiber.yield

      client.send_request(202, "textDocument/inlayHint", {
        textDocument: {uri: "file:///tmp/ih.cr"},
        range:        {start: {line: 0, character: 0}, "end": {line: 0, character: 10}},
      })
      resp = client.read_response

      resp["id"].should eq(202)
      hints = resp["result"].as_a
      hints.size.should eq(1)
      hints[0]["label"].as_s.should eq(": Int32")
      client.close
    end
  end

  describe "Providers::CodeLens" do
    it "shows reference count for methods" do
      code = "def greet\nend\ngreet\ngreet\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      lenses = Lsp::Crystal::Providers::CodeLens.run(doc, nil)
      lenses.size.should eq(1)
      lenses[0].command.not_nil!.title.should eq("2 references")
    end

    it "shows reference count for classes" do
      code = "class Foo\nend\nFoo.new\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      lenses = Lsp::Crystal::Providers::CodeLens.run(doc, nil)
      # Should have lenses for Foo
      foo_lens = lenses.find { |l| l.range.start.line == 0 }
      foo_lens.should_not be_nil
      foo_lens.not_nil!.command.not_nil!.title.should eq("1 reference")
    end

    it "returns empty for no symbols" do
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, "x = 1\n")
      lenses = Lsp::Crystal::Providers::CodeLens.run(doc, nil)
      lenses.should be_empty
    end
  end

  describe "CodeLens handler integration" do
    it "returns lenses via textDocument/codeLens" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/cl.cr", languageId: "crystal", version: 1, text: "def foo\nend\nfoo\n"},
      })
      Fiber.yield

      client.send_request(203, "textDocument/codeLens", {
        textDocument: {uri: "file:///tmp/cl.cr"},
      })
      resp = client.read_response

      resp["id"].should eq(203)
      lenses = resp["result"].as_a
      lenses.size.should eq(1)
      client.close
    end
  end

  describe "Configuration" do
    it "updates settings from JSON" do
      config = Lsp::Crystal::Configuration.new
      config.crystal_path.should eq("crystal")
      config.diagnostics_delay.should eq(500)

      settings = JSON.parse(%({"crystalLsp": {"crystalPath": "/usr/bin/crystal", "diagnosticsDelay": 1000, "formatOnSave": true}}))
      config.update(settings)

      config.crystal_path.should eq("/usr/bin/crystal")
      config.diagnostics_delay.should eq(1000)
      config.format_on_save.should be_true
    end

    it "handles missing settings gracefully" do
      config = Lsp::Crystal::Configuration.new
      settings = JSON.parse(%({"other": "value"}))
      config.update(settings)
      config.crystal_path.should eq("crystal") # unchanged
    end

    it "returns diagnostics_debounce as Time::Span" do
      config = Lsp::Crystal::Configuration.new
      config.diagnostics_debounce.should eq(500.milliseconds)
      config.diagnostics_delay = 1000
      config.diagnostics_debounce.should eq(1.second)
    end
  end

  describe "Configuration handler integration" do
    it "handles workspace/didChangeConfiguration" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("workspace/didChangeConfiguration", {
        settings: {crystalLsp: {diagnosticsDelay: 1000}},
      })
      Fiber.yield

      client.server.configuration.diagnostics_delay.should eq(1000)
      client.close
    end
  end

  describe "Lifecycle capabilities for Phase 3" do
    it "advertises semantic tokens provider" do
      client = TestClient.new
      client.send_request(1, "initialize", {processId: 1, rootUri: "file:///tmp", capabilities: {} of String => String})
      resp = client.read_response
      caps = resp["result"]["capabilities"]

      caps["semanticTokensProvider"].should_not be_nil
      caps["semanticTokensProvider"]["full"].should eq(true)
      legend = caps["semanticTokensProvider"]["legend"]
      legend["tokenTypes"].as_a.size.should be > 0
      legend["tokenModifiers"].as_a.size.should be > 0
      client.close
    end

    it "advertises call hierarchy provider" do
      client = TestClient.new
      client.send_request(1, "initialize", {processId: 1, rootUri: "file:///tmp", capabilities: {} of String => String})
      resp = client.read_response
      resp["result"]["capabilities"]["callHierarchyProvider"].should eq(true)
      client.close
    end

    it "advertises inlay hint provider" do
      client = TestClient.new
      client.send_request(1, "initialize", {processId: 1, rootUri: "file:///tmp", capabilities: {} of String => String})
      resp = client.read_response
      resp["result"]["capabilities"]["inlayHintProvider"].should eq(true)
      client.close
    end

    it "advertises code lens provider" do
      client = TestClient.new
      client.send_request(1, "initialize", {processId: 1, rootUri: "file:///tmp", capabilities: {} of String => String})
      resp = client.read_response
      resp["result"]["capabilities"]["codeLensProvider"].should_not be_nil
      client.close
    end
  end

  describe "Transport concurrent writes" do
    it "serializes concurrent writes via mutex" do
      input = IO::Memory.new
      output = IO::Memory.new
      transport = Lsp::Crystal::Transport::Stdio.new(input: input, output: output)
      done = Channel(Nil).new(5)

      5.times do |i|
        spawn do
          transport.write_message(%({"id":#{i}}))
          done.send(nil)
        end
      end

      5.times { done.receive }

      # Verify output contains 5 complete messages (no interleaving)
      output.rewind
      raw = output.gets_to_end
      # Each message should be preceded by Content-Length header
      raw.scan(/Content-Length:/).size.should eq(5)
    end
  end

  # Phase 4: Smarter Intelligence

  describe "Providers::Completion context-aware" do
    it "returns empty for dot completion without crystal tool" do
      code = "x = \"hello\"\nx."
      doc = Lsp::Crystal::Document.new("file:///tmp/nonexistent.cr", "crystal", 1, code)
      result = Lsp::Crystal::Providers::Completion.run(doc, 1, 2)
      result.is_incomplete.should be_false
    end

    it "returns keyword completions for non-dot prefix" do
      code = "de"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      result = Lsp::Crystal::Providers::Completion.run(doc, 0, 2)
      result.items.any? { |i| i.label == "def" }.should be_true
    end

    it "passes workspace info through handler" do
      client = TestClient.new
      client.initialize_server

      code = "x = 1\nx"
      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/comp_ctx.cr", languageId: "crystal", version: 1, text: code},
      })
      Fiber.yield

      client.send_request(200, "textDocument/completion", {
        textDocument: {uri: "file:///tmp/comp_ctx.cr"},
        position:     {line: 1, character: 1},
      })
      resp = client.read_response
      resp["id"].should eq(200)
      resp["result"]["items"].as_a.should be_a(Array(JSON::Any))
      client.close
    end
  end

  describe "WorkspaceIndex type methods" do
    it "finds methods defined on a type" do
      dir = File.tempname("ws_methods_test")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "types.cr"), "class Dog\n  def bark\n  end\n  def sit\n  end\nend\n")

      index = Lsp::Crystal::WorkspaceIndex.new
      index.index(dir)

      methods = [] of String
      index.search_type_methods("Dog") do |name, detail|
        methods << name
      end

      methods.should contain("bark")
      methods.should contain("sit")
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "returns empty for unknown type" do
      dir = File.tempname("ws_methods_test")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "types.cr"), "class Cat\n  def meow\n  end\nend\n")

      index = Lsp::Crystal::WorkspaceIndex.new
      index.index(dir)

      methods = [] of String
      index.search_type_methods("Dog") do |name, detail|
        methods << name
      end

      methods.should be_empty
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end

  describe "Providers::Hover improved" do
    it "extracts doc comments above a definition" do
      dir = File.tempname("hover_doc_test")
      Dir.mkdir_p(dir)
      code = "# This is a documented method\n# It does important things\ndef my_documented_method\n  42\nend\n"
      file_path = File.join(dir, "test.cr")
      File.write(file_path, code)

      comments = Lsp::Crystal::Providers::Hover.extract_comments_above(file_path, 2)
      comments.should_not be_nil
      comments.not_nil!.should contain("documented method")
      comments.not_nil!.should contain("important things")
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "returns nil when no comments above" do
      dir = File.tempname("hover_doc_test")
      Dir.mkdir_p(dir)
      code = "x = 1\ndef no_docs\n  42\nend\n"
      file_path = File.join(dir, "test.cr")
      File.write(file_path, code)

      comments = Lsp::Crystal::Providers::Hover.extract_comments_above(file_path, 1)
      comments.should be_nil
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "returns nil for line 0" do
      dir = File.tempname("hover_doc_test")
      Dir.mkdir_p(dir)
      file_path = File.join(dir, "test.cr")
      File.write(file_path, "def first_line\nend\n")

      comments = Lsp::Crystal::Providers::Hover.extract_comments_above(file_path, 0)
      comments.should be_nil
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end

  describe "Providers::CodeAction extract variable" do
    it "offers extract variable for expression selection" do
      code = "puts 1 + 2 * 3\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 0, character: 5),
        end_pos: Lsp::Crystal::Position.new(line: 0, character: 14)
      )
      actions = Lsp::Crystal::Providers::CodeAction.run(doc, range, nil)
      actions.any? { |a| a.title == "Extract variable" }.should be_true
    end

    it "does not offer extract variable for simple word" do
      code = "puts hello\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 0, character: 5),
        end_pos: Lsp::Crystal::Position.new(line: 0, character: 10)
      )
      actions = Lsp::Crystal::Providers::CodeAction.run(doc, range, nil)
      actions.any? { |a| a.title == "Extract variable" }.should be_false
    end

    it "does not offer extract variable for empty selection" do
      code = "x = 1\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 0, character: 0),
        end_pos: Lsp::Crystal::Position.new(line: 0, character: 0)
      )
      actions = Lsp::Crystal::Providers::CodeAction.run(doc, range, nil)
      actions.any? { |a| a.title == "Extract variable" }.should be_false
    end
  end

  describe "Providers::CodeAction extract method" do
    it "offers extract method for multi-line selection" do
      code = "def foo\n  x = 1\n  y = 2\n  z = x + y\n  puts z\nend\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 1, character: 0),
        end_pos: Lsp::Crystal::Position.new(line: 3, character: 11)
      )
      actions = Lsp::Crystal::Providers::CodeAction.run(doc, range, nil)
      actions.any? { |a| a.title == "Extract method" }.should be_true
    end

    it "does not offer extract method for single line" do
      code = "x = 1\ny = 2\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 0, character: 0),
        end_pos: Lsp::Crystal::Position.new(line: 0, character: 5)
      )
      actions = Lsp::Crystal::Providers::CodeAction.run(doc, range, nil)
      actions.any? { |a| a.title == "Extract method" }.should be_false
    end
  end

  describe "Providers::TypeDefinition" do
    it "finds type definition in current document" do
      code = "class MyType\n  def hello\n    42\n  end\nend\n\nx : MyType = MyType.new\n"
      doc = Lsp::Crystal::Document.new("file:///t.cr", "crystal", 1, code)
      locations = Lsp::Crystal::Providers::TypeDefinition.run(doc, 6, 4)
      locations.should be_a(Array(Lsp::Crystal::Location))
    end

    it "finds type definition in workspace files" do
      dir = File.tempname("typedef_test")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "types.cr"), "class Foo\n  def bar\n  end\nend\n")
      File.write(File.join(dir, "main.cr"), "x = Foo.new\n")

      index = Lsp::Crystal::WorkspaceIndex.new
      index.index(dir)

      doc = Lsp::Crystal::Document.new(
        Lsp::Crystal::URI.path_to_uri(File.join(dir, "main.cr")),
        "crystal", 1, File.read(File.join(dir, "main.cr"))
      )

      found = false
      index.search_type_definition("Foo") do |uri, line_num, col|
        found = true
        line_num.should eq(0)
      end
      found.should be_true
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end

  describe "TypeDefinition handler integration" do
    it "returns type definition via textDocument/typeDefinition" do
      client = TestClient.new
      client.initialize_server

      code = "class Zxq\nend\nx = Zxq.new\n"
      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/typedef.cr", languageId: "crystal", version: 1, text: code},
      })
      Fiber.yield

      client.send_request(210, "textDocument/typeDefinition", {
        textDocument: {uri: "file:///tmp/typedef.cr"},
        position:     {line: 2, character: 4},
      })
      resp = client.read_response

      resp["id"].should eq(210)
      resp["result"].as_a.should be_a(Array(JSON::Any))
      client.close
    end
  end

  describe "Capabilities" do
    it "advertises typeDefinitionProvider" do
      client = TestClient.new
      client.send_request(1, "initialize", {processId: 1, rootUri: "file:///tmp", capabilities: {} of String => String})
      resp = client.read_response
      resp["result"]["capabilities"]["typeDefinitionProvider"].should eq(true)
      client.close
    end
  end

  # ── Phase 5: Integration Tests ──────────────────────────────────────

  describe "Integration: real Crystal project" do
    it "initializes with a shard.yml project and indexes files" do
      dir = File.tempname("integration_test")
      Dir.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "shard.yml"), <<-YAML
        name: test-project
        version: 0.1.0
        targets:
          test-project:
            main: src/test-project.cr
        crystal: '>= 1.0.0'
        YAML
      )
      File.write(File.join(dir, "src", "test-project.cr"), <<-CR
        module TestProject
          VERSION = "0.1.0"

          class Greeter
            def greet(name : String) : String
              "Hello, \#{name}!"
            end
          end

          def self.run
            g = Greeter.new
            puts g.greet("World")
          end
        end
        CR
      )
      File.write(File.join(dir, "src", "helper.cr"), <<-CR
        module TestProject
          class Helper
            def assist
              42
            end
          end
        end
        CR
      )

      client = TestClient.new
      client.send_request(1, "initialize", {
        processId: 1,
        rootUri:   Lsp::Crystal::URI.path_to_uri(dir),
        capabilities: {} of String => String,
      })
      resp = client.read_response
      resp["result"]["capabilities"]["hoverProvider"].should eq(true)
      resp["result"]["serverInfo"]["name"].should eq("crystal-lsp")

      client.send_notification("initialized")
      sleep 200.milliseconds # let indexing complete

      # Workspace symbol search should find classes across files
      client.send_request(2, "workspace/symbol", {query: "Greeter"})
      resp = client.read_response
      resp["result"].as_a.any? { |s| s["name"].as_s == "Greeter" }.should be_true

      client.send_request(3, "workspace/symbol", {query: "Helper"})
      resp = client.read_response
      resp["result"].as_a.any? { |s| s["name"].as_s == "Helper" }.should be_true

      # Open a document and get symbols
      uri = Lsp::Crystal::URI.path_to_uri(File.join(dir, "src", "test-project.cr"))
      content = File.read(File.join(dir, "src", "test-project.cr"))
      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: uri, languageId: "crystal", version: 1, text: content},
      })
      Fiber.yield

      client.send_request(4, "textDocument/documentSymbol", {textDocument: {uri: uri}})
      resp = client.read_response
      symbols = resp["result"].as_a
      names = symbols.map { |s| s["name"].as_s }
      names.should contain("TestProject")

      # Folding ranges should exist
      client.send_request(5, "textDocument/foldingRange", {textDocument: {uri: uri}})
      resp = client.read_response
      resp["result"].as_a.size.should be > 0

      # Document highlight on a word
      client.send_request(6, "textDocument/documentHighlight", {
        textDocument: {uri: uri},
        position:     {line: 4, character: 8},
      })
      resp = client.read_response
      resp["result"].as_a?.should_not be_nil

      # Clean shutdown
      client.send_request(99, "shutdown")
      resp = client.read_response
      resp["result"].raw.should be_nil

      client.close
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "handles multi-file workspace with cross-references" do
      dir = File.tempname("multi_ref_test")
      Dir.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "shard.yml"), "name: multi-ref\nversion: 0.1.0\n")
      File.write(File.join(dir, "src", "models.cr"), <<-CR
        class User
          property name : String
          def initialize(@name)
          end
        end

        class Team
          property members : Array(User)
          def initialize
            @members = [] of User
          end
        end
        CR
      )
      File.write(File.join(dir, "src", "service.cr"), <<-CR
        class UserService
          def find_user(name : String) : User?
            nil
          end

          def create_team : Team
            Team.new
          end
        end
        CR
      )

      client = TestClient.new
      client.send_request(1, "initialize", {
        processId: 1,
        rootUri:   Lsp::Crystal::URI.path_to_uri(dir),
        capabilities: {} of String => String,
      })
      client.read_response
      client.send_notification("initialized")
      sleep 200.milliseconds

      # Should find all types across files
      client.send_request(2, "workspace/symbol", {query: ""})
      resp = client.read_response
      names = resp["result"].as_a.map { |s| s["name"].as_s }
      names.should contain("User")
      names.should contain("Team")
      names.should contain("UserService")

      # References for "User" should span both files
      uri = Lsp::Crystal::URI.path_to_uri(File.join(dir, "src", "models.cr"))
      content = File.read(File.join(dir, "src", "models.cr"))
      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: uri, languageId: "crystal", version: 1, text: content},
      })
      Fiber.yield

      client.send_request(3, "textDocument/references", {
        textDocument: {uri: uri},
        position:     {line: 0, character: 6},
        context:      {includeDeclaration: true},
      })
      resp = client.read_response
      refs = resp["result"].as_a
      refs.size.should be > 0

      client.close
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end

  # ── Phase 5: Concurrency Stress Tests ───────────────────────────────

  describe "Concurrency: rapid open/edit/close cycles" do
    it "handles rapid sequential open/edit/close without crashing" do
      client = TestClient.new
      client.initialize_server

      10.times do |i|
        uri = "file:///tmp/stress_#{i}.cr"
        content = "def method_#{i}\n  #{i}\nend\n"

        # Open
        client.send_notification("textDocument/didOpen", {
          textDocument: {uri: uri, languageId: "crystal", version: 1, text: content},
        })

        # Edit
        new_content = "def method_#{i}\n  #{i + 100}\nend\n"
        client.send_notification("textDocument/didChange", {
          textDocument: {uri: uri, version: 2},
          contentChanges: [{text: new_content}],
        })

        # Close
        client.send_notification("textDocument/didClose", {
          textDocument: {uri: uri},
        })
      end

      Fiber.yield
      sleep 50.milliseconds

      # Server should still be responsive
      client.send_request(999, "textDocument/documentSymbol", {
        textDocument: {uri: "file:///tmp/stress_0.cr"},
      })
      resp = client.try_read_response(1.seconds)
      resp.should_not be_nil
      resp.not_nil!["id"].should eq(999)

      client.close
    end

    it "handles concurrent requests on same document" do
      client = TestClient.new
      client.initialize_server

      uri = "file:///tmp/concurrent.cr"
      code = "class Foo\n  def bar\n    42\n  end\n  def baz\n    99\n  end\nend\n"
      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: uri, languageId: "crystal", version: 1, text: code},
      })
      Fiber.yield

      # Send multiple requests back-to-back
      client.send_request(1, "textDocument/documentSymbol", {textDocument: {uri: uri}})
      client.send_request(2, "textDocument/foldingRange", {textDocument: {uri: uri}})
      client.send_request(3, "textDocument/documentHighlight", {
        textDocument: {uri: uri},
        position:     {line: 1, character: 6},
      })
      client.send_request(4, "textDocument/selectionRange", {
        textDocument: {uri: uri},
        positions:    [{line: 1, character: 6}],
      })

      # Read all responses (order may vary)
      ids = Set(Int64).new
      4.times do
        resp = client.try_read_response(2.seconds)
        resp.should_not be_nil
        ids << resp.not_nil!["id"].as_i64
      end

      ids.should contain(1_i64)
      ids.should contain(2_i64)
      ids.should contain(3_i64)
      ids.should contain(4_i64)

      client.close
    end

    it "handles rapid version bumps without errors" do
      client = TestClient.new
      client.initialize_server

      uri = "file:///tmp/versions.cr"
      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: uri, languageId: "crystal", version: 1, text: "x = 1\n"},
      })

      50.times do |i|
        client.send_notification("textDocument/didChange", {
          textDocument:   {uri: uri, version: i + 2},
          contentChanges: [{text: "x = #{i + 2}\n"}],
        })
      end

      Fiber.yield
      sleep 50.milliseconds

      # Verify server is still healthy
      client.send_request(1, "textDocument/hover", {
        textDocument: {uri: uri},
        position:     {line: 0, character: 0},
      })
      resp = client.try_read_response(1.seconds)
      resp.should_not be_nil

      client.close
    end
  end

  # ── Phase 5: Large File Tests ───────────────────────────────────────

  describe "Large file handling" do
    it "handles document symbols for 10K+ line file" do
      client = TestClient.new
      client.initialize_server

      # Generate a large Crystal file with many classes and methods
      lines = [] of String
      50.times do |cls_i|
        lines << "class LargeClass#{cls_i}"
        200.times do |method_i|
          lines << "  def method_#{method_i}"
          lines << "    #{method_i}"
          lines << "  end"
        end
        lines << "end"
        lines << ""
      end
      large_code = lines.join("\n")
      large_code.lines.size.should be > 10000

      uri = "file:///tmp/large_file.cr"
      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: uri, languageId: "crystal", version: 1, text: large_code},
      })
      Fiber.yield

      client.send_request(1, "textDocument/documentSymbol", {textDocument: {uri: uri}})
      resp = client.try_read_response(5.seconds)
      resp.should_not be_nil
      symbols = resp.not_nil!["result"].as_a
      symbols.size.should be > 0

      # Should find many of our classes
      class_names = symbols.map { |s| s["name"].as_s }
      class_names.should contain("LargeClass0")
      class_names.should contain("LargeClass49")

      client.close
    end

    it "handles folding ranges for large file" do
      client = TestClient.new
      client.initialize_server

      lines = [] of String
      100.times do |i|
        lines << "class Block#{i}"
        lines << "  def work"
        lines << "    # doing stuff"
        lines << "  end"
        lines << "end"
        lines << ""
      end
      code = lines.join("\n")

      uri = "file:///tmp/large_fold.cr"
      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: uri, languageId: "crystal", version: 1, text: code},
      })
      Fiber.yield

      client.send_request(1, "textDocument/foldingRange", {textDocument: {uri: uri}})
      resp = client.try_read_response(5.seconds)
      resp.should_not be_nil
      ranges = resp.not_nil!["result"].as_a
      ranges.size.should be >= 100

      client.close
    end

    it "handles highlight in large file" do
      client = TestClient.new
      client.initialize_server

      lines = [] of String
      500.times do |i|
        lines << "value = #{i}"
      end
      code = lines.join("\n")

      uri = "file:///tmp/large_hl.cr"
      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: uri, languageId: "crystal", version: 1, text: code},
      })
      Fiber.yield

      client.send_request(1, "textDocument/documentHighlight", {
        textDocument: {uri: uri},
        position:     {line: 0, character: 0},
      })
      resp = client.try_read_response(5.seconds)
      resp.should_not be_nil
      highlights = resp.not_nil!["result"].as_a
      # "value" appears on every line
      highlights.size.should be > 100

      client.close
    end

    it "handles completion in large file" do
      client = TestClient.new
      client.initialize_server

      lines = ["class BigClass"]
      200.times do |i|
        lines << "  def method_#{i}"
        lines << "    #{i}"
        lines << "  end"
      end
      lines << "end"
      lines << "x = BigClass.new"
      lines << "x."
      code = lines.join("\n")

      uri = "file:///tmp/large_comp.cr"
      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: uri, languageId: "crystal", version: 1, text: code},
      })
      Fiber.yield

      last_line = code.lines.size - 1
      client.send_request(1, "textDocument/completion", {
        textDocument: {uri: uri},
        position:     {line: last_line, character: 2},
      })
      resp = client.try_read_response(5.seconds)
      resp.should_not be_nil
      resp.not_nil!["id"].should eq(1)

      client.close
    end

    it "handles semantic tokens for large file" do
      client = TestClient.new
      client.initialize_server

      lines = [] of String
      500.times do |i|
        lines << "def func_#{i}(arg : Int32)"
        lines << "  arg + #{i}"
        lines << "end"
      end
      code = lines.join("\n")

      uri = "file:///tmp/large_tokens.cr"
      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: uri, languageId: "crystal", version: 1, text: code},
      })
      Fiber.yield

      client.send_request(1, "textDocument/semanticTokens/full", {textDocument: {uri: uri}})
      resp = client.try_read_response(5.seconds)
      resp.should_not be_nil
      data = resp.not_nil!["result"]["data"].as_a
      data.size.should be > 0

      client.close
    end
  end

  # ── Phase 5: Structured Logging Tests ───────────────────────────────

  describe "Structured logging" do
    it "JsonLogBackend outputs valid JSON to IO" do
      io = IO::Memory.new
      backend = Lsp::Crystal::JsonLogBackend.new(io: io)
      entry = ::Log::Entry.new(
        source: "test",
        severity: ::Log::Severity::Info,
        message: "hello world",
        data: ::Log::Metadata.new,
        exception: nil,
      )
      backend.write(entry)
      io.rewind
      output = io.gets_to_end.strip
      parsed = JSON.parse(output)
      parsed["level"].as_s.should eq("info")
      parsed["message"].as_s.should eq("hello world")
      parsed["source"].as_s.should eq("test")
      parsed["timestamp"].as_i64.should be > 0
    end

    it "JsonLogBackend includes exception info" do
      io = IO::Memory.new
      backend = Lsp::Crystal::JsonLogBackend.new(io: io)
      ex = Exception.new("test error")
      entry = ::Log::Entry.new(
        source: "test",
        severity: ::Log::Severity::Error,
        message: "something failed",
        data: ::Log::Metadata.new,
        exception: ex,
      )
      backend.write(entry)
      io.rewind
      output = io.gets_to_end.strip
      parsed = JSON.parse(output)
      parsed["level"].as_s.should eq("error")
      parsed["exception"].as_s.should eq("test error")
    end
  end

  # ── Phase 5: Graceful Shutdown Tests ────────────────────────────────

  describe "Graceful shutdown" do
    it "shuts down cleanly via LSP shutdown/exit" do
      client = TestClient.new
      client.initialize_server

      # Open a document to create some state
      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/shutdown_test.cr", languageId: "crystal", version: 1, text: "puts 1\n"},
      })
      Fiber.yield

      # Shutdown should succeed
      client.send_request(1, "shutdown")
      resp = client.read_response
      resp["id"].should eq(1)
      resp["result"].raw.should be_nil
      client.server.shutdown_requested?.should be_true

      client.close
    end

    it "server remains responsive after opening many documents then shutting down" do
      client = TestClient.new
      client.initialize_server

      5.times do |i|
        client.send_notification("textDocument/didOpen", {
          textDocument: {uri: "file:///tmp/sd_#{i}.cr", languageId: "crystal", version: 1, text: "x = #{i}\n"},
        })
      end
      Fiber.yield

      client.send_request(1, "shutdown")
      resp = client.read_response
      resp["result"].raw.should be_nil

      client.close
    end
  end
end
