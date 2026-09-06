# src/SystemConfig.jl
#
# Singleton-style config module. Reads `config/quantitative_lib.toml` at
# module load time (or falls back to sensible defaults if the file is
# missing). All magic-number constants are defined here; downstream modules
# call the accessor functions rather than hard-coding literals.
#
# Uses a minimal built-in TOML parser — no external dependencies required.

module SystemConfig

using Dates

# ─────────────────────────────────────────────
# Resolve config-file path
# ─────────────────────────────────────────────

"""
    config_path() -> String

Return the absolute path to `config/quantitative_lib.toml`, starting from
the directory that contains this module's source file.
"""
function config_path()::String
    # `pathof(SystemConfig)` returns the parent module's file path when the
    # module is included rather than loaded from a file.  The path points to
    # `src/QuantitativeLib.jl`, so dirname gives `src/`.  We go up one level
    # to the project root, then into `config/`.
    base = dirname(pathof(SystemConfig))
    return abspath(joinpath(base, "..", "config", "quantitative_lib.toml"))
end

# ─────────────────────────────────────────────
# Minimal TOML parser (handles our config format)
# ─────────────────────────────────────────────

"""
Parse a small TOML config file into a nested `Dict{String, Any}`.

Supports:
- `[section]` headers
- `key = value` entries (strings, ints, floats, bools)
- `#` line comments
- Blank lines
"""
function _parse_toml(path::String)::Dict{String, Any}
    cfg = Dict{String, Any}()
    current_section = ""
    for line in eachline(path)
        s = strip(line)
        s == "" && continue
        s[1] == '#' && continue
        if startswith(s, '[') && endswith(s, ']')
            current_section = strip(s[2:end-1])
            continue
        end
        idx = findfirst(==('='), s)
        idx === nothing && continue
        key = strip(s[1:idx-1])
        val_str = strip(s[idx+1:end])
        # Remove trailing comments
        cidx = findfirst(==('#'), val_str)
        cidx !== nothing && (val_str = strip(val_str[1:cidx-1]))
        # Inline value parsing to avoid compile-order issues during const init.
        val = if startswith(val_str, '"') && endswith(val_str, '"')
            val_str[2:end-1]
        elseif val_str == "true"
            true
        elseif val_str == "false"
            false
        else
            i = tryparse(Int, val_str)
            if i !== nothing
                i
            else
                f = tryparse(Float64, val_str)
                f !== nothing ? f : val_str
            end
        end
        if current_section == ""
            cfg[key] = val
        else
            section = get(cfg, current_section, Dict{String, Any}())
            if !(section isa Dict)
                section = Dict{String, Any}()
                cfg[current_section] = section
            end
            section[key] = val
        end
    end
    return cfg
end



function _load_config()::Dict{String, Any}
    path = config_path()
    try
        return _parse_toml(path)
    catch e
        @warn "Could not read config at $path: $e — using built-in defaults"
        return Dict{String, Any}()
    end
end

# ─────────────────────────────────────────────
# Read the config once at load time
# ─────────────────────────────────────────────

const _CFG_PATH = config_path()
const _CFG = _load_config()

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────

"""
    _get(cfg::Dict, section::String, key::String, default)

Return the value of `cfg[section][key]` as `T`, falling back to `default`.
"""
function _get(section::String, key::String, default)
    d = get(_CFG, section, nothing)
    d isa Dict || return default
    v = get(d, key, nothing)
    if v isa Number && default isa Int
        return Int(v)
    end
    return v isa typeof(default) ? v : default
end

# ─────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────

"""
    day_count(name::String) -> Float64

Return the divisor for the named day-count convention.

Supported names (see `config/quantitative_lib.toml`):
- `"ACT_365"`  → 365.0
- `"ACT_360"`  → 360.0
- `"ACT_36525"` → 365.25
- `"DE300_D"`  → 360.0  (30/360)

The name mapping is flexible: callers may pass the convention string used
by the calling code (e.g. `"ACT/360"` from `yearfrac`) and it will be
translated to the config key `"ACT_360"`.
"""
function day_count(name::String)::Float64
    # Normalise: replace `/` with `_` so `"ACT/360"` → `"ACT_360"`.
    key = replace(name, '/' => '_')
    dc = _get("day_counts", key, nothing)
    if dc === nothing
        # Fall back to a small lookup table for the most common conventions.
        mapping = Dict{String, Float64}(
            "ACT_365"   => 365.0,
            "ACT_360"   => 360.0,
            "ACT_36525" => 365.25,
            "DE300_D"   => 360.0,
        )
        return get(mapping, key, 365.0)
    end
    return Float64(dc)
end

"""
    default_digits() -> Int

Return the global default number of significant digits for `round()` calls.
"""
function default_digits()::Int
    return _get("defaults", "default_digits", 8)
end

"""
    trading_days_year() -> Int

Return the number of trading days assumed per year.
"""
function trading_days_year()::Int
    return _get("defaults", "trading_days_year", 252)
end

"""
    default_day_count() -> String

Return the name of the default day-count convention key (e.g. `"ACT_365"`).
"""
function default_day_count()::String
    return _get("defaults", "default_day_count", "ACT_365")
end

"""
    curve_day_count() -> String

Return the default day-count name for new `Curve` objects (from
`curve_defaults`).
"""
function curve_day_count()::String
    return _get("curve_defaults", "day_count", "ACT_365")
end

"""
    curve_currency() -> String
"""
function curve_currency()::String
    return _get("curve_defaults", "currency", "USD")
end

"""
    curve_name() -> String
"""
function curve_name()::String
    return _get("curve_defaults", "name", "GenericCurve")
end

export day_count, default_digits, trading_days_year, default_day_count, curve_day_count, curve_currency, curve_name

end # module SystemConfig
