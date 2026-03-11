require "json"
require "./types"

module Lsp::Crystal::JSONRPC
  struct Message
    include JSON::Serializable

    property jsonrpc : String = "2.0"
    property method : String?
    property id : (Int64 | String)?
    property params : JSON::Any?
    property result : JSON::Any?
    property error : ResponseError?
  end

  struct ResponseError
    include JSON::Serializable

    property code : Int32
    property message : String
    property data : JSON::Any?

    def initialize(@code, @message, @data = nil)
    end
  end

  module Response
    def self.success(id : RequestId, result) : String
      JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "id", id
          json.field "result" do
            result.to_json(json)
          end
        end
      end
    end

    def self.success_null(id : RequestId) : String
      JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "id", id
          json.field "result", nil
        end
      end
    end

    def self.error(id : RequestId?, code : ErrorCode, message : String) : String
      JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "id", id
          json.field "error" do
            json.object do
              json.field "code", code.value
              json.field "message", message
            end
          end
        end
      end
    end

    def self.notification(method : String, params) : String
      JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field "method", method
          json.field "params" do
            params.to_json(json)
          end
        end
      end
    end
  end
end
