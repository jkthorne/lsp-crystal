require "./header_parser"

module Lsp::Crystal::Transport
  class Stdio
    MAX_MESSAGE_SIZE = 10 * 1024 * 1024 # 10 MB

    def initialize(@input : IO = STDIN, @output : IO = STDOUT)
      @output_mutex = Mutex.new
    end

    def read_message : String
      length = HeaderParser.read_content_length(@input)
      if length <= 0 || length > MAX_MESSAGE_SIZE
        raise "Invalid Content-Length: #{length} (max #{MAX_MESSAGE_SIZE})"
      end
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
