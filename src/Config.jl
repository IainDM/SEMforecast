module Config

using Dates
using TimeZones

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))

const DATA_DIR = joinpath(REPO_ROOT, "data")
const RAW_DIR = joinpath(DATA_DIR, "raw")
const COMMODITIES_DIR = joinpath(DATA_DIR, "commodities")
const REPORTS_DIR = joinpath(REPO_ROOT, "reports")
const MODELS_DIR = joinpath(REPO_ROOT, "models_cache")

# SEM unified day-ahead bidding zone.
const SEM_EIC = "10Y1001A1001A59C"
const SEM_TZ = tz"Europe/Dublin"

# ENTSO-E REST endpoint.
const ENTSOE_BASE_URL = "https://web-api.tp.entsoe.eu/api"

# Yahoo Finance chart endpoint (used for TTF gas and EUA carbon proxies).
const YAHOO_CHART_URL = "https://query1.finance.yahoo.com/v8/finance/chart"
const TTF_SYMBOL = "TTF=F"
const EUA_SYMBOL = "CO2.L"
const EUA_FALLBACK_SYMBOL = "KRBN"

# Model hyperparameters (EvoTrees, MAE loss).
const MODEL_HP = (
    loss = :mae,
    nrounds = 2000,
    eta = 0.05,
    max_depth = 7,
    min_weight = 20.0,
    rowsample = 0.8,
    colsample = 0.8,
    early_stopping_rounds = 100,
    L2 = 1.0,
)

# CCGT marginal-cost proxy coefficients (heat rate, emissions intensity).
const CCGT_HEAT_RATE = 0.49
const CCGT_EMISSIONS = 0.37  # tCO2/MWh

function ensure_dirs()
    for d in (RAW_DIR, COMMODITIES_DIR, REPORTS_DIR, MODELS_DIR)
        isdir(d) || mkpath(d)
    end
end

"""
    load_dotenv(path = joinpath(REPO_ROOT, ".env"))

Minimal .env loader: parses `KEY=VALUE` lines and sets `ENV[KEY]` unless the
variable is already set in the process environment.
"""
function load_dotenv(path::AbstractString = joinpath(REPO_ROOT, ".env"))
    isfile(path) || return
    for line in eachline(path)
        s = strip(line)
        (isempty(s) || startswith(s, "#")) && continue
        eq = findfirst('=', s)
        eq === nothing && continue
        key = strip(s[1:eq-1])
        val = strip(s[eq+1:end])
        # Strip surrounding quotes if present.
        if length(val) >= 2 && ((val[1] == '"' && val[end] == '"') ||
                                (val[1] == '\'' && val[end] == '\''))
            val = val[2:end-1]
        end
        haskey(ENV, key) || (ENV[key] = val)
    end
end

function entsoe_api_key()
    key = get(ENV, "ENTSOE_API_KEY", "")
    isempty(key) && error("ENTSOE_API_KEY not set. Add it to .env or your shell environment.")
    return key
end

end # module
