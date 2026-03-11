require "log"

module Lsp::Crystal
  Log = ::Log.for("lsp-crystal")

  def self.setup_logging(level : ::Log::Severity = :info)
    ::Log.setup(level, ::Log::IOBackend.new(io: STDERR))
  end
end
