module Weather

using Dates
using DataFrames
using Statistics
using Random
using HTTP
using CSV
using Arrow

using ..Config

# Met Éireann historical hourly station IDs. Source: met.ie historical data
# index. The five coastal/island stations cover the dominant Atlantic wind
# regimes that drive SEM generation; Dublin Airport drives demand.
const ME_STATIONS = (
    mace_head    = 175,    # Mace Head, Galway (Atlantic west coast)
    belmullet    = 2375,   # Belmullet, Mayo
    malin_head   = 1575,   # Malin Head, Donegal (north tip)
    valentia     = 2275,   # Valentia Observatory, Kerry (SW)
    roches_point = 1075,   # Roches Point, Cork (SE)
    dublin       = 532,    # Dublin Airport — Met Éireann synoptic station
)

const ME_BASE_URL = "https://cli.fusio.net/cli/climate_data/webdata"

# ---------------------------------------------------------------------------
# Real Met Éireann hourly CSV fetcher
# ---------------------------------------------------------------------------
#
# Note: the cli.fusio.net endpoint times out from the current managed
# execution environment (network policy). This code path is kept so it works
# the moment outbound access is available — typically when run locally.

"""
    fetch_metereann_station(station_id, start_date, end_date) -> DataFrame

Returns hourly weather for one Met Éireann automatic synoptic station.
Columns: `ts_utc::DateTime`, `wind_speed::Float64` (knots), `wind_dir::Float64`
(degrees, 0–360), `temp::Float64` (°C), `pressure::Float64` (hPa).

Missing data values in the source CSV are returned as `missing`.
"""
function fetch_metereann_station(station_id::Integer, start_date::Date, end_date::Date;
                                 timeout::Int = 30)
    url = "$(ME_BASE_URL)/hly$(station_id).csv"
    resp = HTTP.get(url; readtimeout = timeout, retry = true, retries = 2)
    df = CSV.read(IOBuffer(resp.body), DataFrame;
                  comment = "#", missingstring = ["", " "])
    # Met Éireann CSV header is typically: date, ind, rain, ind, temp, ...,
    # wdsp, ind, wddir, ... — column names vary by station. We match on
    # known column names.
    cmap = lowercase.(string.(names(df)))
    function _col(needle)
        i = findfirst(c -> occursin(needle, c), cmap)
        return i === nothing ? nothing : names(df)[i]
    end
    date_col = _col("date")
    out = DataFrame(
        ts_utc     = DateTime.(df[!, date_col], dateformat"dd-uuu-yyyy HH:MM"),
        wind_speed = Float64.(coalesce.(df[!, _col("wdsp")], NaN)),
        wind_dir   = Float64.(coalesce.(df[!, _col("wddir")], NaN)),
        temp       = Float64.(coalesce.(df[!, _col("temp")], NaN)),
        pressure   = Float64.(coalesce.(df[!, _col("msl")], NaN)),
    )
    sort!(out, :ts_utc)
    out = out[(out.ts_utc .>= DateTime(start_date)) .&
              (out.ts_utc .<  DateTime(end_date + Day(1))), :]
    return out
end

"""
    fetch_metereann_panel(start_date, end_date) -> DataFrame

Fetches all five coastal stations + Dublin temperature, returns one wide table
keyed on `ts_utc` with columns named per station.

A failure on any single station logs a warning and is replaced with an
all-NaN placeholder so downstream feature engineering (which references each
station by name, e.g. `temp_dublin`) doesn't crash.
"""
function fetch_metereann_panel(start_date::Date, end_date::Date)
    out = nothing
    for (name, sid) in pairs(ME_STATIONS)
        df = try
            fetch_metereann_station(sid, start_date, end_date)
        catch e
            @warn "Met Éireann station $(name) (id $sid) fetch failed; using NaN placeholder" exception=(e, catch_backtrace())
            DataFrame(
                ts_utc     = DateTime[],
                wind_speed = Float64[],
                wind_dir   = Float64[],
                temp       = Float64[],
                pressure   = Float64[],
            )
        end
        rename!(df,
            :wind_speed => Symbol("wind_$(name)"),
            :wind_dir   => Symbol("winddir_$(name)"),
            :temp       => Symbol("temp_$(name)"),
            :pressure   => Symbol("pressure_$(name)"),
        )
        out = out === nothing ? df : outerjoin(out, df, on = :ts_utc)
    end
    # Ensure every expected station column exists even if a station returned
    # an empty df and the outer-join dropped it.
    for (name, _) in pairs(ME_STATIONS)
        for prefix in ("wind_", "winddir_", "temp_", "pressure_")
            col = Symbol("$(prefix)$(name)")
            if !(col in propertynames(out))
                out[!, col] = fill(NaN, nrow(out))
            end
        end
    end
    sort!(out, :ts_utc)
    return out
end

# ---------------------------------------------------------------------------
# Synthetic weather (always available)
# ---------------------------------------------------------------------------

"""
    synthetic_weather(start_date, end_date; seed = 23) -> DataFrame

Generates hourly weather at the five Met Éireann coastal stations + Dublin
temperature. The stations are correlated (same Atlantic systems) but
geographically dispersed so an Atlantic front arrives at Mace Head first,
Malin Head a few hours later, Valentia in parallel, Roches Point trailing.

This series is then **consumed** by `Entsoe.synthetic_dataset` to drive the
realised IE wind generation and the wind-forecast error — making the
weather features genuinely causal in the synthetic backtest.

Columns: `ts_utc`, `wind_mace_head`, `wind_belmullet`, `wind_malin_head`,
`wind_valentia`, `wind_roches_point`, `winddir_mace_head`, `temp_dublin`,
`pressure_gradient` (Valentia − Malin, hPa).
"""
function synthetic_weather(start_date::Date, end_date::Date; seed::Int = 23)
    rng = MersenneTwister(seed)
    n_days = Dates.value(end_date - start_date)
    n = n_days * 24
    ts = [DateTime(start_date) + Hour(i) for i in 0:n-1]

    # Underlying synoptic wind regime: slow OU process at the day scale.
    regime = Vector{Float64}(undef, n)
    regime[1] = 0.0
    for i in 2:n
        # Mean-reverting toward 0 with seasonal modulation: winter regime
        # has higher mean wind.
        seasonal = 5.0 * sin(2π * (i / (24 * 365.25) - 0.05))
        regime[i] = 0.96 * regime[i-1] + 0.04 * seasonal + 2.0 * randn(rng)
    end

    # Station-specific phase shifts (hours) — Atlantic fronts hit west first.
    function _shifted(arr, shift_hours)
        out = similar(arr)
        for i in 1:length(arr)
            j = clamp(i - shift_hours, 1, length(arr))
            out[i] = arr[j]
        end
        return out
    end

    wind_mace     = max.(0.0, 12.0 .+ _shifted(regime, 0)  .+ 2.5 .* randn(rng, n))
    wind_belmul   = max.(0.0, 13.0 .+ _shifted(regime, 1)  .+ 2.7 .* randn(rng, n))
    wind_malin    = max.(0.0, 11.0 .+ _shifted(regime, 3)  .+ 2.8 .* randn(rng, n))
    wind_valentia = max.(0.0, 11.5 .+ _shifted(regime, 0)  .+ 2.6 .* randn(rng, n))
    wind_roches   = max.(0.0,  9.0 .+ _shifted(regime, 2)  .+ 2.5 .* randn(rng, n))

    # Wind direction at Mace Head: prevailing southwesterly with some swing.
    wind_dir_mace = mod.(220.0 .+ 40.0 .* sin.(2π .* (1:n) ./ (24 * 5)) .+
                         20.0 .* randn(rng, n), 360.0)

    # Temperature at Dublin: annual cycle + diurnal cycle + AR(1) noise.
    t_seasonal = [9.0 + 6.5 * sin(2π * (i / (24 * 365.25) - 0.25)) for i in 1:n]
    t_diurnal  = [3.0 * sin(2π * (mod(i, 24) - 4) / 24) for i in 1:n]
    t_noise    = Vector{Float64}(undef, n)
    t_noise[1] = 0.0
    for i in 2:n
        t_noise[i] = 0.85 * t_noise[i-1] + 1.5 * randn(rng)
    end
    temp_dub = t_seasonal .+ t_diurnal .+ t_noise

    # Pressure gradient: synthetic but correlated with regime (high gradient
    # → high wind regime).
    pressure_grad = 4.0 .* regime ./ 5.0 .+ 1.5 .* randn(rng, n)

    return DataFrame(
        ts_utc           = ts,
        wind_mace_head   = wind_mace,
        wind_belmullet   = wind_belmul,
        wind_malin_head  = wind_malin,
        wind_valentia    = wind_valentia,
        wind_roches_point = wind_roches,
        winddir_mace_head = wind_dir_mace,
        temp_dublin       = temp_dub,
        pressure_gradient = pressure_grad,
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
