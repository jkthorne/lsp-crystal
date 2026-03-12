require "log"
require "json"

module Lsp::Crystal
  Log = ::Log.for("lsp-crystal")

  class JsonLogBackend < ::Log::Backend
    def initialize(@io : IO = STDERR)
      super(::Log::DispatchMode::Sync)
    end

    def write(entry : ::Log::Entry) : Nil
      data = String.build do |str|
        str << %({"timestamp":)
        str << entry.timestamp.to_unix_ms
        str << %(,"level":)
        entry.severity.to_s.downcase.to_json(str)
        str << %(,"source":)
        entry.source.to_json(str)
        str << %(,"message":)
        entry.message.to_json(str)
        if context = entry.context
          context.each do |key, value|
            str << ","
            key.to_json(str)
            str << ":"
            value.to_s.to_json(str)
          end
        end
        if ex = entry.exception
          str << %(,"exception":)
          ex.message.to_json(str)
          str << %(,"backtrace":)
          (ex.backtrace? || [] of String).to_json(str)
        end
        str << "}"
      end
      @io.puts(data)
      @io.flush
    end
  end

  def self.setup_logging(level : ::Log::Severity = :info, json : Bool = true)
    backend = if json
                JsonLogBackend.new(io: STDERR)
              else
                ::Log::IOBackend.new(io: STDERR)
              end
    ::Log.setup(level, backend)
  end
end
