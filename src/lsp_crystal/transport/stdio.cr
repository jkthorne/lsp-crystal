require "./header_parser"

module Lsp::Crystal::Transport
  class Stdio
    def initialize(@input : IO = STDIN, @output : IO = STDOUT)
      @output_mutex = Mutex.new
    end

    def read_message : String
      length = HeaderParser.read_content_length(@input)
      body = Bytes.new(length)
      @input.read_fully(body)
      String.new(body)
    end

    def write_message(json : String) : Nil
      @output_mutex.synchronize do
        @output << "Content-Length: #{json.bytesize}\r\n\r\n"
        @output << json
        @output.flush
      end
    end
  end
end
