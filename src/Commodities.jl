module Commodities

using Dates
using TimeZones
using DataFrames
using HTTP
using JSON3
using Arrow

using ..Config

const YAHOO_HEADERS = [
    "User-Agent" => "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 SEMforecast/0.1",
    "Accept" => "application/json",
]

"""
    fetch_yahoo_daily(symbol, start_date, end_date) -> DataFrame

Returns a DataFrame with columns `date::Date`, `close::Float64`. Uses Yahoo
Finance's chart API directly (no third-party wrapper) for stability.
"""
function fetch_yahoo_daily(symbol::AbstractString, start_date::Date, end_date::Date)
    period1 = Int64(datetime2unix(DateTime(start_date)))
    period2 = Int64(datetime2unix(DateTime(end_date + Day(1))))
    url = string(Config.YAHOO_CHART_URL, "/", symbol,
                 "?period1=", period1, "&period2=", period2,
                 "&interval=1d&events=history&includeAdjustedClose=true")
    resp = HTTP.get(url, YAHOO_HEADERS; readtimeout = 30, retry = false)
    j = JSON3.read(resp.body)
    chart = j.chart
    if !isnothing(chart.error) && chart.error !== nothing
        error("Yahoo returned error for $(symbol): $(chart.error)")
    end
    isempty(chart.result) && error("Yahoo returned no data for $(symbol)")
    r = chart.result[1]
    ts = r.timestamp
    closes = r.indicators.quote[1].close
    dates = Date.(unix2datetime.(Int.(ts)))
    # JSON3 parses JSON null as `nothing`; convert to `missing` before
    # building the DataFrame so dropmissing works.
    closes_clean = Union{Missing,Float64}[c === nothing ? missing : Float64(c)
                                          for c in closes]
    df = DataFrame(date = dates, close = closes_clean)
    dropmissing!(df, :close)
    sort!(df, :date)
    return df
end

"""
    fetch_with_fallback(primary, fallback, start_date, end_date)

Tries `primary` first; if it raises, retries with `fallback` and renames so the
returned DataFrame still describes the same series for downstream code.
"""
function fetch_with_fallback(primary, fallback, start_date, end_date)
    try
        return fetch_yahoo_daily(primary, start_date, end_date)
    catch e
        @warn "Primary symbol $primary failed ($e); falling back to $fallback"
        return fetch_yahoo_daily(fallback, start_date, end_date)
    end
end

function fetch_ttf(start_date::Date, end_date::Date)
    df = fetch_yahoo_daily(Config.TTF_SYMBOL, start_date, end_date)
    rename!(df, :close => :ttf_gas)
    return df
end

function fetch_eua(start_date::Date, end_date::Date)
    df = fetch_with_fallback(Config.EUA_SYMBOL, Config.EUA_FALLBACK_SYMBOL,
                             start_date, end_date)
    rename!(df, :close => :eua_carbon)
    return df
end

"""
    daily_commodities(start_date, end_date) -> DataFrame

Returns a DataFrame `date`, `ttf_gas`, `eua_carbon` covering the date range,
forward-filled to give a value on every calendar date (commodities don't trade
weekends/holidays).
"""
function daily_commodities(start_date::Date, end_date::Date)
    ttf = fetch_ttf(start_date, end_date)
    eua = fetch_eua(start_date, end_date)

    cal = DataFrame(date = collect(start_date:Day(1):end_date))
    merged = leftjoin(cal, ttf, on = :date)
    merged = leftjoin(merged, eua, on = :date)
    sort!(merged, :date)

    # Forward-fill missing days (markets closed).
    for col in (:ttf_gas, :eua_carbon)
        last_val = missing
        for i in 1:nrow(merged)
            v = merged[i, col]
            if ismissing(v)
                merged[i, col] = last_val
            else
                last_val = v
            end
        end
    end
    return merged
end

"""
    synthetic_commodities(start_date, end_date)

Returns a plausible-looking commodities DataFrame for offline smoke tests.
"""
function synthetic_commodities(start_date::Date, end_date::Date)
    dates = collect(start_date:Day(1):end_date)
    n = length(dates)
    # Random-walk-ish series with reasonable means.
    rng_state = 42
    ttf = Vector{Float64}(undef, n)
    eua = Vector{Float64}(undef, n)
    ttf[1] = 35.0
    eua[1] = 75.0
    for i in 2:n
        rng_state = (1103515245 * rng_state + 12345) & 0x7fffffff
        step_g = (Float64(rng_state) / 2^31 - 0.5) * 1.5
        rng_state = (1103515245 * rng_state + 12345) & 0x7fffffff
        step_c = (Float64(rng_state) / 2^31 - 0.5) * 1.0
        ttf[i] = max(5.0, ttf[i-1] + step_g)
        eua[i] = max(20.0, eua[i-1] + step_c)
    end
    return DataFrame(date = dates, ttf_gas = ttf, eua_carbon = eua)
end

function cache_path(name::AbstractString)
    Config.ensure_dirs()
    return joinpath(Config.COMMODITIES_DIR, "$name.arrow")
end

function save(df::DataFrame, name::AbstractString)
    Arrow.write(cache_path(name), df)
end

function load(name::AbstractString)
    p = cache_path(name)
    isfile(p) || error("Commodity cache missing: $p")
    return DataFrame(Arrow.Table(p))
end

end # module
