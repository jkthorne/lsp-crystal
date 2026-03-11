module Lsp::Crystal::JSONRPC
  alias RequestId = Int64 | String

  enum ErrorCode
    ParseError           = -32700
    InvalidRequest       = -32600
    MethodNotFound       = -32601
    InvalidParams        = -32602
    InternalError        = -32603
    ServerNotInitialized = -32002
    RequestCancelled     = -32800
  end
end
