module Lsp::Crystal
  class RequestTracker
    struct TrackedRequest
      property method : String
      property token : CancellationToken
      property fiber : Fiber

      def initialize(@method, @token, @fiber)
      end
    end

    def initialize
      @requests = Hash(JSONRPC::RequestId, TrackedRequest).new
      @mutex = Mutex.new
    end

    def track(id : JSONRPC::RequestId, method : String, token : CancellationToken, fiber : Fiber) : Nil
      @mutex.synchronize do
        @requests[id] = TrackedRequest.new(method, token, fiber)
      end
    end

    def cancel(id : JSONRPC::RequestId) : Bool
      @mutex.synchronize do
        if tracked = @requests[id]?
          tracked.token.cancel
          @requests.delete(id)
          true
        else
          false
        end
      end
    end

    def complete(id : JSONRPC::RequestId) : Nil
      @mutex.synchronize do
        @requests.delete(id)
      end
    end

    def cancel_all : Nil
      @mutex.synchronize do
        @requests.each_value do |tracked|
          tracked.token.cancel
        end
        @requests.clear
      end
    end

    def size : Int32
      @mutex.synchronize { @requests.size }
    end

    def has?(id : JSONRPC::RequestId) : Bool
      @mutex.synchronize { @requests.has_key?(id) }
    end
  end
end
