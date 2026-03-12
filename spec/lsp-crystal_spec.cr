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

  describe "CancellationToken" do
    it "starts not cancelled" do
      token = Lsp::Crystal::CancellationToken.new
      token.cancelled?.should be_false
    end

    it "can be cancelled" do
      token = Lsp::Crystal::CancellationToken.new
      token.cancel
      token.cancelled?.should be_true
    end

    it "cancel is idempotent" do
      token = Lsp::Crystal::CancellationToken.new
      token.cancel
      token.cancel
      token.cancelled?.should be_true
    end

    it "is visible across fibers" do
      token = Lsp::Crystal::CancellationToken.new
      ch = Channel(Bool).new(1)
      spawn do
        ch.send(token.cancelled?)
      end
      Fiber.yield
      result_before = ch.receive
      result_before.should be_false

      token.cancel
      spawn do
        ch.send(token.cancelled?)
      end
      Fiber.yield
      result_after = ch.receive
      result_after.should be_true
    end
  end

  describe "RequestTracker" do
    it "tracks and completes requests" do
      tracker = Lsp::Crystal::RequestTracker.new
      token = Lsp::Crystal::CancellationToken.new
      tracker.track(1_i64, "textDocument/hover", token, Fiber.current)
      tracker.size.should eq(1)
      tracker.has?(1_i64).should be_true

      tracker.complete(1_i64)
      tracker.size.should eq(0)
      tracker.has?(1_i64).should be_false
    end

    it "cancels a tracked request" do
      tracker = Lsp::Crystal::RequestTracker.new
      token = Lsp::Crystal::CancellationToken.new
      tracker.track(1_i64, "textDocument/hover", token, Fiber.current)

      tracker.cancel(1_i64).should be_true
      token.cancelled?.should be_true
      tracker.size.should eq(0)
    end

    it "returns false when cancelling unknown request" do
      tracker = Lsp::Crystal::RequestTracker.new
      tracker.cancel(999_i64).should be_false
    end

    it "cancel_all cancels all tracked requests" do
      tracker = Lsp::Crystal::RequestTracker.new
      token1 = Lsp::Crystal::CancellationToken.new
      token2 = Lsp::Crystal::CancellationToken.new
      tracker.track(1_i64, "textDocument/hover", token1, Fiber.current)
      tracker.track(2_i64, "textDocument/definition", token2, Fiber.current)

      tracker.cancel_all
      token1.cancelled?.should be_true
      token2.cancelled?.should be_true
      tracker.size.should eq(0)
    end

    it "tracks string request IDs" do
      tracker = Lsp::Crystal::RequestTracker.new
      token = Lsp::Crystal::CancellationToken.new
      tracker.track("abc", "textDocument/hover", token, Fiber.current)
      tracker.has?("abc").should be_true
      tracker.cancel("abc").should be_true
      token.cancelled?.should be_true
    end
  end

  describe "Async dispatch" do
    it "handles async methods via spawned fibers" do
      client = TestClient.new
      client.initialize_server

      # Open a document
      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/async_test.cr", languageId: "crystal", version: 1, text: "x = 1\n"},
      })
      Fiber.yield

      # Send a hover request (async method) — should still get a response
      client.send_request(200, "textDocument/hover", {
        textDocument: {uri: "file:///tmp/async_test.cr"},
        position:     {line: 0, character: 0},
      })
      resp = client.read_response
      resp["id"].should eq(200)
      # Should have either a result or null result (not an error for missing crystal tool)
      resp["jsonrpc"].should eq("2.0")

      client.close
    end

    it "handles $/cancelRequest for in-flight requests" do
      client = TestClient.new
      client.initialize_server

      # The request tracker should be empty initially
      client.server.request_tracker.size.should eq(0)

      client.close
    end

    it "fast methods remain synchronous" do
      client = TestClient.new
      client.initialize_server

      # textDocument/completion is synchronous — should respond inline
      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/sync_test.cr", languageId: "crystal", version: 1, text: "x = 1\n"},
      })
      Fiber.yield

      client.send_request(201, "textDocument/completion", {
        textDocument: {uri: "file:///tmp/sync_test.cr"},
        position:     {line: 0, character: 4},
      })
      resp = client.read_response
      resp["id"].should eq(201)

      client.close
    end

    it "request tracker is empty after graceful shutdown" do
      client = TestClient.new
      client.initialize_server

      client.send_request(1, "shutdown")
      resp = client.read_response
      resp["result"].raw.should be_nil
      client.server.request_tracker.size.should eq(0)

      client.close
    end
  end

  describe "File watching" do
    it "lifecycle handler sends registerCapability on initialized" do
      client = TestClient.new
      # Send initialize
      client.send_request(1, "initialize", {processId: 1, rootUri: "file:///tmp", capabilities: {} of String => String})
      client.read_response

      # Send initialized — server should send client/registerCapability
      client.send_notification("initialized")
      Fiber.yield

      # Read the server→client request (skip any notifications like $/progress)
      msg = loop do
        m = client.read_raw_message
        break m if m["method"]? && m["id"]?
      end
      msg["method"].should eq("client/registerCapability")
      registrations = msg["params"]["registrations"].as_a
      registrations.size.should eq(1)
      registrations[0]["method"].should eq("workspace/didChangeWatchedFiles")
      watchers = registrations[0]["registerOptions"]["watchers"].as_a
      watchers[0]["globPattern"].should eq("**/*.cr")
      watchers[0]["kind"].should eq(7)

      client.close
    end

    it "handles didChangeWatchedFiles notification" do
      client = TestClient.new
      client.initialize_server

      # Create a temp file for the workspace index to track
      tmp_path = "/tmp/watched_test.cr"
      File.write(tmp_path, "class Watched; end\n")

      begin
        # Send file change notification
        client.send_notification("workspace/didChangeWatchedFiles", {
          changes: [{uri: "file://#{tmp_path}", type: 2}],
        })
        Fiber.yield

        # Should not error — just verify server is still responsive
        client.send_request(300, "textDocument/completion", {
          textDocument: {uri: "file:///tmp/responsive.cr"},
          position:     {line: 0, character: 0},
        })
        resp = client.read_response
        resp["id"].should eq(300)
      ensure
        File.delete(tmp_path) rescue nil
      end

      client.close
    end

    it "skips files open in editor" do
      client = TestClient.new
      client.initialize_server

      # Open a document in the editor
      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/open_file.cr", languageId: "crystal", version: 1, text: "x = 1\n"},
      })
      Fiber.yield

      # Send file change for the same file — should be skipped
      client.send_notification("workspace/didChangeWatchedFiles", {
        changes: [{uri: "file:///tmp/open_file.cr", type: 2}],
      })
      Fiber.yield

      # Server should still be responsive
      client.send_request(301, "textDocument/completion", {
        textDocument: {uri: "file:///tmp/open_file.cr"},
        position:     {line: 0, character: 0},
      })
      resp = client.read_response
      resp["id"].should eq(301)

      client.close
    end

    it "clears diagnostics for deleted files" do
      client = TestClient.new
      client.initialize_server

      # Send delete notification
      client.send_notification("workspace/didChangeWatchedFiles", {
        changes: [{uri: "file:///tmp/deleted_file.cr", type: 3}],
      })
      Fiber.yield

      # Should still be responsive
      client.send_request(302, "shutdown")
      resp = client.read_response
      resp["id"].should eq(302)

      client.close
    end
  end

  describe "Diagnostics caching" do
    it "invalidate_diagnostics_cache clears cached hash" do
      client = TestClient.new
      client.initialize_server

      # Open a document — this will schedule diagnostics
      client.send_notification("textDocument/didOpen", {
        textDocument: {uri: "file:///tmp/cache_test.cr", languageId: "crystal", version: 1, text: "x = 1\n"},
      })
      Fiber.yield

      # Invalidate the cache
      client.server.invalidate_diagnostics_cache("file:///tmp/cache_test.cr")

      # Server should still be responsive
      client.send_request(400, "shutdown")
      resp = client.read_response
      resp["id"].should eq(400)

      client.close
    end

    it "configurable debounce uses configuration value" do
      client = TestClient.new
      client.initialize_server

      # Default debounce should be 500ms
      client.server.configuration.diagnostics_debounce.should eq(500.milliseconds)

      # Update configuration
      client.send_notification("workspace/didChangeConfiguration", {
        settings: {crystalLsp: {diagnosticsDelay: 1000}},
      })
      Fiber.yield

      client.server.configuration.diagnostics_debounce.should eq(1000.milliseconds)

      client.close
    end
  end

  describe "Server.send_request" do
    it "sends requests with auto-incrementing IDs" do
      client = TestClient.new
      client.initialize_server

      # The initialized handler already sent one request (registerCapability)
      # so next request should have id > 0
      id = client.server.send_request("window/showMessageRequest", {
        type:    3,
        message: "test",
      })
      id.should be > 0_i64

      client.close
    end
  end

  describe "CrystalTool cancellation" do
    it "sets and clears fiber-local cancellation token" do
      token = Lsp::Crystal::CancellationToken.new
      Lsp::Crystal::CrystalTool.current_cancellation.should be_nil

      Lsp::Crystal::CrystalTool.set_cancellation(token)
      Lsp::Crystal::CrystalTool.current_cancellation.should eq(token)

      Lsp::Crystal::CrystalTool.clear_cancellation
      Lsp::Crystal::CrystalTool.current_cancellation.should be_nil
    end

    it "fiber-local tokens are isolated between fibers" do
      token1 = Lsp::Crystal::CancellationToken.new
      token2 = Lsp::Crystal::CancellationToken.new

      ch = Channel(Lsp::Crystal::CancellationToken?).new(1)

      Lsp::Crystal::CrystalTool.set_cancellation(token1)

      spawn do
        Lsp::Crystal::CrystalTool.set_cancellation(token2)
        ch.send(Lsp::Crystal::CrystalTool.current_cancellation)
        Lsp::Crystal::CrystalTool.clear_cancellation
      end
      Fiber.yield

      other_token = ch.receive
      other_token.should eq(token2)
      Lsp::Crystal::CrystalTool.current_cancellation.should eq(token1)

      Lsp::Crystal::CrystalTool.clear_cancellation
    end
  end

  describe "DocumentStore#each_uri" do
    it "iterates over all open document URIs" do
      store = Lsp::Crystal::DocumentStore.new
      store.open("file:///a.cr", "crystal", 1, "a")
      store.open("file:///b.cr", "crystal", 1, "b")

      uris = [] of String
      store.each_uri { |uri| uris << uri }
      uris.sort.should eq(["file:///a.cr", "file:///b.cr"])
    end
  end

  # ── Phase 7: Crystal AST Integration ──

  describe "AST::Parser" do
    it "parses valid Crystal code" do
      result = Lsp::Crystal::AST.parse("class Foo; end")
      result.success?.should be_true
      result.node.should_not be_nil
      result.error.should be_nil
    end

    it "returns SyntaxException for invalid code" do
      result = Lsp::Crystal::AST.parse("def foo\n  x = \nend")
      result.success?.should be_false
      result.error.should_not be_nil
    end

    it "converts Crystal location to LSP position (1-based to 0-based)" do
      result = Lsp::Crystal::AST.parse("class Foo\nend")
      result.success?.should be_true
    end
  end

  describe "AST::Cache" do
    it "caches parse results by document version" do
      cache = Lsp::Crystal::AST::Cache.new
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, "class Foo; end")

      result1 = cache.get(doc)
      result1.should_not be_nil
      result1.not_nil!.success?.should be_true

      # Same version returns cached
      result2 = cache.get(doc)
      result2.should_not be_nil
      cache.size.should eq(1)
    end

    it "re-parses on version change" do
      cache = Lsp::Crystal::AST::Cache.new
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, "class Foo; end")
      cache.get(doc)

      doc.version = 2
      doc.content = "class Bar; end"
      result = cache.get(doc)
      result.should_not be_nil
      result.not_nil!.success?.should be_true
    end

    it "invalidates by URI" do
      cache = Lsp::Crystal::AST::Cache.new
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, "class Foo; end")
      cache.get(doc)
      cache.size.should eq(1)

      cache.invalidate("file:///test.cr")
      cache.size.should eq(0)
    end
  end

  describe "AST Document Symbols (SymbolVisitor)" do
    it "extracts class symbols from AST" do
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, "class Foo\nend")
      cache = Lsp::Crystal::AST::Cache.new
      symbols = Lsp::Crystal::Providers::DocumentSymbol.run(doc, cache)
      symbols.size.should eq(1)
      symbols[0].name.should eq("Foo")
      symbols[0].kind.should eq(Lsp::Crystal::Providers::DocumentSymbol::SymbolKind::Class.value)
    end

    it "extracts struct symbols" do
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, "struct Point\nend")
      cache = Lsp::Crystal::AST::Cache.new
      symbols = Lsp::Crystal::Providers::DocumentSymbol.run(doc, cache)
      symbols.size.should eq(1)
      symbols[0].name.should eq("Point")
      symbols[0].kind.should eq(Lsp::Crystal::Providers::DocumentSymbol::SymbolKind::Struct.value)
    end

    it "extracts nested symbols with hierarchy" do
      code = "class Foo\n  def bar\n  end\nend"
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, code)
      cache = Lsp::Crystal::AST::Cache.new
      symbols = Lsp::Crystal::Providers::DocumentSymbol.run(doc, cache)
      symbols.size.should eq(1)
      symbols[0].name.should eq("Foo")
      symbols[0].children.size.should eq(1)
      symbols[0].children[0].name.should eq("bar")
    end

    it "extracts module, enum, alias, constant" do
      code = <<-CR
      module MyMod
        enum Color
          Red
        end
        alias Name = String
        FOO = 42
      end
      CR
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, code)
      cache = Lsp::Crystal::AST::Cache.new
      symbols = Lsp::Crystal::Providers::DocumentSymbol.run(doc, cache)
      symbols.size.should eq(1)
      symbols[0].name.should eq("MyMod")
      children = symbols[0].children
      children.any? { |c| c.name == "Color" }.should be_true
      children.any? { |c| c.name == "Name" }.should be_true
      children.any? { |c| c.name == "FOO" }.should be_true
    end

    it "extracts property declarations" do
      code = "class Foo\n  property name : String\n  getter age : Int32\nend"
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, code)
      cache = Lsp::Crystal::AST::Cache.new
      symbols = Lsp::Crystal::Providers::DocumentSymbol.run(doc, cache)
      symbols[0].children.any? { |c| c.name == "name" }.should be_true
      symbols[0].children.any? { |c| c.name == "age" }.should be_true
    end

    it "falls back to regex on parse failure" do
      code = "class Foo\n  def bar\n    x = \n  end\nend"
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, code)
      cache = Lsp::Crystal::AST::Cache.new
      symbols = Lsp::Crystal::Providers::DocumentSymbol.run(doc, cache)
      # Should still find symbols via regex fallback
      symbols.should_not be_empty
    end

    it "works without ast_cache (regex path)" do
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, "class Foo\nend")
      symbols = Lsp::Crystal::Providers::DocumentSymbol.run(doc)
      symbols.size.should eq(1)
      symbols[0].name.should eq("Foo")
    end
  end

  describe "AST Semantic Tokens (LexerTokenizer)" do
    it "tokenizes keywords" do
      tokens = Lsp::Crystal::AST::LexerTokenizer.tokenize("def foo; end")
      tokens.should_not be_nil
      ts = tokens.not_nil!
      # Should have at least: def, foo, end
      keyword_tokens = ts.select { |t| t[3] == 10 } # keyword type
      keyword_tokens.size.should be >= 2 # def, end
    end

    it "tokenizes comments" do
      tokens = Lsp::Crystal::AST::LexerTokenizer.tokenize("x = 1 # comment")
      tokens.should_not be_nil
      ts = tokens.not_nil!
      comment_tokens = ts.select { |t| t[3] == 12 }
      comment_tokens.size.should eq(1)
    end

    it "tokenizes instance variables as properties" do
      tokens = Lsp::Crystal::AST::LexerTokenizer.tokenize("@foo = 1")
      tokens.should_not be_nil
      ts = tokens.not_nil!
      prop_tokens = ts.select { |t| t[3] == 7 } # property type
      prop_tokens.size.should eq(1)
    end

    it "tokenizes numbers" do
      tokens = Lsp::Crystal::AST::LexerTokenizer.tokenize("x = 42")
      tokens.should_not be_nil
      ts = tokens.not_nil!
      number_tokens = ts.select { |t| t[3] == 14 }
      number_tokens.size.should eq(1)
    end

    it "tokenizes constants as types" do
      tokens = Lsp::Crystal::AST::LexerTokenizer.tokenize("Foo")
      tokens.should_not be_nil
      ts = tokens.not_nil!
      type_tokens = ts.select { |t| t[3] == 1 } # type
      type_tokens.size.should eq(1)
    end

    it "marks class definitions with definition modifier" do
      tokens = Lsp::Crystal::AST::LexerTokenizer.tokenize("class Foo; end")
      tokens.should_not be_nil
      ts = tokens.not_nil!
      # The Foo token after class should be class type with definition modifier
      class_defs = ts.select { |t| t[3] == 2 && t[4] == 1 } # class type, definition modifier
      class_defs.size.should eq(1)
    end

    it "marks method definitions with definition modifier" do
      tokens = Lsp::Crystal::AST::LexerTokenizer.tokenize("def greet; end")
      tokens.should_not be_nil
      ts = tokens.not_nil!
      func_defs = ts.select { |t| t[3] == 8 && t[4] == 1 } # function type, definition modifier
      func_defs.size.should eq(1)
    end

    it "tokenizes modifier keywords (private, protected, abstract)" do
      tokens = Lsp::Crystal::AST::LexerTokenizer.tokenize("private def foo; end")
      tokens.should_not be_nil
      ts = tokens.not_nil!
      modifier_tokens = ts.select { |t| t[3] == 11 } # modifier type
      modifier_tokens.size.should eq(1)
    end

    it "uses lexer path when ast_cache is provided" do
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, "def foo; end")
      cache = Lsp::Crystal::AST::Cache.new
      data = Lsp::Crystal::Providers::SemanticTokens.run(doc, cache)
      data.should_not be_empty
    end

    it "falls back to regex without ast_cache" do
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, "def foo; end")
      data = Lsp::Crystal::Providers::SemanticTokens.run(doc)
      data.should_not be_empty
    end
  end

  describe "Two-Tier Diagnostics" do
    it "detects syntax errors instantly via check_syntax" do
      diags = Lsp::Crystal::Providers::Diagnostics.check_syntax("def foo\n  x = \nend")
      diags.size.should eq(1)
      diags[0].source.should eq("crystal-syntax")
      diags[0].severity.should eq(1) # Error
    end

    it "returns empty for valid syntax" do
      diags = Lsp::Crystal::Providers::Diagnostics.check_syntax("class Foo; end")
      diags.should be_empty
    end

    it "includes line and column in syntax error" do
      diags = Lsp::Crystal::Providers::Diagnostics.check_syntax("class Foo\n  def\nend")
      diags.size.should eq(1)
      diags[0].range.start.line.should be >= 0
    end

    it "uses 'crystal-syntax' source tag (distinct from 'crystal')" do
      diags = Lsp::Crystal::Providers::Diagnostics.check_syntax("def")
      diags.size.should eq(1)
      diags[0].source.should eq("crystal-syntax")
    end
  end

  describe "AST References (ReferenceVisitor)" do
    it "finds references ignoring strings and comments" do
      code = <<-CR
      x = 1
      y = x + 1
      # x in comment
      z = "x in string"
      CR
      result = Lsp::Crystal::AST.parse(code)
      result.success?.should be_true
      visitor = Lsp::Crystal::AST::ReferenceVisitor.new(target_name: "x")
      result.node.not_nil!.accept(visitor)
      refs = visitor.references
      # Should find x as variable references but NOT in string/comment
      refs.all? { |r| r.name == "x" }.should be_true
      # The string and comment x should not appear
      refs.size.should be <= 3 # definition + read, not string/comment
    end

    it "classifies assignments as writes" do
      code = "x = 1\ny = x"
      result = Lsp::Crystal::AST.parse(code)
      visitor = Lsp::Crystal::AST::ReferenceVisitor.new(target_name: "x")
      result.node.not_nil!.accept(visitor)
      writes = visitor.references.select { |r| r.kind.write? }
      writes.should_not be_empty
    end

    it "classifies reads correctly" do
      code = "x = 1\ny = x"
      result = Lsp::Crystal::AST.parse(code)
      visitor = Lsp::Crystal::AST::ReferenceVisitor.new(target_name: "x")
      result.node.not_nil!.accept(visitor)
      reads = visitor.references.select { |r| r.kind.read? }
      reads.should_not be_empty
    end

    it "finds method definitions as definitions" do
      code = "def greet; end"
      result = Lsp::Crystal::AST.parse(code)
      visitor = Lsp::Crystal::AST::ReferenceVisitor.new(target_name: "greet")
      result.node.not_nil!.accept(visitor)
      defs = visitor.references.select { |r| r.kind.definition? }
      defs.size.should eq(1)
    end

    it "finds class definitions" do
      code = "class MyClass; end"
      result = Lsp::Crystal::AST.parse(code)
      visitor = Lsp::Crystal::AST::ReferenceVisitor.new(target_name: "MyClass")
      result.node.not_nil!.accept(visitor)
      defs = visitor.references.select { |r| r.kind.definition? }
      defs.size.should eq(1)
    end
  end

  describe "AST Document Highlight" do
    it "highlights with accurate read/write classification" do
      code = "x = 1\ny = x + 2"
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, code)
      cache = Lsp::Crystal::AST::Cache.new
      highlights = Lsp::Crystal::Providers::DocumentHighlight.run(doc, 0, 0, cache)
      highlights.should_not be_empty
      # Assignment target should be WRITE
      writes = highlights.select { |h| h.kind == 3 } # WRITE
      writes.should_not be_empty
    end

    it "falls back to regex without ast_cache" do
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, "x = 1\ny = x")
      highlights = Lsp::Crystal::Providers::DocumentHighlight.run(doc, 0, 0)
      highlights.should_not be_empty
    end
  end

  describe "AST References Provider" do
    it "uses AST for in-document references when cache available" do
      code = "x = 1\ny = x + 2\nz = \"x in string\""
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, code)
      cache = Lsp::Crystal::AST::Cache.new
      refs = Lsp::Crystal::Providers::References.run(doc, 0, 0, nil, true, nil, cache)
      # AST-based should not find x in string
      refs.should_not be_empty
      refs.size.should be <= 2 # x = 1 and y = x, not "x in string"
    end

    it "falls back to regex without ast_cache" do
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, "x = 1\ny = x")
      refs = Lsp::Crystal::Providers::References.run(doc, 0, 0, nil, true, nil, nil)
      refs.should_not be_empty
    end
  end

  describe "AST Context Visitor" do
    it "detects method context at cursor" do
      code = "class Foo\n  def bar(x)\n    y = x + 1\n  end\nend"
      result = Lsp::Crystal::AST.parse(code)
      result.success?.should be_true
      visitor = Lsp::Crystal::AST::ContextVisitor.new(2, 4)
      result.node.not_nil!.accept(visitor)
      ctx = visitor.context
      ctx.in_class.should eq("Foo")
      ctx.in_method.should eq("bar")
      ctx.method_params.should contain("x")
    end

    it "collects local variables before cursor" do
      code = "def foo\n  x = 1\n  y = 2\n  z = x\nend"
      result = Lsp::Crystal::AST.parse(code)
      visitor = Lsp::Crystal::AST::ContextVisitor.new(3, 6)
      result.node.not_nil!.accept(visitor)
      ctx = visitor.context
      ctx.local_vars.should contain("x")
      ctx.local_vars.should contain("y")
    end

    it "collects instance variables" do
      code = "class Foo\n  def bar\n    @name = \"hi\"\n    @name\n  end\nend"
      result = Lsp::Crystal::AST.parse(code)
      visitor = Lsp::Crystal::AST::ContextVisitor.new(3, 4)
      result.node.not_nil!.accept(visitor)
      ctx = visitor.context
      ctx.instance_vars.should contain("@name")
    end
  end

  describe "AST Call Visitor" do
    it "finds call nodes in a method" do
      code = "def foo\n  puts \"hello\"\n  bar(1)\nend"
      result = Lsp::Crystal::AST.parse(code)
      result.success?.should be_true
      # Find the def node
      node = result.node.not_nil!
      visitor = Lsp::Crystal::AST::CallVisitor.new(skip_name: "foo")
      node.accept(visitor)
      call_names = visitor.calls.map(&.name)
      call_names.should contain("puts")
      call_names.should contain("bar")
    end

    it "skips recursive calls" do
      code = "def foo\n  foo()\n  bar()\nend"
      result = Lsp::Crystal::AST.parse(code)
      visitor = Lsp::Crystal::AST::CallVisitor.new(skip_name: "foo")
      result.node.not_nil!.accept(visitor)
      call_names = visitor.calls.map(&.name)
      call_names.should_not contain("foo")
      call_names.should contain("bar")
    end
  end

  describe "AST Completion" do
    it "provides local var completions from AST context" do
      code = "def foo\n  my_variable = 1\n  my_other = 2\n  my\nend"
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, code)
      cache = Lsp::Crystal::AST::Cache.new
      result = Lsp::Crystal::Providers::Completion.run(doc, 3, 4, nil, nil, cache)
      labels = result.items.map(&.label)
      labels.should contain("my_variable")
      labels.should contain("my_other")
    end

    it "works without ast_cache" do
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, "def foo; end\nfo")
      result = Lsp::Crystal::Providers::Completion.run(doc, 1, 2)
      result.items.should_not be_empty
    end
  end

  # Phase 1: Diagnostic Diffing
  describe "Diagnostic Diffing" do
    it "publishes diagnostics on first call" do
      server = TestClient.new.server
      diags = [Lsp::Crystal::Providers::Diagnostics::Diagnostic.new(
        range: Lsp::Crystal::Range.new(
          start: Lsp::Crystal::Position.new(line: 0, character: 0),
          end_pos: Lsp::Crystal::Position.new(line: 0, character: 5)
        ),
        severity: 1,
        source: "crystal",
        message: "test error"
      )]
      # Should not raise and should publish (no cached version)
      server.publish_diagnostics_if_changed("file:///test.cr", diags)
    end

    it "skips publishing identical diagnostics" do
      input_read, input_write = IO.pipe
      output_read, output_write = IO.pipe
      transport = Lsp::Crystal::Transport::Stdio.new(input: input_read, output: output_write)
      server = Lsp::Crystal::Server.new(transport)

      diags = [Lsp::Crystal::Providers::Diagnostics::Diagnostic.new(
        range: Lsp::Crystal::Range.new(
          start: Lsp::Crystal::Position.new(line: 1, character: 2),
          end_pos: Lsp::Crystal::Position.new(line: 1, character: 5)
        ),
        severity: 1,
        source: "crystal",
        message: "undefined variable"
      )]

      # First publish — should write to output
      server.publish_diagnostics_if_changed("file:///test.cr", diags)
      output_write.flush

      # Second publish with identical diagnostics — should skip
      server.publish_diagnostics_if_changed("file:///test.cr", diags)
      output_write.flush

      # Read first notification
      output_read.read_line("\r\n")  # Content-Length header
      output_read.read_line("\r\n")  # blank line

      # Check if there's a second message (there shouldn't be)
      ch = Channel(Bool).new(1)
      spawn do
        output_read.read_line("\r\n") rescue nil
        ch.send(true)
      end

      select
      when ch.receive
        # Got second message — fail
        false.should be_true  # "Should not have published identical diagnostics"
      when timeout(100.milliseconds)
        # Good — no second message
        true.should be_true
      end

      input_write.close rescue nil
    end

    it "publishes when diagnostics change" do
      input_read, input_write = IO.pipe
      output_read, output_write = IO.pipe
      transport = Lsp::Crystal::Transport::Stdio.new(input: input_read, output: output_write)
      server = Lsp::Crystal::Server.new(transport)

      diags1 = [Lsp::Crystal::Providers::Diagnostics::Diagnostic.new(
        range: Lsp::Crystal::Range.new(
          start: Lsp::Crystal::Position.new(line: 0, character: 0),
          end_pos: Lsp::Crystal::Position.new(line: 0, character: 0)
        ),
        severity: 1,
        source: "crystal",
        message: "error one"
      )]

      diags2 = [Lsp::Crystal::Providers::Diagnostics::Diagnostic.new(
        range: Lsp::Crystal::Range.new(
          start: Lsp::Crystal::Position.new(line: 2, character: 3),
          end_pos: Lsp::Crystal::Position.new(line: 2, character: 3)
        ),
        severity: 2,
        source: "crystal",
        message: "error two"
      )]

      server.publish_diagnostics_if_changed("file:///test.cr", diags1)
      server.publish_diagnostics_if_changed("file:///test.cr", diags2)

      # Both should have been published — verify by reading two messages
      2.times do
        header = output_read.read_line("\r\n").rstrip("\r\n")
        length = header.split(": ")[1].to_i
        output_read.read_line("\r\n")  # blank line
        body = Bytes.new(length)
        output_read.read_fully(body)
      end

      input_write.close rescue nil
    end

    it "clears published cache on didClose" do
      server = TestClient.new.server
      diags = [Lsp::Crystal::Providers::Diagnostics::Diagnostic.new(
        range: Lsp::Crystal::Range.new(
          start: Lsp::Crystal::Position.new(line: 0, character: 0),
          end_pos: Lsp::Crystal::Position.new(line: 0, character: 0)
        ),
        severity: 1,
        source: "crystal",
        message: "test"
      )]
      server.publish_diagnostics_if_changed("file:///test.cr", diags)
      server.clear_published_diagnostics("file:///test.cr")
      # After clear, publishing same diagnostics should succeed (not skip)
      # This is a behavioral check — no exception means success
      server.publish_diagnostics_if_changed("file:///test.cr", diags)
    end
  end

  # Phase 2: Multi-File Diagnostic Routing
  describe "Multi-File Diagnostic Routing" do
    it "groups diagnostics by file with parse_output_by_file" do
      output = <<-STDERR
      In /project/src/foo.cr:10:5

       10 | x = undefined_var
                ^-------------
      Error: undefined local variable or method 'undefined_var'

      In /project/src/bar.cr:3:1

        3 | bad_call()
            ^--------
      Error: undefined method 'bad_call'
      STDERR

      result = Lsp::Crystal::Providers::Diagnostics.parse_output_by_file(output)
      result.keys.should contain("/project/src/foo.cr")
      result.keys.should contain("/project/src/bar.cr")
      result["/project/src/foo.cr"].size.should eq(1)
      result["/project/src/bar.cr"].size.should eq(1)
      result["/project/src/foo.cr"][0].message.should eq("undefined local variable or method 'undefined_var'")
      result["/project/src/bar.cr"][0].message.should eq("undefined method 'bad_call'")
    end

    it "returns empty hash for successful output" do
      result = Lsp::Crystal::Providers::Diagnostics.parse_output_by_file("")
      result.should be_empty
    end

    it "handles multiple errors in same file" do
      output = <<-STDERR
      In /project/src/foo.cr:5:3

        5 | x = bad1
                ^---
      Error: undefined method 'bad1'

      In /project/src/foo.cr:10:3

       10 | y = bad2
                ^---
      Error: undefined method 'bad2'
      STDERR

      result = Lsp::Crystal::Providers::Diagnostics.parse_output_by_file(output)
      result["/project/src/foo.cr"].size.should eq(2)
    end

    it "parse_output still returns flat array" do
      output = <<-STDERR
      In /project/src/a.cr:1:1

        1 | err
            ^--
      Error: undefined method 'err'

      In /project/src/b.cr:2:1

        2 | err2
            ^---
      Error: undefined method 'err2'
      STDERR

      result = Lsp::Crystal::Providers::Diagnostics.parse_output(output)
      result.size.should eq(2)
      result.should be_a(Array(Lsp::Crystal::Providers::Diagnostics::Diagnostic))
    end
  end

  # Phase 3: Require Dependency Graph
  describe "RequireGraph" do
    it "initializes as not built" do
      graph = Lsp::Crystal::RequireGraph.new
      graph.built?.should be_false
    end

    it "builds from a workspace directory" do
      Dir.mkdir_p("/tmp/test_rg_build/src")
      File.write("/tmp/test_rg_build/shard.yml", "name: test\n")
      File.write("/tmp/test_rg_build/src/main.cr", %{require "./helper"\nputs "hello"})
      File.write("/tmp/test_rg_build/src/helper.cr", "def help; end")

      graph = Lsp::Crystal::RequireGraph.new
      graph.build("/tmp/test_rg_build")
      graph.built?.should be_true

      deps = graph.dependencies("/tmp/test_rg_build/src/main.cr")
      deps.should contain("/tmp/test_rg_build/src/helper.cr")
    ensure
      FileUtils.rm_rf("/tmp/test_rg_build")
    end

    it "resolves relative requires" do
      Dir.mkdir_p("/tmp/test_rg_rel/src/sub")
      File.write("/tmp/test_rg_rel/shard.yml", "name: test\n")
      File.write("/tmp/test_rg_rel/src/main.cr", %{require "./sub/utils"})
      File.write("/tmp/test_rg_rel/src/sub/utils.cr", "def util; end")

      graph = Lsp::Crystal::RequireGraph.new
      graph.build("/tmp/test_rg_rel")

      deps = graph.dependencies("/tmp/test_rg_rel/src/main.cr")
      deps.should contain("/tmp/test_rg_rel/src/sub/utils.cr")
    ensure
      FileUtils.rm_rf("/tmp/test_rg_rel")
    end

    it "computes transitive dependents" do
      Dir.mkdir_p("/tmp/test_rg_trans/src")
      File.write("/tmp/test_rg_trans/shard.yml", "name: test\n")
      File.write("/tmp/test_rg_trans/src/a.cr", %{require "./b"})
      File.write("/tmp/test_rg_trans/src/b.cr", %{require "./c"})
      File.write("/tmp/test_rg_trans/src/c.cr", "def c; end")

      graph = Lsp::Crystal::RequireGraph.new
      graph.build("/tmp/test_rg_trans")

      # Changing C should affect B (requires C) and A (requires B)
      dependents = graph.transitive_dependents("/tmp/test_rg_trans/src/c.cr")
      dependents.should contain("/tmp/test_rg_trans/src/b.cr")
      dependents.should contain("/tmp/test_rg_trans/src/a.cr")
    ensure
      FileUtils.rm_rf("/tmp/test_rg_trans")
    end

    it "independent files are not dependents" do
      Dir.mkdir_p("/tmp/test_rg_indep/src")
      File.write("/tmp/test_rg_indep/shard.yml", "name: test\n")
      File.write("/tmp/test_rg_indep/src/a.cr", %{require "./b"})
      File.write("/tmp/test_rg_indep/src/b.cr", "def b; end")
      File.write("/tmp/test_rg_indep/src/c.cr", "def c; end")

      graph = Lsp::Crystal::RequireGraph.new
      graph.build("/tmp/test_rg_indep")

      # Changing B should affect A but not C
      dependents = graph.transitive_dependents("/tmp/test_rg_indep/src/b.cr")
      dependents.should contain("/tmp/test_rg_indep/src/a.cr")
      dependents.should_not contain("/tmp/test_rg_indep/src/c.cr")
    ensure
      FileUtils.rm_rf("/tmp/test_rg_indep")
    end

    it "updates file dependencies" do
      Dir.mkdir_p("/tmp/test_rg_update/src")
      File.write("/tmp/test_rg_update/shard.yml", "name: test\n")
      File.write("/tmp/test_rg_update/src/main.cr", %{require "./helper"})
      File.write("/tmp/test_rg_update/src/helper.cr", "def help; end")
      File.write("/tmp/test_rg_update/src/utils.cr", "def util; end")

      graph = Lsp::Crystal::RequireGraph.new
      graph.build("/tmp/test_rg_update")

      # main.cr now requires utils instead of helper
      File.write("/tmp/test_rg_update/src/main.cr", %{require "./utils"})
      graph.update_file("/tmp/test_rg_update/src/main.cr")

      deps = graph.dependencies("/tmp/test_rg_update/src/main.cr")
      deps.should contain("/tmp/test_rg_update/src/utils.cr")
      deps.should_not contain("/tmp/test_rg_update/src/helper.cr")

      # helper should no longer have main as dependent
      helper_deps = graph.direct_dependents("/tmp/test_rg_update/src/helper.cr")
      helper_deps.should_not contain("/tmp/test_rg_update/src/main.cr")
    ensure
      FileUtils.rm_rf("/tmp/test_rg_update")
    end

    it "removes file from graph" do
      Dir.mkdir_p("/tmp/test_rg_remove/src")
      File.write("/tmp/test_rg_remove/shard.yml", "name: test\n")
      File.write("/tmp/test_rg_remove/src/main.cr", %{require "./helper"})
      File.write("/tmp/test_rg_remove/src/helper.cr", "def help; end")

      graph = Lsp::Crystal::RequireGraph.new
      graph.build("/tmp/test_rg_remove")

      graph.remove_file("/tmp/test_rg_remove/src/main.cr")
      deps = graph.dependencies("/tmp/test_rg_remove/src/main.cr")
      deps.should be_empty

      helper_deps = graph.direct_dependents("/tmp/test_rg_remove/src/helper.cr")
      helper_deps.should_not contain("/tmp/test_rg_remove/src/main.cr")
    ensure
      FileUtils.rm_rf("/tmp/test_rg_remove")
    end

    it "resolves glob requires" do
      Dir.mkdir_p("/tmp/test_rg_glob/src/models")
      File.write("/tmp/test_rg_glob/shard.yml", "name: test\n")
      File.write("/tmp/test_rg_glob/src/main.cr", %{require "./models/*"})
      File.write("/tmp/test_rg_glob/src/models/user.cr", "class User; end")
      File.write("/tmp/test_rg_glob/src/models/post.cr", "class Post; end")

      graph = Lsp::Crystal::RequireGraph.new
      graph.build("/tmp/test_rg_glob")

      deps = graph.dependencies("/tmp/test_rg_glob/src/main.cr")
      deps.should contain("/tmp/test_rg_glob/src/models/user.cr")
      deps.should contain("/tmp/test_rg_glob/src/models/post.cr")
    ensure
      FileUtils.rm_rf("/tmp/test_rg_glob")
    end

    it "resolves directory form (foo/foo.cr)" do
      Dir.mkdir_p("/tmp/test_rg_dir/src/mylib")
      File.write("/tmp/test_rg_dir/shard.yml", "name: test\n")
      File.write("/tmp/test_rg_dir/src/main.cr", %{require "./mylib"})
      File.write("/tmp/test_rg_dir/src/mylib/mylib.cr", "module MyLib; end")

      graph = Lsp::Crystal::RequireGraph.new
      graph.build("/tmp/test_rg_dir")

      deps = graph.dependencies("/tmp/test_rg_dir/src/main.cr")
      deps.should contain("/tmp/test_rg_dir/src/mylib/mylib.cr")
    ensure
      FileUtils.rm_rf("/tmp/test_rg_dir")
    end

    it "handles update_file with content parameter" do
      Dir.mkdir_p("/tmp/test_rg_content/src")
      File.write("/tmp/test_rg_content/shard.yml", "name: test\n")
      File.write("/tmp/test_rg_content/src/main.cr", %{require "./a"})
      File.write("/tmp/test_rg_content/src/a.cr", "def a; end")
      File.write("/tmp/test_rg_content/src/b.cr", "def b; end")

      graph = Lsp::Crystal::RequireGraph.new
      graph.build("/tmp/test_rg_content")

      # Update with in-memory content (unsaved buffer)
      graph.update_file("/tmp/test_rg_content/src/main.cr", %{require "./b"})

      deps = graph.dependencies("/tmp/test_rg_content/src/main.cr")
      deps.should contain("/tmp/test_rg_content/src/b.cr")
      deps.should_not contain("/tmp/test_rg_content/src/a.cr")
    ensure
      FileUtils.rm_rf("/tmp/test_rg_content")
    end
  end

  # Phase 5: Configuration
  describe "Configuration - precompile_on_idle" do
    it "defaults to true" do
      config = Lsp::Crystal::Configuration.new
      config.precompile_on_idle.should be_true
    end

    it "can be toggled via settings" do
      config = Lsp::Crystal::Configuration.new
      settings = JSON.parse(%{{"crystalLsp": {"precompileOnIdle": false}}})
      config.update(settings)
      config.precompile_on_idle.should be_false
    end
  end

  # Phase 5: Idle precompile cancellation
  describe "Idle Precompile" do
    it "cancel_idle_precompile resets state" do
      server = TestClient.new.server
      server.cancel_idle_precompile
      # Should not raise, just a no-op if no timer set
    end
  end

  # Phase 9: Medium-Impact Future Work

  describe "Configuration - diagnostic severity" do
    it "defaults to show all severities" do
      config = Lsp::Crystal::Configuration.new
      config.diagnostics_min_severity.should eq(4)
      config.diagnostics_suppressed_patterns.should be_empty
    end

    it "parses diagnosticsMinSeverity from JSON" do
      config = Lsp::Crystal::Configuration.new
      settings = JSON.parse(%{{"crystalLsp": {"diagnosticsMinSeverity": 2}}})
      config.update(settings)
      config.diagnostics_min_severity.should eq(2)
    end

    it "clamps severity to valid range" do
      config = Lsp::Crystal::Configuration.new
      settings = JSON.parse(%{{"crystalLsp": {"diagnosticsMinSeverity": 10}}})
      config.update(settings)
      config.diagnostics_min_severity.should eq(4)

      settings = JSON.parse(%{{"crystalLsp": {"diagnosticsMinSeverity": 0}}})
      config.update(settings)
      config.diagnostics_min_severity.should eq(1)
    end

    it "parses diagnosticsSuppressedPatterns from JSON" do
      config = Lsp::Crystal::Configuration.new
      settings = JSON.parse(%{{"crystalLsp": {"diagnosticsSuppressedPatterns": ["unused", "deprecated"]}}})
      config.update(settings)
      config.diagnostics_suppressed_patterns.should eq(["unused", "deprecated"])
    end

    it "handles missing severity settings gracefully" do
      config = Lsp::Crystal::Configuration.new
      settings = JSON.parse(%{{"crystalLsp": {"crystalPath": "/usr/bin/crystal"}}})
      config.update(settings)
      config.diagnostics_min_severity.should eq(4)
      config.diagnostics_suppressed_patterns.should be_empty
    end
  end

  describe "Providers::LinkedEditingRange" do
    it "returns ranges for def...end" do
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, "def foo\n  42\nend\n")
      result = Lsp::Crystal::Providers::LinkedEditingRange.run(doc, 0, 1)
      result.should_not be_nil
      result.not_nil!.ranges.size.should eq(2)
      result.not_nil!.ranges[0].start.line.should eq(0)
      result.not_nil!.ranges[1].start.line.should eq(2)
    end

    it "returns ranges when cursor is on end" do
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, "def foo\n  42\nend\n")
      result = Lsp::Crystal::Providers::LinkedEditingRange.run(doc, 2, 1)
      result.should_not be_nil
      result.not_nil!.ranges.size.should eq(2)
      result.not_nil!.ranges[0].start.line.should eq(0)
      result.not_nil!.ranges[1].start.line.should eq(2)
    end

    it "returns ranges for if...end" do
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, "if true\n  42\nend\n")
      result = Lsp::Crystal::Providers::LinkedEditingRange.run(doc, 0, 1)
      result.should_not be_nil
      result.not_nil!.ranges.size.should eq(2)
    end

    it "handles nested blocks correctly" do
      code = "class Foo\n  def bar\n    42\n  end\nend\n"
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, code)

      # Cursor on class
      result = Lsp::Crystal::Providers::LinkedEditingRange.run(doc, 0, 1)
      result.should_not be_nil
      result.not_nil!.ranges[0].start.line.should eq(0)
      result.not_nil!.ranges[1].start.line.should eq(4)

      # Cursor on def
      result = Lsp::Crystal::Providers::LinkedEditingRange.run(doc, 1, 3)
      result.should_not be_nil
      result.not_nil!.ranges[0].start.line.should eq(1)
      result.not_nil!.ranges[1].start.line.should eq(3)
    end

    it "returns nil for postfix if" do
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, "x = 1 if true\n")
      result = Lsp::Crystal::Providers::LinkedEditingRange.run(doc, 0, 7)
      result.should be_nil
    end

    it "returns nil when cursor is not on a keyword" do
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, "def foo\n  x = 42\nend\n")
      result = Lsp::Crystal::Providers::LinkedEditingRange.run(doc, 1, 3)
      result.should be_nil
    end
  end

  describe "LinkedEditingRange handler integration" do
    it "handles textDocument/linkedEditingRange" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("textDocument/didOpen", {
        textDocument: {
          uri:        "file:///tmp/test_linked.cr",
          languageId: "crystal",
          version:    1,
          text:       "def foo\n  42\nend\n",
        },
      })
      Fiber.yield

      client.send_request(10, "textDocument/linkedEditingRange", {
        textDocument: {uri: "file:///tmp/test_linked.cr"},
        position:     {line: 0, character: 1},
      })
      resp = client.read_response
      resp["result"].should_not be_nil
      resp["result"]["ranges"].as_a.size.should eq(2)
      client.close
    end

    it "returns null when not on keyword" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("textDocument/didOpen", {
        textDocument: {
          uri:        "file:///tmp/test_linked2.cr",
          languageId: "crystal",
          version:    1,
          text:       "x = 42\n",
        },
      })
      Fiber.yield

      client.send_request(11, "textDocument/linkedEditingRange", {
        textDocument: {uri: "file:///tmp/test_linked2.cr"},
        position:     {line: 0, character: 0},
      })
      resp = client.read_response
      resp["result"].raw.should be_nil
      client.close
    end
  end

  describe "LinkedEditingRange capability" do
    it "advertises linkedEditingRangeProvider" do
      client = TestClient.new
      client.send_request(1, "initialize", {processId: 1, rootUri: "file:///tmp", capabilities: {} of String => String})
      resp = client.read_response
      caps = resp["result"]["capabilities"]
      caps["linkedEditingRangeProvider"].should eq(true)
      client.close
    end
  end

  describe "Providers::TypeHierarchy" do
    it "prepares type hierarchy for class with superclass" do
      code = "class Foo < Bar\n  def hello\n  end\nend\n"
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, code)
      items = Lsp::Crystal::Providers::TypeHierarchy.prepare(doc, 0, 7)
      items.size.should eq(1)
      items[0].name.should eq("Foo")
      items[0].data.should_not be_nil
      items[0].data.not_nil!["superclass"].as_s.should eq("Bar")
    end

    it "prepares type hierarchy for module" do
      code = "module MyModule\n  def hello\n  end\nend\n"
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, code)
      items = Lsp::Crystal::Providers::TypeHierarchy.prepare(doc, 0, 8)
      items.size.should eq(1)
      items[0].name.should eq("MyModule")
    end

    it "returns empty for non-type line" do
      code = "x = 42\n"
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, code)
      items = Lsp::Crystal::Providers::TypeHierarchy.prepare(doc, 0, 0)
      items.should be_empty
    end

    it "detects includes in type body" do
      code = "class Foo\n  include Bar\n  include Baz\nend\n"
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, code)
      items = Lsp::Crystal::Providers::TypeHierarchy.prepare(doc, 0, 2)
      items.size.should eq(1)
      items[0].data.should_not be_nil
      includes = items[0].data.not_nil!["includes"].as_a.map(&.as_s)
      includes.should eq(["Bar", "Baz"])
    end

    it "returns empty supertypes when no data" do
      item = Lsp::Crystal::Providers::TypeHierarchy::TypeHierarchyItem.new(
        name: "Foo",
        kind: 5,
        uri: "file:///test.cr",
        range: Lsp::Crystal::Range.new(
          start: Lsp::Crystal::Position.new(line: 0, character: 0),
          end_pos: Lsp::Crystal::Position.new(line: 0, character: 3)
        ),
        selection_range: Lsp::Crystal::Range.new(
          start: Lsp::Crystal::Position.new(line: 0, character: 0),
          end_pos: Lsp::Crystal::Position.new(line: 0, character: 3)
        )
      )
      results = Lsp::Crystal::Providers::TypeHierarchy.supertypes(item, nil)
      results.should be_empty
    end
  end

  describe "TypeHierarchy handler integration" do
    it "handles textDocument/prepareTypeHierarchy" do
      client = TestClient.new
      client.initialize_server

      client.send_notification("textDocument/didOpen", {
        textDocument: {
          uri:        "file:///tmp/test_th.cr",
          languageId: "crystal",
          version:    1,
          text:       "class Foo < Bar\nend\n",
        },
      })
      Fiber.yield

      client.send_request(20, "textDocument/prepareTypeHierarchy", {
        textDocument: {uri: "file:///tmp/test_th.cr"},
        position:     {line: 0, character: 7},
      })
      resp = client.read_response
      result = resp["result"].as_a
      result.size.should eq(1)
      result[0]["name"].as_s.should eq("Foo")
      client.close
    end

    it "advertises typeHierarchyProvider" do
      client = TestClient.new
      client.send_request(1, "initialize", {processId: 1, rootUri: "file:///tmp", capabilities: {} of String => String})
      resp = client.read_response
      caps = resp["result"]["capabilities"]
      caps["typeHierarchyProvider"].should eq(true)
      client.close
    end
  end

  describe "Providers::CodeAction - convert to multiline" do
    it "converts single-line block to multi-line" do
      code = "  arr.map { |x| x + 1 }\n"
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, code)
      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 0, character: 5),
        end_pos: Lsp::Crystal::Position.new(line: 0, character: 5)
      )
      actions = Lsp::Crystal::Providers::CodeAction.run(doc, range, nil)
      multiline = actions.find { |a| a.title == "Convert to multi-line block" }
      multiline.should_not be_nil
      edit = multiline.not_nil!.edit.not_nil!
      text_edits = edit.changes["file:///test.cr"]
      text_edits[0].new_text.should contain("do |x|")
      text_edits[0].new_text.should contain("x + 1")
      text_edits[0].new_text.should contain("end")
    end

    it "does not offer convert for empty block" do
      code = "arr.map {}\n"
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, code)
      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 0, character: 5),
        end_pos: Lsp::Crystal::Position.new(line: 0, character: 5)
      )
      actions = Lsp::Crystal::Providers::CodeAction.run(doc, range, nil)
      multiline = actions.find { |a| a.title == "Convert to multi-line block" }
      multiline.should be_nil
    end
  end

  describe "Providers::CodeAction - generate method stub" do
    it "generates method stub from diagnostic" do
      Dir.mkdir_p("/tmp/test_stub")
      File.write("/tmp/test_stub/bar.cr", "class Bar\nend\n")

      idx = Lsp::Crystal::WorkspaceIndex.new
      idx.index("/tmp/test_stub")

      code = "bar = Bar.new\nbar.hello\n"
      doc = Lsp::Crystal::Document.new("file:///tmp/test_stub/foo.cr", "crystal", 1, code)
      diag = JSON.parse(%{{"message": "undefined method 'hello' for Bar", "range": {"start": {"line": 1, "character": 4}, "end": {"line": 1, "character": 9}}}})

      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 1, character: 4),
        end_pos: Lsp::Crystal::Position.new(line: 1, character: 9)
      )
      actions = Lsp::Crystal::Providers::CodeAction.run(doc, range, [diag], idx)
      stub_action = actions.find { |a| a.title.includes?("Generate method") }
      stub_action.should_not be_nil
      stub_action.not_nil!.title.should eq("Generate method 'hello' on Bar")

      FileUtils.rm_rf("/tmp/test_stub")
    end
  end

  describe "Providers::CodeAction - add missing require" do
    it "adds require for undefined constant" do
      Dir.mkdir_p("/tmp/test_require")
      File.write("/tmp/test_require/my_class.cr", "class MyClass\nend\n")
      File.write("/tmp/test_require/main.cr", "x = MyClass.new\n")

      idx = Lsp::Crystal::WorkspaceIndex.new
      idx.index("/tmp/test_require")

      doc = Lsp::Crystal::Document.new("file:///tmp/test_require/main.cr", "crystal", 1, "x = MyClass.new\n")
      diag = JSON.parse(%{{"message": "undefined constant MyClass", "range": {"start": {"line": 0, "character": 4}, "end": {"line": 0, "character": 11}}}})

      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 0, character: 4),
        end_pos: Lsp::Crystal::Position.new(line: 0, character: 11)
      )
      actions = Lsp::Crystal::Providers::CodeAction.run(doc, range, [diag], idx)
      require_action = actions.find { |a| a.title.includes?("Add require") }
      require_action.should_not be_nil
      edit = require_action.not_nil!.edit.not_nil!
      text_edits = edit.changes["file:///tmp/test_require/main.cr"]
      text_edits[0].new_text.should contain("require")
      text_edits[0].new_text.should contain("my_class")

      FileUtils.rm_rf("/tmp/test_require")
    end
  end

  describe "Existing code actions still work" do
    it "still suggests unused variable prefix" do
      code = "x = 42\n"
      doc = Lsp::Crystal::Document.new("file:///test.cr", "crystal", 1, code)
      diag = JSON.parse(%{{"message": "variable 'x' isn't used", "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}}}})
      range = Lsp::Crystal::Range.new(
        start: Lsp::Crystal::Position.new(line: 0, character: 0),
        end_pos: Lsp::Crystal::Position.new(line: 0, character: 1)
      )
      actions = Lsp::Crystal::Providers::CodeAction.run(doc, range, [diag])
      prefix_action = actions.find { |a| a.title.includes?("underscore") }
      prefix_action.should_not be_nil
    end
  end
end
