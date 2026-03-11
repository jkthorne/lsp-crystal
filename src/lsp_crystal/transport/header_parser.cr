module Lsp::Crystal::Transport
  class HeaderParser
    SEPARATOR = "\r\n"

    def self.read_headers(io : IO) : Hash(String, String)
      headers = Hash(String, String).new
      loop do
        line = io.read_line(SEPARATOR)
        line = line.rstrip(SEPARATOR)
        break if line.empty?
        if line =~ /^(.+?):\s*(.+)$/
          headers[$1] = $2
        end
      end
      headers
    end

    def self.read_content_length(io : IO) : Int32
      headers = read_headers(io)
      length = headers["Content-Length"]?
      raise "Missing Content-Length header" unless length
      length.to_i
    end
  end
end
