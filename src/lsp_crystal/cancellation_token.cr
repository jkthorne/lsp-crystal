module Lsp::Crystal
  class CancellationToken
    def initialize
      @cancelled = Atomic(Int32).new(0)
    end

    def cancel : Nil
      @cancelled.set(1)
    end

    def cancelled? : Bool
      @cancelled.get == 1
    end
  end
end
