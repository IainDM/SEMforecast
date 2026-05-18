module Gb

using Dates
using TimeZones
using DataFrames
using Statistics
using Random
using HTTP
using JSON3
using Arrow

using ..Config

const BMRS_BASE = "https://data.elexon.co.uk/bmrs/api/v1"
const BMRS_HEADERS = ["Accept" => "application/json",
                      "User-Agent" => "SEMforecast/0.1"]

# ---------------------------------------------------------------------------
# Real BMRS fetchers — free, no auth, JSON
# ---------------------------------------------------------------------------

"""
    fetch_gb_da_prices(start_date, end_date) -> DataFrame

GB day-ahead market index price (MID dataset). BMRS publishes prices for two
indices (APX-MIDP and N2EX-MIDP); we keep APX (the larger, more liquid book)
and aggregate half-hourly settlement periods to hourly mean.

Columns: `ts_utc::DateTime`, `gb_price::Float64` (£/MWh).
"""
function fetch_gb_da_prices(start_date::Date, end_date::Date;
                            provider::AbstractString = "APXMIDP")
    rows = NamedTuple[]
    cursor = start_date
    # BMRS MID supports broader windows than WINDFOR but isn't documented;
    # chunk weekly to stay well inside any limit and let single-chunk
    # failures degrade gracefully.
    while cursor < end_date
        nxt = min(cursor + Day(7), end_date)
        url = "$(BMRS_BASE)/datasets/MID?from=$(cursor)&to=$(nxt)&format=json"
        try
            resp = HTTP.get(url, BMRS_HEADERS; readtimeout = 30,
                            retry = true, retries = 2, status_exception = false)
            if resp.status == 200
                j = JSON3.read(resp.body)
                for r in j.data
                    String(r.dataProvider) == provider || continue
                    push!(rows, (
                        ts_utc = DateTime(String(r.startTime)[1:19]),
                        price  = Float64(r.price),
                    ))
                end
            elseif resp.status == 400
                @debug "BMRS MID 400 for $cursor..$nxt; skipping"
            else
                @warn "BMRS MID $(resp.status) for $cursor..$nxt"
            end
        catch e
            @warn "MID fetch failed for $cursor..$nxt: $e"
        end
        cursor = nxt
        sleep(0.2)
    end
    df = DataFrame(rows)
    isempty(df) && return DataFrame(ts_utc = DateTime[], gb_price = Float64[])
    df.hour_ts = floor.(df.ts_utc, Hour)
    out = combine(groupby(df, :hour_ts), :price => mean => :gb_price)
    rename!(out, :hour_ts => :ts_utc)
    sort!(out, :ts_utc)
    return out
end

"""
    fetch_gb_wind_forecast(start_date, end_date) -> DataFrame

BMRS `WINDFOR` dataset: NESO's GB wind generation forecast. Hourly resolution.

Columns: `ts_utc`, `gb_wind_fcst::Float64` (MW).
"""
function fetch_gb_wind_forecast(start_date::Date, end_date::Date)
    rows = NamedTuple[]
    cursor = start_date
    # WINDFOR enforces a 7-day window per request — chunk accordingly.
    while cursor < end_date
        nxt = min(cursor + Day(7), end_date)
        url = "$(BMRS_BASE)/datasets/WINDFOR?from=$(cursor)&to=$(nxt)&format=json"
        try
            resp = HTTP.get(url, BMRS_HEADERS; readtimeout = 30,
                            retry = true, retries = 2, status_exception = false)
            if resp.status == 200
                j = JSON3.read(resp.body)
                for r in j.data
                    push!(rows, (
                        ts_utc        = DateTime(String(r.startTime)[1:19]),
                        gb_wind_fcst  = Float64(r.generation),
                    ))
                end
            elseif resp.status == 400
                # BMRS often returns 400 for date ranges with no published
                # forecasts (e.g. far in the past). Just skip.
                @debug "BMRS WINDFOR 400 for $cursor..$nxt; skipping"
            else
                @warn "BMRS WINDFOR $(resp.status) for $cursor..$nxt"
            end
        catch e
            @warn "WINDFOR fetch failed for $cursor..$nxt: $e"
        end
        cursor = nxt
        sleep(0.2)
    end
    df = DataFrame(rows)
    isempty(df) && return DataFrame(ts_utc = DateTime[], gb_wind_fcst = Float64[])
    # Deduplicate (BMRS publishes multiple forecasts per delivery hour);
    # taking the mean is close enough for hourly.
    out = combine(groupby(df, :ts_utc), :gb_wind_fcst => mean => :gb_wind_fcst)
    sort!(out, :ts_utc)
    return out
end

# ---------------------------------------------------------------------------
# Synthetic GB series (correlated with IE)
# ---------------------------------------------------------------------------
#
# The point: GB and IE share Atlantic weather and are interconnected, so the
# synthetic should be plausibly correlated. We don't try to model the GB
# market in detail — we just generate price/wind series correlated with the
# IE drivers so the feature has signal in the synthetic backtest.

"""
    synthetic_gb(start_date, end_date, weather_df) -> NamedTuple

Generates synthetic GB DA price and wind forecast that share the Atlantic
weather signal in `weather_df`. Returns a named tuple with `:price` and
`:wind`, each a hourly DataFrame.
"""
function synthetic_gb(start_date::Date, end_date::Date, weather_df::DataFrame;
                      seed::Int = 17)
    rng = MersenneTwister(seed)
    # GB wind is a smoothed version of UK domain wind, which we proxy as a
    # weighted sum of our 5-station IE wind series (since they cover the
    # Atlantic regime).
    w = weather_df
    n = nrow(w)
    avg_wind = (w.wind_mace_head .+ w.wind_belmullet .+ w.wind_malin_head .+
                w.wind_valentia .+ w.wind_roches_point) ./ 5.0
    # GB installed wind capacity is ~28 GW, ~3x IE — scale up.
    gb_wind = max.(0.0, 800.0 .* avg_wind .+ 1500.0 .* randn(rng, n))

    # GB DA price: residual demand + gas cost + noise; we don't have GB load
    # forecast so use diurnal + weekly cycle.
    base_demand = Vector{Float64}(undef, n)
    for i in 1:n
        h = mod(i - 1, 24)
        dow = mod(div(i - 1, 24), 7) + 1
        wknd = (dow >= 6) ? 0.85 : 1.0
        base_demand[i] = (32000 + 7000 * exp(-((h-8.5)^2)/8) +
                          10000 * exp(-((h-19)^2)/6)) * wknd
    end
    residual = base_demand .- gb_wind
    gb_price = 18.0 .+ 0.0018 .* max.(residual, 0.0) .+ 4.0 .* randn(rng, n)
    # GB pound vs euro: prices roughly equivalent in absolute terms, so don't
    # convert in synthetic.
    return (
        price = DataFrame(ts_utc = w.ts_utc, gb_price = gb_price),
        wind  = DataFrame(ts_utc = w.ts_utc, gb_wind_fcst = gb_wind),
    )
end

# ---------------------------------------------------------------------------
# Caching
# ---------------------------------------------------------------------------

cache_path(name::AbstractString) = begin
    Config.ensure_dirs()
    joinpath(Config.RAW_DIR, "$name.arrow")
end

save(df::DataFrame, name::AbstractString) = Arrow.write(cache_path(name), df)
load(name::AbstractString) = DataFrame(Arrow.Table(cache_path(name)))

end # module
