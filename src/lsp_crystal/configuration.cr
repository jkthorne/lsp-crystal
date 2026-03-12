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
    property tool_cache_ttl : Int32 = 60
    property tool_cache_max_entries : Int32 = 500
    property macro_expand_enabled : Bool = true
    property macro_expand_timeout : Int32 = 15
    property parallel_tool_calls : Bool = true

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
        if ttl = crystal_lsp["toolCacheTtl"]?.try(&.as_i?)
          @tool_cache_ttl = ttl.clamp(0, 600)
        end
        if max = crystal_lsp["toolCacheMaxEntries"]?.try(&.as_i?)
          @tool_cache_max_entries = max.clamp(0, 10000)
        end
        if crystal_lsp["macroExpandEnabled"]?
          me = crystal_lsp["macroExpandEnabled"].as_bool?
          @macro_expand_enabled = me unless me.nil?
        end
        if mt = crystal_lsp["macroExpandTimeout"]?.try(&.as_i?)
          @macro_expand_timeout = mt.clamp(1, 60)
        end
        if crystal_lsp["parallelToolCalls"]?
          pt = crystal_lsp["parallelToolCalls"].as_bool?
          @parallel_tool_calls = pt unless pt.nil?
        end
      end
    end

    def diagnostics_debounce : Time::Span
      @diagnostics_delay.milliseconds
    end
  end
end
