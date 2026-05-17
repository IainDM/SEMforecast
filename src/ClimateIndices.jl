module ClimateIndices

using Dates
using DataFrames
using Statistics
using Random
using HTTP
using Arrow

using ..Config

const NAO_URL = "https://www.cpc.ncep.noaa.gov/products/precip/CWlink/pna/norm.nao.monthly.b5001.current.ascii"

# ---------------------------------------------------------------------------
# Real NAO fetcher — NOAA CPC monthly text feed
# ---------------------------------------------------------------------------
#
# Format: whitespace-separated " yyyy  mm    value", one record per month,
# from 1950 to current month. Free, no auth.

"""
    fetch_nao() -> DataFrame

Returns the full NAO (North Atlantic Oscillation) monthly index series from
NOAA CPC. Positive NAO = strong westerlies = high IE wind regime; persists
days to weeks so it's useful as a multi-day predictor.

Columns: `year::Int`, `month::Int`, `nao_monthly::Float64`.
"""
function fetch_nao(; timeout::Int = 30)
    resp = HTTP.get(NAO_URL; readtimeout = timeout, retry = true, retries = 2)
    rows = NamedTuple[]
    for line in eachline(IOBuffer(resp.body))
        parts = filter(!isempty, split(strip(line)))
        length(parts) == 3 || continue
        try
            yr = parse(Int, parts[1])
            mn = parse(Int, parts[2])
            v  = parse(Float64, parts[3])
            push!(rows, (year = yr, month = mn, nao_monthly = v))
        catch
            continue
        end
    end
    return sort!(DataFrame(rows), [:year, :month])
end

"""
    nao_daily(start_date, end_date) -> DataFrame

Broadcasts the monthly NAO index over every calendar date in the range.
Returns `date::Date`, `nao_monthly::Float64`.

Tries the real NOAA CPC feed first; falls back to a synthetic series if the
network is unavailable.
"""
function nao_daily(start_date::Date, end_date::Date; allow_synthetic::Bool = true)
    monthly = try
        fetch_nao()
    catch e
        allow_synthetic || rethrow(e)
        @warn "NAO fetch failed ($e); using synthetic"
        return synthetic_nao_daily(start_date, end_date)
    end
    dates = collect(start_date:Day(1):end_date)
    lookup = Dict((r.year, r.month) => r.nao_monthly for r in eachrow(monthly))
    vals = Vector{Float64}(undef, length(dates))
    last_known = 0.0
    for (i, d) in enumerate(dates)
        v = get(lookup, (year(d), month(d)), missing)
        if v === missing
            vals[i] = last_known
        else
            vals[i] = v
            last_known = v
        end
    end
    return DataFrame(date = dates, nao_monthly = vals)
end

# ---------------------------------------------------------------------------
# Synthetic fallback
# ---------------------------------------------------------------------------

function synthetic_nao_daily(start_date::Date, end_date::Date; seed::Int = 11)
    rng = MersenneTwister(seed)
    dates = collect(start_date:Day(1):end_date)
    n = length(dates)
    # Multi-month AR(1) random walk anchored near zero.
    vals = Vector{Float64}(undef, n)
    vals[1] = 0.0
    for i in 2:n
        vals[i] = 0.98 * vals[i-1] + 0.4 * randn(rng)
    end
    return DataFrame(date = dates, nao_monthly = vals)
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
