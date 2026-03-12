module Lsp::Crystal
  class Configuration
    property crystal_path : String = "crystal"
    property diagnostics_delay : Int32 = 500
    property format_on_save : Bool = false
    property inlay_hints_enabled : Bool = true
    property code_lens_enabled : Bool = true
    property semantic_tokens_enabled : Bool = true
    property precompile_on_idle : Bool = true
    property diagnostics_min_severity : Int32 = 4
    property diagnostics_suppressed_patterns : Array(String) = [] of String

    def initialize
    end

    def update(settings : JSON::Any) : Nil
      if crystal_lsp = settings["crystalLsp"]? || settings["crystal-lsp"]?
        if path = crystal_lsp["crystalPath"]?.try(&.as_s?)
          @crystal_path = path
        end
        if delay = crystal_lsp["diagnosticsDelay"]?.try(&.as_i?)
          @diagnostics_delay = delay
        end
        if fos = crystal_lsp["formatOnSave"]?.try(&.as_bool?)
          @format_on_save = fos
        end
        if ih = crystal_lsp["inlayHints"]?.try(&.as_bool?)
          @inlay_hints_enabled = ih
        end
        if cl = crystal_lsp["codeLens"]?.try(&.as_bool?)
          @code_lens_enabled = cl
        end
        if st = crystal_lsp["semanticTokens"]?.try(&.as_bool?)
          @semantic_tokens_enabled = st
        end
        if crystal_lsp["precompileOnIdle"]?
          poi = crystal_lsp["precompileOnIdle"].as_bool?
          @precompile_on_idle = poi unless poi.nil?
        end
        if sev = crystal_lsp["diagnosticsMinSeverity"]?.try(&.as_i?)
          @diagnostics_min_severity = sev.clamp(1, 4)
        end
        if patterns = crystal_lsp["diagnosticsSuppressedPatterns"]?.try(&.as_a?)
          @diagnostics_suppressed_patterns = patterns.compact_map(&.as_s?)
        end
      end
    end

    def diagnostics_debounce : Time::Span
      @diagnostics_delay.milliseconds
    end
  end
end
