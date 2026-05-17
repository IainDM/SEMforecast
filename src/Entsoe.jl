module Entsoe

using Dates
using TimeZones
using DataFrames
using HTTP
using EzXML
using Arrow
using Printf
using Random
using Statistics

using ..Config

# ---------------------------------------------------------------------------
# Low-level REST client
# ---------------------------------------------------------------------------

# ENTSO-E expects YYYYMMDDHHMM in UTC.
function _entsoe_period(dt::ZonedDateTime)
    utc = astimezone(dt, tz"UTC")
    return @sprintf("%04d%02d%02d%02d%02d",
                    year(utc), month(utc), day(utc), hour(utc), minute(utc))
end

# Build the query URL.
function _build_url(params::Dict{String,String})
    token = Config.entsoe_api_key()
    parts = ["securityToken=$token"]
    for (k, v) in params
        push!(parts, "$(k)=$(HTTP.escapeuri(v))")
    end
    return Config.ENTSOE_BASE_URL * "?" * join(parts, "&")
end

# Issue a request and return parsed XML root. ENTSO-E returns HTTP 200 with
# acknowledgement XML when no data is found; we let the caller detect and
# treat it as an empty result.
function _request(params::Dict{String,String}; retries::Int = 2)
    url = _build_url(params)
    last_err = nothing
    for attempt in 1:(retries + 1)
        try
            resp = HTTP.get(url; readtimeout = 60, retry = false,
                            status_exception = false)
            if resp.status == 200
                return parsexml(resp.body)
            elseif resp.status == 429
                @warn "ENTSO-E rate limited (429), backing off"
                sleep(5.0 * attempt)
            elseif resp.status >= 500
                @warn "ENTSO-E $(resp.status), retrying" attempt
                sleep(2.0 * attempt)
            else
                error("ENTSO-E HTTP $(resp.status): $(String(resp.body)[1:min(end,500)])")
            end
        catch e
            last_err = e
            attempt > retries && rethrow(e)
            sleep(2.0 * attempt)
        end
    end
    error("ENTSO-E request failed after retries: $last_err")
end

# ---------------------------------------------------------------------------
# XML helpers (namespace-agnostic by local-name matching)
# ---------------------------------------------------------------------------

# Return last segment of qualified name (e.g. "ns:Foo" -> "Foo").
_localname(node) = let n = nodename(node); s = findlast(':', n);
                       s === nothing ? n : n[s+1:end]; end

# Direct element children whose local name matches `name`.
function _children(node, name::AbstractString)
    out = EzXML.Node[]
    for c in eachelement(node)
        _localname(c) == name && push!(out, c)
    end
    return out
end

_first_child(node, name) = (cs = _children(node, name); isempty(cs) ? nothing : cs[1])

function _child_text(node, name)
    c = _first_child(node, name)
    c === nothing ? nothing : strip(nodecontent(c))
end

# Resolution string like "PT60M", "PT30M", "PT15M", "PT1H" -> Minute.
function _parse_resolution(s::AbstractString)
    s == "PT60M" && return Minute(60)
    s == "PT1H"  && return Minute(60)
    s == "PT30M" && return Minute(30)
    s == "PT15M" && return Minute(15)
    s == "P1Y"   && return Minute(60 * 24 * 365)  # not expected, but safe
    error("Unsupported ENTSO-E resolution: $s")
end

function _parse_utc(s::AbstractString)
    # Accept "...Z" and "...+00:00".
    clean = endswith(s, "Z") ? s[1:end-1] : s
    return DateTime(clean[1:min(end, 19)])
end

# ---------------------------------------------------------------------------
# TimeSeries parser
# ---------------------------------------------------------------------------

# Parse a single TimeSeries -> Vector{(DateTime_UTC, Float64)}.
# `value_tag` is the leaf element holding the numeric value
# ("price.amount" for prices, "quantity" for load/generation).
function _parse_timeseries(ts_node, value_tag::AbstractString)
    out = Tuple{DateTime,Float64}[]
    for period in _children(ts_node, "Period")
        ti = _first_child(period, "timeInterval")
        ti === nothing && continue
        start_text = _child_text(ti, "start")
        start_text === nothing && continue
        start_utc = _parse_utc(start_text)
        res_text = _child_text(period, "resolution")
        res_text === nothing && continue
        step = _parse_resolution(res_text)

        for pt in _children(period, "Point")
            pos_text = _child_text(pt, "position")
            val_text = _child_text(pt, value_tag)
            (pos_text === nothing || val_text === nothing) && continue
            pos = parse(Int, pos_text)
            val = parse(Float64, val_text)
            ts = start_utc + step * (pos - 1)
            push!(out, (ts, val))
        end
    end
    return out
end

# Detect the ENTSO-E "no data" acknowledgement document.
function _is_no_data(doc)
    root_ = root(doc)
    return _localname(root_) == "Acknowledgement_MarketDocument"
end

# Iterate TimeSeries nodes of a parsed doc.
function _timeseries_nodes(doc)
    _children(root(doc), "TimeSeries")
end

# Resample arbitrary-resolution series to hourly by taking the mean of all
# sub-hour points whose UTC timestamp floors to the same hour.
function _to_hourly(rows::Vector{Tuple{DateTime,Float64}})
    isempty(rows) && return DataFrame(ts_utc = DateTime[], value = Float64[])
    sort!(rows; by = first)
    bucket = Dict{DateTime,Vector{Float64}}()
    for (ts, v) in rows
        h = floor(ts, Hour)
        push!(get!(bucket, h, Float64[]), v)
    end
    keys_sorted = sort(collect(keys(bucket)))
    vals = [mean(bucket[k]) for k in keys_sorted]
    return DataFrame(ts_utc = keys_sorted, value = vals)
end

# ---------------------------------------------------------------------------
# Chunked fetch (ENTSO-E enforces ~1 year max per request)
# ---------------------------------------------------------------------------

# Splits [start_date, end_date) into ~1-year chunks (UTC midnight aligned).
function _chunks(start_date::Date, end_date::Date)
    chunks = Tuple{Date,Date}[]
    cur = start_date
    while cur < end_date
        nxt = min(cur + Day(365), end_date)
        push!(chunks, (cur, nxt))
        cur = nxt
    end
    return chunks
end

function _fetch_series(base_params::Dict{String,String}, value_tag::AbstractString,
                      start_date::Date, end_date::Date)
    all_rows = Tuple{DateTime,Float64}[]
    for (a, b) in _chunks(start_date, end_date)
        params = copy(base_params)
        z_a = ZonedDateTime(DateTime(a), tz"UTC")
        z_b = ZonedDateTime(DateTime(b), tz"UTC")
        params["periodStart"] = _entsoe_period(z_a)
        params["periodEnd"]   = _entsoe_period(z_b)
        doc = _request(params)
        _is_no_data(doc) && continue
        for ts in _timeseries_nodes(doc)
            append!(all_rows, _parse_timeseries(ts, value_tag))
        end
        sleep(0.4)  # polite spacing between requests
    end
    return _to_hourly(all_rows)
end

# ---------------------------------------------------------------------------
# Public fetchers
# ---------------------------------------------------------------------------

"""
    fetch_day_ahead_prices(start_date, end_date) -> DataFrame

Returns hourly DAM prices for the SEM bidding zone.
Columns: `ts_utc::DateTime`, `price::Float64`.
"""
function fetch_day_ahead_prices(start_date::Date, end_date::Date)
    params = Dict(
        "documentType" => "A44",
        "in_Domain"    => Config.SEM_EIC,
        "out_Domain"   => Config.SEM_EIC,
    )
    df = _fetch_series(params, "price.amount", start_date, end_date)
    rename!(df, :value => :price)
    return df
end

"""
    fetch_load_forecast(start_date, end_date) -> DataFrame

Day-ahead total load forecast (ENTSO-E A65 / processType A01).
Columns: `ts_utc::DateTime`, `load_fcst::Float64` (MW).
"""
function fetch_load_forecast(start_date::Date, end_date::Date)
    params = Dict(
        "documentType"            => "A65",
        "processType"             => "A01",
        "outBiddingZone_Domain"   => Config.SEM_EIC,
    )
    df = _fetch_series(params, "quantity", start_date, end_date)
    rename!(df, :value => :load_fcst)
    return df
end

"""
    fetch_wind_forecast(start_date, end_date) -> DataFrame

Day-ahead onshore wind generation forecast. Columns: `ts_utc`, `wind_fcst`.
"""
function fetch_wind_forecast(start_date::Date, end_date::Date)
    params = Dict(
        "documentType" => "A69",
        "processType"  => "A01",
        "in_Domain"    => Config.SEM_EIC,
        "psrType"      => "B19",  # onshore wind
    )
    df = _fetch_series(params, "quantity", start_date, end_date)
    rename!(df, :value => :wind_fcst)
    return df
end

"""
    fetch_solar_forecast(start_date, end_date) -> DataFrame

Day-ahead solar generation forecast. Columns: `ts_utc`, `solar_fcst`.
"""
function fetch_solar_forecast(start_date::Date, end_date::Date)
    params = Dict(
        "documentType" => "A69",
        "processType"  => "A01",
        "in_Domain"    => Config.SEM_EIC,
        "psrType"      => "B16",
    )
    try
        df = _fetch_series(params, "quantity", start_date, end_date)
        rename!(df, :value => :solar_fcst)
        return df
    catch e
        @warn "Solar forecast fetch failed ($e); returning zeros"
        return DataFrame(ts_utc = DateTime[], solar_fcst = Float64[])
    end
end

# ---------------------------------------------------------------------------
# Synthetic data for offline smoke tests
# ---------------------------------------------------------------------------

"""
    synthetic_dataset(start_date, end_date)

Generates plausible SEM-like hourly series (price, load_fcst, wind_fcst,
solar_fcst) without hitting the network. Captures the broad structure: daily
double-peak demand, weekly cycle, wind-driven price suppression, occasional
spikes. Useful for end-to-end pipeline tests without an API token.
"""
function synthetic_dataset(start_date::Date, end_date::Date; seed::Int = 42)
    rng = MersenneTwister(seed)
    hours_per_day = 24
    n_days = Dates.value(end_date - start_date)
    n = n_days * hours_per_day
    base_dt = DateTime(start_date)
    ts = [base_dt + Hour(i) for i in 0:n-1]

    # Load profile: morning + evening peaks, weekday/weekend modulation.
    load = Vector{Float64}(undef, n)
    wind = Vector{Float64}(undef, n)
    solar = Vector{Float64}(undef, n)
    price = Vector{Float64}(undef, n)

    for i in 1:n
        t = ts[i]
        h = hour(t)
        dow = dayofweek(t)
        wknd_mul = (dow >= 6) ? 0.85 : 1.0
        # Two-peak demand pattern (morning 8-9, evening 18-20).
        load[i] = 3500 + 1200 * exp(-((h-8.5)^2)/8) +
                  1800 * exp(-((h-19)^2)/6) + 200 * randn(rng)
        load[i] *= wknd_mul

        # Wind: slow-changing random walk + diurnal noise.
        wind[i] = max(0.0, 1500 + 1000 * sin(2π * i / (24*5)) +
                            500 * sin(2π * i / 24) + 300 * randn(rng))

        # Solar: bell-shaped during daylight, zero overnight, small in SEM.
        solar[i] = (h >= 6 && h <= 20) ?
                   max(0.0, 150 * exp(-((h-13)^2)/12) + 30 * randn(rng)) :
                   0.0

        # Price ~ residual-demand driven, with floor and occasional spike.
        residual = load[i] - wind[i] - solar[i]
        price[i] = 20.0 + 0.025 * max(residual, 0.0) + 5 * randn(rng)
        if rand(rng) < 0.003
            price[i] += 200 * rand(rng)  # spike
        end
        price[i] = max(-50.0, price[i])
    end

    return (
        prices    = DataFrame(ts_utc = ts, price     = price),
        load      = DataFrame(ts_utc = ts, load_fcst = load),
        wind      = DataFrame(ts_utc = ts, wind_fcst = wind),
        solar     = DataFrame(ts_utc = ts, solar_fcst= solar),
    )
end

# ---------------------------------------------------------------------------
# Caching to Arrow
# ---------------------------------------------------------------------------

function cache_path(name::AbstractString)
    Config.ensure_dirs()
    return joinpath(Config.RAW_DIR, "$name.arrow")
end

save(df::DataFrame, name::AbstractString) = Arrow.write(cache_path(name), df)

function load(name::AbstractString)
    p = cache_path(name)
    isfile(p) || error("ENTSO-E cache missing: $p (run scripts/fetch_data.jl)")
    return DataFrame(Arrow.Table(p))
end

end # module
