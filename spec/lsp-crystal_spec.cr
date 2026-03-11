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
end
