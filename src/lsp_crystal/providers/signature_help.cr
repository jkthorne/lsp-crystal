module Lsp::Crystal::Providers
  module SignatureHelp
    struct ParameterInfo
      include JSON::Serializable

      property label : String

      def initialize(@label)
      end
    end

    struct SignatureInfo
      include JSON::Serializable

      property label : String
      property documentation : String?
      property parameters : Array(ParameterInfo)

      @[JSON::Field(key: "activeParameter")]
      property active_parameter : Int32?

      def initialize(@label, @parameters, @documentation = nil, @active_parameter = nil)
      end
    end

    struct SignatureHelpResult
      include JSON::Serializable

      property signatures : Array(SignatureInfo)

      @[JSON::Field(key: "activeSignature")]
      property active_signature : Int32

      @[JSON::Field(key: "activeParameter")]
      property active_parameter : Int32

      def initialize(@signatures, @active_signature = 0, @active_parameter = 0)
      end
    end

    DEF_REGEX = /^\s*def\s+(?:self\.)?(\w+[?!=]?)\s*(?:\(([^)]*)\))?/

    def self.run(document : Document, line : Int32, character : Int32) : SignatureHelpResult?
      current_line = document.line_at(line) || return nil
      prefix = character <= current_line.size ? current_line[0...character] : current_line

      # Find the method name and count active parameter
      method_name, active_param = find_call_context(prefix)
      return nil unless method_name

      # Scan document for matching def signatures
      signatures = find_signatures(document, method_name)
      return nil if signatures.empty?

      SignatureHelpResult.new(
        signatures: signatures,
        active_signature: 0,
        active_parameter: active_param
      )
    end

    private def self.find_call_context(prefix : String) : {String?, Int32}
      # Walk backwards to find unmatched opening paren
      depth = 0
      i = prefix.size - 1
      while i >= 0
        case prefix[i]
        when ')'
          depth += 1
        when '('
          if depth == 0
            # Found the opening paren — extract method name before it
            j = i - 1
            # Skip whitespace
            while j >= 0 && prefix[j].whitespace?
              j -= 1
            end
            # Extract identifier
            k = j
            while k >= 0 && (prefix[k].alphanumeric? || prefix[k] == '_' || prefix[k] == '?' || prefix[k] == '!')
              k -= 1
            end
            name = prefix[(k + 1)..(j)]
            return {nil, 0} if name.empty?

            # Count commas after the paren to determine active parameter
            after_paren = prefix[(i + 1)..]
            active = count_params(after_paren)
            return {name, active}
          else
            depth -= 1
          end
        end
        i -= 1
      end

      {nil, 0}
    end

    private def self.count_params(text : String) : Int32
      count = 0
      depth = 0
      text.each_char do |ch|
        case ch
        when '(', '[', '{'
          depth += 1
        when ')', ']', '}'
          depth -= 1
        when ','
          count += 1 if depth == 0
        end
      end
      count
    end

    private def self.find_signatures(document : Document, method_name : String) : Array(SignatureInfo)
      signatures = [] of SignatureInfo

      document.content.each_line do |line|
        if match = DEF_REGEX.match(line)
          name = match[1]
          next unless name == method_name

          params_str = match[2]?
          params = if params_str && !params_str.strip.empty?
                     parse_parameters(params_str)
                   else
                     [] of ParameterInfo
                   end

          label = "def #{name}"
          label += "(#{params_str.strip})" if params_str
          signatures << SignatureInfo.new(label: label, parameters: params)
        end
      end

      signatures
    end

    private def self.parse_parameters(params_str : String) : Array(ParameterInfo)
      params_str.split(",").map do |param|
        ParameterInfo.new(label: param.strip)
      end
    end
  end
end
