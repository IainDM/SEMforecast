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
using ZipFile

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

# Resolution string like "PT60M", "PT30M", "PT15M", "PT1M", "PT1H" -> Minute.
# A80 outage docs commonly emit PT1M (curveType=A03 holds the value until
# the next Point, so the small step is fine).
function _parse_resolution(s::AbstractString)
    s == "PT60M" && return Minute(60)
    s == "PT1H"  && return Minute(60)
    s == "PT30M" && return Minute(30)
    s == "PT15M" && return Minute(15)
    s == "PT1M"  && return Minute(1)
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

# SEM load/generation series are published under separate IE and NI EICs;
# the unified SEM_EIC works only for the day-ahead price (A44).
const IE_EIC = "10YIE-1001A00010"

"""
    fetch_load_forecast(start_date, end_date) -> DataFrame

Day-ahead total load forecast (ENTSO-E A65 / processType A01) for the IE
bidding zone (NI load is not separately published to ENTSO-E and IE accounts
for the bulk of SEM demand).

Columns: `ts_utc::DateTime`, `load_fcst::Float64` (MW).
"""
function fetch_load_forecast(start_date::Date, end_date::Date)
    params = Dict(
        "documentType"            => "A65",
        "processType"             => "A01",
        "outBiddingZone_Domain"   => IE_EIC,
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

"""
    fetch_load_actual(start_date, end_date) -> DataFrame

Actual total load (ENTSO-E A65 with processType A16). Use this together with
`fetch_load_forecast` to compute realised forecast errors for the rolling-MAE
features. Columns: `ts_utc`, `load_actual` (MW).
"""
function fetch_load_actual(start_date::Date, end_date::Date)
    params = Dict(
        "documentType"          => "A65",
        "processType"           => "A16",
        "outBiddingZone_Domain" => IE_EIC,
    )
    df = _fetch_series(params, "quantity", start_date, end_date)
    rename!(df, :value => :load_actual)
    return df
end

"""
    fetch_wind_actual(start_date, end_date) -> DataFrame

Actual onshore wind generation (ENTSO-E A75 — Actual Generation per Type,
psrType B19). Pair with `fetch_wind_forecast` for forecast errors.
Columns: `ts_utc`, `wind_actual` (MW).
"""
function fetch_wind_actual(start_date::Date, end_date::Date)
    params = Dict(
        "documentType" => "A75",
        "processType"  => "A16",
        "in_Domain"    => Config.SEM_EIC,
        "psrType"      => "B19",
    )
    df = _fetch_series(params, "quantity", start_date, end_date)
    rename!(df, :value => :wind_actual)
    return df
end

"""
    fetch_actuals_panel(start_date, end_date) -> DataFrame

Convenience wrapper that fetches both actuals and inner-joins on `ts_utc`,
matching the shape of the synthetic `actuals` output.
"""
function fetch_actuals_panel(start_date::Date, end_date::Date)
    la = fetch_load_actual(start_date, end_date)
    wa = fetch_wind_actual(start_date, end_date)
    return innerjoin(la, wa, on = :ts_utc)
end

"""
    fetch_imbalance_prices(start_date, end_date) -> DataFrame

Imbalance settlement price (ENTSO-E A85). SEM publishes this half-hourly; the
parser aggregates to hourly (mean of two settlement periods) so the series is
directly comparable with the hourly day-ahead price.

Columns: `ts_utc::DateTime`, `isp::Float64` (€/MWh).
"""
function fetch_imbalance_prices(start_date::Date, end_date::Date)
    params = Dict(
        "documentType"        => "A85",
        "controlArea_Domain"  => Config.SEM_EIC,
    )
    df = _fetch_series(params, "price.amount", start_date, end_date)
    rename!(df, :value => :isp)
    return df
end

"""
    fetch_outages(start_date, end_date) -> DataFrame

Generator outage / unavailability documents (ENTSO-E A77 — production and
consumption unit outages). For each hour we aggregate total offline capacity
across all units with active outage windows.

The full A77 document has rich structure (per-unit, per-business-type,
planned vs forced). This helper returns the hourly aggregate that drives
short-run scarcity pricing; if the caller needs the per-unit detail they
should extend `_parse_outages` below.

Columns: `ts_utc::DateTime`, `outage_capacity_mw::Float64`,
`unplanned_outage_mw::Float64`, `large_outage_flag::Int` (1 if any single
unit >300 MW offline in that hour, else 0).
"""
function fetch_outages(start_date::Date, end_date::Date)
    base = Dict(
        "documentType" => "A77",
        "biddingZone_Domain" => Config.SEM_EIC,
    )
    out = Tuple{DateTime,Float64,Float64,Int}[]
    for (a, b) in _chunks(start_date, end_date)
        params = copy(base)
        params["periodStart"] = _entsoe_period(ZonedDateTime(DateTime(a), tz"UTC"))
        params["periodEnd"]   = _entsoe_period(ZonedDateTime(DateTime(b), tz"UTC"))
        doc = _request(params)
        _is_no_data(doc) && continue
        append!(out, _parse_outages(doc))
        sleep(0.4)
    end
    isempty(out) && return DataFrame(ts_utc = DateTime[],
        outage_capacity_mw = Float64[], unplanned_outage_mw = Float64[],
        large_outage_flag = Int[])
    return _aggregate_outages(out)
end

# ---------------------------------------------------------------------------
# A80 unavailability (ZIP-of-XML) — what SEM actually publishes
# ---------------------------------------------------------------------------
#
# A77 is empty for SEM. Generator unavailability for the SEM bidding zone is
# served as an A80 "Unavailability of production and generation units"
# document, returned as `application/zip` containing one XML per outage event.
# When the requested window has no events, ENTSO-E still returns an
# Acknowledgement XML (handled by `_is_no_data`).

# Parallel to `_request`: returns either (:xml, doc) for Acknowledgement-style
# responses or (:zip, body_bytes) for the data path.
function _request_zip(params::Dict{String,String}; retries::Int = 2)
    url = _build_url(params)
    last_err = nothing
    for attempt in 1:(retries + 1)
        try
            resp = HTTP.get(url; readtimeout = 120, retry = false,
                            status_exception = false)
            if resp.status == 200
                ct = lowercase(String(HTTP.header(resp, "Content-Type", "")))
                if occursin("zip", ct) || occursin("octet-stream", ct)
                    return (:zip, Vector{UInt8}(resp.body))
                else
                    # Acknowledgement / inline XML — let the caller handle it
                    # via the existing _is_no_data path.
                    return (:xml, parsexml(resp.body))
                end
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
    error("ENTSO-E (zip) request failed after retries: $last_err")
end

# Open a ZIP body and return parsed XML documents whose archive entry name
# looks like an unavailability XML (the SEM A80 archives are named e.g.
# `001-UNAVAILABILITY_OF_PRODUCTION_AND_GENERATION_UNITS_<eic>.xml`).
function _unzip_outage_docs(zip_bytes::Vector{UInt8})
    docs = EzXML.Document[]
    r = ZipFile.Reader(IOBuffer(zip_bytes))
    try
        for f in r.files
            occursin(r"\.xml$"i, f.name) || continue
            occursin(r"unavail|outage|production"i, f.name) || continue
            data = read(f)
            try
                push!(docs, parsexml(data))
            catch e
                @warn "Failed to parse A80 archive entry; skipping" name=f.name exception=e
            end
        end
    finally
        close(r)
    end
    return docs
end

"""
    fetch_outages_a80(start_date, end_date) -> DataFrame

Generator unavailability via ENTSO-E A80 (zipped XML). SEM publishes outages
through this endpoint rather than A77; output schema matches `fetch_outages`
so callers and feature engineering can swap one for the other.

Columns: `ts_utc::DateTime`, `outage_capacity_mw::Float64`,
`unplanned_outage_mw::Float64`, `large_outage_flag::Int`.
"""
function fetch_outages_a80(start_date::Date, end_date::Date)
    base = Dict(
        "documentType"       => "A80",
        "biddingZone_Domain" => Config.SEM_EIC,
    )
    out = Tuple{DateTime,Float64,Float64,Int}[]
    for (a, b) in _chunks(start_date, end_date)
        params = copy(base)
        params["periodStart"] = _entsoe_period(ZonedDateTime(DateTime(a), tz"UTC"))
        params["periodEnd"]   = _entsoe_period(ZonedDateTime(DateTime(b), tz"UTC"))
        tag, payload = _request_zip(params)
        # A80 returns the full outage window for any event whose validity
        # overlaps the requested period, so we filter to the chunk's
        # [chunk_a, chunk_b) window to avoid double-counting events that
        # span chunk boundaries.
        chunk_lo = DateTime(a)
        chunk_hi = DateTime(b)
        _push_in_window = (rows) -> begin
            for row in rows
                if chunk_lo <= row[1] < chunk_hi
                    push!(out, row)
                end
            end
        end
        if tag === :xml
            _is_no_data(payload) && (sleep(0.4); continue)
            # Inline (non-zipped) Unavailability document — parse with the A80
            # schema, not A77.
            _push_in_window(_parse_outages_a80(payload))
        else
            for doc in _unzip_outage_docs(payload)
                _push_in_window(_parse_outages_a80(doc))
            end
        end
        sleep(0.4)
    end
    isempty(out) && return DataFrame(ts_utc = DateTime[],
        outage_capacity_mw = Float64[], unplanned_outage_mw = Float64[],
        large_outage_flag = Int[])
    return _aggregate_outages(out)
end

# A80 documents are structured differently from A77:
#   <Unavailability_MarketDocument>
#     <TimeSeries>
#       <businessType>A53|A54</businessType>          -- planned / forced
#       <start_DateAndOrTime.date>…</…>               -- separate date + time
#       <start_DateAndOrTime.time>…</…>
#       <end_DateAndOrTime.date>…</…>
#       <end_DateAndOrTime.time>…</…>
#       <production_RegisteredResource.pSRType.powerSystemResources.nominalP unit="MAW">…</…>
#       <Available_Period>                            -- one per TimeSeries
#         <timeInterval><start/><end/></timeInterval>
#         <resolution>PT1M|PT15M|PT30M|PT60M</resolution>
#         <Point><position/><quantity/></Point>        -- piecewise-constant
#       </Available_Period>
#     </TimeSeries>
#   </Unavailability_MarketDocument>
#
# The `<quantity>` is the AVAILABLE capacity remaining (MW); offline is the
# nominal minus available. With `curveType=A03` the value is held until the
# next Point — so to expand to hourly we walk one hour at a time and look up
# the most recent Point.
function _parse_outages_a80(doc)
    rows = Tuple{DateTime,Float64,Float64,Int}[]
    for ts_node in _children(root(doc), "TimeSeries")
        btype = _child_text(ts_node, "businessType")
        unplanned = btype == "A54"

        # Nominal capacity (deep field name, exact match needed).
        nominal = let
            n = _first_child(ts_node,
                "production_RegisteredResource.pSRType.powerSystemResources.nominalP")
            if n === nothing
                0.0
            else
                v = strip(nodecontent(n))
                try parse(Float64, v) catch; 0.0 end
            end
        end
        nominal <= 0.0 && continue

        for ap in _children(ts_node, "Available_Period")
            ti = _first_child(ap, "timeInterval")
            ti === nothing && continue
            start_text = _child_text(ti, "start")
            end_text   = _child_text(ti, "end")
            (start_text === nothing || end_text === nothing) && continue
            start_utc = _parse_utc(start_text)
            end_utc   = _parse_utc(end_text)
            res_text  = _child_text(ap, "resolution")
            res_text === nothing && continue
            step = _parse_resolution(res_text)

            points = Tuple{Int,Float64}[]
            for pt in _children(ap, "Point")
                pos_text = _child_text(pt, "position")
                qty_text = _child_text(pt, "quantity")
                (pos_text === nothing || qty_text === nothing) && continue
                push!(points, (parse(Int, pos_text), parse(Float64, qty_text)))
            end
            sort!(points; by = first)
            isempty(points) && continue

            # Step duration in minutes.
            step_min = Dates.value(step)

            # First hour to emit: ceiling of start_utc to the next hour.
            current = floor(start_utc, Hour)
            current < start_utc && (current += Hour(1))
            while current < end_utc
                # Position is 1-indexed relative to step from start_utc.
                offset_min = Dates.value(current - start_utc) ÷ 60_000
                pos = offset_min ÷ step_min + 1
                # Find the most recent Point with position <= pos. Default to
                # the first Point's quantity if pos < points[1][1].
                avail = points[1][2]
                for (p, q) in points
                    if p <= pos
                        avail = q
                    else
                        break
                    end
                end
                offline = max(0.0, nominal - avail)
                if offline > 0.0
                    push!(rows, (current, offline, unplanned ? offline : 0.0,
                                 offline > 300.0 ? 1 : 0))
                end
                current += Hour(1)
            end
        end
    end
    return rows
end

# Per-document parse: emit one row per (timestamp, available_capacity,
# nominal_capacity, businessType). For SEM, nominal_capacity is in the
# Production Unit; we read both fields.
function _parse_outages(doc)
    rows = Tuple{DateTime,Float64,Float64,Int}[]  # ts, offline_mw, unplanned_mw, large_flag
    for ts_node in _timeseries_nodes(doc)
        # businessType: "A53" planned, "A54" unplanned
        btype = _child_text(ts_node, "businessType")
        unplanned = btype == "A54"
        # nominalCapacity is in nested ProductionRegisteredResource node.
        nominal = let n = _first_child(ts_node, "ProductionRegisteredResource_nominalCapacity")
            n === nothing ? 0.0 :
                let v = _child_text(n, "value"); v === nothing ? 0.0 : parse(Float64, v) end
        end
        for period in _children(ts_node, "Period")
            ti = _first_child(period, "timeInterval")
            ti === nothing && continue
            start_text = _child_text(ti, "start"); start_text === nothing && continue
            start_utc = _parse_utc(start_text)
            res_text = _child_text(period, "resolution"); res_text === nothing && continue
            step = _parse_resolution(res_text)
            for pt in _children(period, "Point")
                pos_text = _child_text(pt, "position")
                qty_text = _child_text(pt, "quantity")
                (pos_text === nothing || qty_text === nothing) && continue
                pos = parse(Int, pos_text)
                avail = parse(Float64, qty_text)
                offline = max(0.0, nominal - avail)
                ts = start_utc + step * (pos - 1)
                large = (offline > 300.0) ? 1 : 0
                push!(rows, (ts, offline, unplanned ? offline : 0.0, large))
            end
        end
    end
    return rows
end

# Bucket the (potentially overlapping, multi-unit) rows to hourly aggregates.
function _aggregate_outages(rows::Vector{Tuple{DateTime,Float64,Float64,Int}})
    sort!(rows; by = r -> r[1])
    buckets = Dict{DateTime,Vector{Tuple{Float64,Float64,Int}}}()
    for (ts, offline, unplanned, large) in rows
        h = floor(ts, Hour)
        push!(get!(buckets, h, Tuple{Float64,Float64,Int}[]), (offline, unplanned, large))
    end
    ks = sort(collect(keys(buckets)))
    return DataFrame(
        ts_utc              = ks,
        outage_capacity_mw  = [sum(first.(buckets[k])) for k in ks],
        unplanned_outage_mw = [sum(getindex.(buckets[k], 2)) for k in ks],
        large_outage_flag   = [maximum(getindex.(buckets[k], 3)) for k in ks],
    )
end

# ---------------------------------------------------------------------------
# Synthetic data for offline smoke tests
# ---------------------------------------------------------------------------

"""
    synthetic_dataset(start_date, end_date; weather_df = nothing, seed = 42)

Generates plausible SEM-like hourly series. When `weather_df` is supplied
(from `Weather.synthetic_weather`), the realised wind generation, demand,
and forecast errors are **causally driven** by the weather signal — this
is what makes weather features genuinely predictive in the synthetic
backtest. Without it, the function falls back to the pre-weather model.

The function also generates generator outages as a Poisson process of
single-unit trips (300–500 MW lasting 6–36 hours) plus a smaller background
of planned outages, and emits actual (post-delivery) load + wind so the
rolling forecast-MAE features have something to bite on.

Returned named tuple keys:
  prices, load, wind, solar, imbalance,
  actuals (load_actual, wind_actual),
  outages (outage_capacity_mw, unplanned_outage_mw, large_outage_flag).
"""
function synthetic_dataset(start_date::Date, end_date::Date;
                           weather_df::Union{Nothing,DataFrame} = nothing,
                           seed::Int = 42)
    rng = MersenneTwister(seed)
    n_days = Dates.value(end_date - start_date)
    n = n_days * 24
    ts = [DateTime(start_date) + Hour(i) for i in 0:n-1]

    # ----- Weather-derived wind regime -----
    if weather_df === nothing
        # Fallback: deterministic seasonal + diurnal pattern with noise.
        avg_coastal_wind = [10.0 + 5.0 * sin(2π * i / (24 * 5)) +
                            2.5 * sin(2π * i / 24) + randn(rng) for i in 1:n]
        temp_dub = [10.0 + 7.0 * sin(2π * (i / (24 * 365.25) - 0.25)) +
                    3.0 * sin(2π * (mod(i,24) - 4)/24) + randn(rng) for i in 1:n]
    else
        # Use weather as the causal driver.
        w = sort(weather_df, :ts_utc)
        # Align weather to our timestamps — assume same start.
        @assert nrow(w) >= n "weather_df shorter than synthetic horizon"
        avg_coastal_wind = (w.wind_mace_head[1:n] .+ w.wind_belmullet[1:n] .+
                             w.wind_malin_head[1:n] .+ w.wind_valentia[1:n] .+
                             w.wind_roches_point[1:n]) ./ 5.0
        temp_dub = w.temp_dublin[1:n]
    end

    # ----- Outages: Poisson trips + slow-moving planned -----
    outage_capacity_mw  = zeros(Float64, n)
    unplanned_outage_mw = zeros(Float64, n)
    large_outage_flag   = zeros(Int, n)
    # Baseline planned outage drifting around 600 MW.
    planned = Vector{Float64}(undef, n)
    planned[1] = 600.0
    for i in 2:n
        planned[i] = max(200.0, planned[i-1] + 50.0 * randn(rng))
    end
    outage_capacity_mw .+= planned
    # Unplanned trip events: rare large-unit failures.
    for _ in 1:max(1, n ÷ (24 * 18))      # ~one trip every ~18 days on average
        i0 = rand(rng, 1:n)
        mw  = 250.0 + 250.0 * rand(rng)
        dur = rand(rng, 6:36)
        for k in i0:min(i0 + dur - 1, n)
            outage_capacity_mw[k]  += mw
            unplanned_outage_mw[k] += mw
            mw > 300.0 && (large_outage_flag[k] = 1)
        end
    end

    # ----- Realised wind, load -----
    wind_actual = Vector{Float64}(undef, n)
    load_actual = Vector{Float64}(undef, n)
    solar       = Vector{Float64}(undef, n)
    wind_fcst   = Vector{Float64}(undef, n)
    load_fcst   = Vector{Float64}(undef, n)
    price       = Vector{Float64}(undef, n)
    isp         = Vector{Float64}(undef, n)

    # Persistent forecast-error innovations.
    re_load = randn(rng, n) .* 250.0
    re_wind_base = randn(rng, n) .* 400.0

    for i in 1:n
        t = ts[i]
        h = hour(t)
        dow = dayofweek(t)
        wknd = (dow >= 6) ? 0.85 : 1.0

        # Realised wind generation driven by measured coastal wind speed
        # (kt → MW via a saturating logistic; IE installed capacity ~5.5 GW).
        w = avg_coastal_wind[i]
        wind_actual[i] = 5500.0 / (1.0 + exp(-(w - 12.0) / 4.0))
        # Forecast error scales with regime — high wind = larger absolute MAE.
        err_scale = 1.0 + 0.05 * max(w, 0.0)
        wind_fcst[i] = max(0.0, wind_actual[i] + re_wind_base[i] * err_scale)

        # Demand: base shape modulated by temperature (heating-degree-days).
        hdd = max(0.0, 15.5 - temp_dub[i])
        cdd = max(0.0, temp_dub[i] - 22.0)
        load_actual[i] = (3300.0 +
                          1200.0 * exp(-((h - 8.5)^2)/8) +
                          1800.0 * exp(-((h - 19)^2)/6) +
                          45.0 * hdd + 60.0 * cdd) * wknd + 100.0 * randn(rng)
        load_fcst[i] = max(0.0, load_actual[i] + re_load[i])

        # Solar (small in SEM): same forecast = actual.
        solar[i] = (h >= 6 && h <= 20) ?
                   max(0.0, 150 * exp(-((h-13)^2)/12) + 30 * randn(rng)) : 0.0

        # DAM price: function of FORECAST residual demand (known at auction)
        # minus available capacity (planned outages reduce supply).
        residual_fcst = load_fcst[i] - wind_fcst[i] - solar[i]
        # Scarcity premium grows non-linearly as outages bite.
        scarcity = 0.020 * max(residual_fcst + outage_capacity_mw[i] - 4500.0, 0.0)
        price[i] = 20.0 + 0.022 * max(residual_fcst, 0.0) +
                   0.5 * scarcity +
                   5.0 * randn(rng)
        # Rare spike on top.
        rand(rng) < 0.003 && (price[i] += 200.0 * rand(rng))
        price[i] = max(-50.0, price[i])

        # ISP = DA + structured basis + noise. Now also driven by:
        #   - realised residual demand vs forecast (the "auction surprise")
        #   - unplanned outages happening during delivery
        residual_real = load_actual[i] - wind_actual[i] - solar[i]
        surprise = residual_real - residual_fcst   # positive = system tighter than expected
        tight = (residual_fcst - 3500.0) / 1500.0
        prev_basis = (i > 24) ? (isp[i-24] - price[i-24]) : 0.0
        structured = 4.0 * max(tight, 0.0)^2 * sign(tight) +
                     0.012 * surprise +
                     0.025 * unplanned_outage_mw[i] +
                     1.5 * sin(2π * (h - 4) / 24) +
                     0.35 * prev_basis
        noise_scale = 2.5 + 1.5 * exp(-((h-19)^2)/12) + 0.0015 * wind_actual[i]
        spike = (rand(rng) < 0.01) ? (rand(rng) < 0.5 ? -1 : 1) * (15.0 + 30.0 * rand(rng)) : 0.0
        isp[i] = max(-100.0, price[i] + structured + noise_scale * randn(rng) + spike)
    end

    return (
        prices    = DataFrame(ts_utc = ts, price     = price),
        load      = DataFrame(ts_utc = ts, load_fcst = load_fcst),
        wind      = DataFrame(ts_utc = ts, wind_fcst = wind_fcst),
        solar     = DataFrame(ts_utc = ts, solar_fcst = solar),
        imbalance = DataFrame(ts_utc = ts, isp       = isp),
        actuals   = DataFrame(ts_utc = ts, load_actual = load_actual,
                              wind_actual = wind_actual),
        outages   = DataFrame(ts_utc = ts,
                              outage_capacity_mw = outage_capacity_mw,
                              unplanned_outage_mw = unplanned_outage_mw,
                              large_outage_flag = large_outage_flag),
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
