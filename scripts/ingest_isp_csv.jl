#!/usr/bin/env julia
# Ingest SEMO Imbalance Settlement Price CSVs into the Arrow cache that the
# basis backtest expects.
#
# SEM does NOT publish the Imbalance Settlement Price (ISP) to ENTSO-E A85,
# so the normal scripts/fetch_data.jl can't fill it. This script bridges the
# gap from a manual SEMO publication-portal download.
#
# How to get the source files:
#   1. Log in to https://reports.sem-o.com (or sem-o.com publication reports)
#   2. Find the Imbalance Settlement Price (or Market Imbalance Price) report
#   3. Download half-hourly CSVs for the date range you want
#   4. Drop them all in a directory, e.g. data/raw/isp_csvs/
#   5. Run:  julia --project=. scripts/ingest_isp_csv.jl --dir data/raw/isp_csvs
#
# Output: data/raw/imbalance_prices.arrow with columns
#   ts_utc :: DateTime  (UTC, hourly)
#   isp    :: Float64   (€/MWh, mean of the two half-hour periods)
#
# This matches the schema scripts/run_basis_backtest.jl expects.
#
# The script is column-name tolerant — most SEMO reports differ only in
# capitalisation and underscore placement. If your CSVs use a column that
# isn't recognised, pass --time-col / --price-col explicitly.

using Pkg
Pkg.activate(normpath(joinpath(@__DIR__, "..")))

using ArgParse
using CSV
using DataFrames
using Dates
using TimeZones
using Arrow
using Statistics
using Logging

using SEMforecast
using SEMforecast: Config

# ------------------------------------------------------------------
# Column-name detection (case-insensitive, underscores ignored)
# ------------------------------------------------------------------

_norm(s::AbstractString) = lowercase(replace(string(s), r"[_\s\-]" => ""))

const _TIME_CANDIDATES = ["starttime", "startdatetime", "starttimegmt",
                          "settlementperiodstarttime", "halfhourstarttime",
                          "deliverystart", "deliverystartutc", "tradingdatetime",
                          "datetime", "timestamp", "ts", "tsutc"]

const _PRICE_CANDIDATES = ["imbalancesettlementprice", "imbalanceprice",
                           "settlementprice", "marketimbalanceprice",
                           "isp", "price", "value", "imb_price"]

const _DATE_CANDIDATES = ["tradedate", "deliverydate", "efadate", "settlementdate",
                          "date", "tradingdate"]

const _PERIOD_CANDIDATES = ["periodofday", "settlementperiod", "halfhourperiod",
                            "efaperiod", "halfhour", "period"]

function _detect_column(df::DataFrame, candidates::Vector{String})
    cols = names(df)
    normalised = _norm.(cols)
    for cand in candidates
        i = findfirst(==(cand), normalised)
        i === nothing || return cols[i]
    end
    return nothing
end

# ------------------------------------------------------------------
# Time parsing
# ------------------------------------------------------------------

# Parse a string that might be "2025-01-01 00:30:00", "01/01/2025 00:30",
# ISO "2025-01-01T00:30:00", or with a trailing Z/offset.
function _parse_datetime_any(s::AbstractString)
    s = strip(s)
    isempty(s) && return missing
    # Strip trailing Z / timezone — we'll attach Dublin tz explicitly.
    s = replace(s, r"Z$" => "")
    s = replace(s, r"[+\-]\d{2}:?\d{2}$" => "")
    for fmt in (
        dateformat"yyyy-mm-dd HH:MM:SS",
        dateformat"yyyy-mm-dd HH:MM",
        dateformat"yyyy-mm-ddTHH:MM:SS",
        dateformat"yyyy-mm-ddTHH:MM",
        dateformat"dd/mm/yyyy HH:MM:SS",
        dateformat"dd/mm/yyyy HH:MM",
        dateformat"dd-mm-yyyy HH:MM:SS",
        dateformat"dd-mm-yyyy HH:MM",
    )
        try
            return DateTime(s, fmt)
        catch
        end
    end
    return missing
end

# SEMO half-hourly settlement period (1..48 or 1..50 on DST days) → minutes
# offset from local midnight. Period 1 covers 00:00–00:30 local time.
function _period_to_minutes(p::Integer)
    return (p - 1) * 30
end

# ------------------------------------------------------------------
# Per-file ingestion
# ------------------------------------------------------------------

"""
    ingest_file(path; time_col=nothing, price_col=nothing, tz=tz"Europe/Dublin")
        -> DataFrame(ts_utc::DateTime, isp::Float64)

Read one SEMO CSV into a half-hourly DataFrame in UTC. The time column is
parsed as local (Europe/Dublin) wall-clock time then converted to UTC; DST
transitions are handled by `TimeZones.jl`'s default behaviour (`first`).

If the file lacks a single datetime column but has separate date + period
columns, those are combined automatically.
"""
function ingest_file(path::AbstractString;
                     time_col::Union{Nothing,String} = nothing,
                     price_col::Union{Nothing,String} = nothing,
                     tz_local::TimeZone = tz"Europe/Dublin")
    df = CSV.read(path, DataFrame; comment = "#", missingstring = ["", "NA", "null"])
    nrow(df) == 0 && return DataFrame(ts_utc = DateTime[], isp = Float64[])

    tcol = time_col === nothing ? _detect_column(df, _TIME_CANDIDATES) : time_col
    pcol = price_col === nothing ? _detect_column(df, _PRICE_CANDIDATES) : price_col

    pcol === nothing && error("Could not detect ISP price column in $(basename(path)); columns=$(names(df))")

    local_ts = if tcol !== nothing
        # Single datetime column.
        map(x -> ismissing(x) ? missing : _parse_datetime_any(string(x)), df[!, tcol])
    else
        # Fall back to date + period.
        dcol = _detect_column(df, _DATE_CANDIDATES)
        prdcol = _detect_column(df, _PERIOD_CANDIDATES)
        (dcol === nothing || prdcol === nothing) &&
            error("Could not detect time/date+period columns in $(basename(path)); columns=$(names(df))")
        map(zip(df[!, dcol], df[!, prdcol])) do (d, p)
            (ismissing(d) || ismissing(p)) && return missing
            day = d isa Date ? d : Date(_parse_datetime_any(string(d) * " 00:00"))
            DateTime(day) + Minute(_period_to_minutes(Int(p)))
        end
    end

    # Coerce price to Float64 (CSV.read may give it as String for some
    # locale-quirky exports).
    raw_price = df[!, pcol]
    price = map(raw_price) do v
        ismissing(v) && return missing
        v isa Number && return Float64(v)
        s = strip(replace(string(v), "," => ""))
        isempty(s) && return missing
        try
            return parse(Float64, s)
        catch
            return missing
        end
    end

    out = DataFrame(local_ts = local_ts, isp = price)
    out = filter(r -> !ismissing(r.local_ts) && !ismissing(r.isp), out)
    isempty(out) && return DataFrame(ts_utc = DateTime[], isp = Float64[])

    # Convert local (Dublin) → UTC, default-tz strategy for DST ambiguity.
    out.ts_utc = map(out.local_ts) do dt
        zdt = try
            ZonedDateTime(dt, tz_local)
        catch err
            isa(err, AmbiguousTimeError) && return ZonedDateTime(dt, tz_local, 1)
            isa(err, NonExistentTimeError) && return missing
            rethrow()
        end
        return DateTime(astimezone(zdt, tz"UTC"))
    end
    out = filter(r -> !ismissing(r.ts_utc), out)
    return DataFrame(ts_utc = DateTime.(out.ts_utc), isp = Float64.(out.isp))
end

# ------------------------------------------------------------------
# Aggregate half-hourly to hourly mean
# ------------------------------------------------------------------

function aggregate_hourly(df::DataFrame)
    isempty(df) && return df
    sort!(df, :ts_utc)
    df.hour = floor.(df.ts_utc, Hour)
    g = combine(groupby(df, :hour), :isp => mean => :isp)
    rename!(g, :hour => :ts_utc)
    return g
end

# ------------------------------------------------------------------
# CLI
# ------------------------------------------------------------------

function parse_args_()
    s = ArgParseSettings(description =
        "Aggregate SEMO half-hourly Imbalance Settlement Price CSVs into Arrow.")
    @add_arg_table! s begin
        "--dir";    arg_type = String; required = true;  help = "Directory of *.csv files to ingest"
        "--out";    arg_type = String; required = false; default = "";
                    help = "Output Arrow path (defaults to data/raw/imbalance_prices.arrow)"
        "--time-col";  arg_type = String; required = false; default = "";
                       help = "Override time column name (otherwise auto-detected)"
        "--price-col"; arg_type = String; required = false; default = "";
                       help = "Override ISP column name (otherwise auto-detected)"
    end
    return parse_args(s)
end

function main()
    args = parse_args_()
    Config.ensure_dirs()
    dir = args["dir"]
    isdir(dir) || error("Not a directory: $dir")

    out_path = isempty(args["out"]) ?
        joinpath(Config.RAW_DIR, "imbalance_prices.arrow") : args["out"]

    files = sort(filter(f -> endswith(lowercase(f), ".csv"), readdir(dir; join = true)))
    isempty(files) && error("No .csv files in $dir")

    @info "Ingesting $(length(files)) SEMO ISP CSV(s) from $dir"
    chunks = DataFrame[]
    for f in files
        try
            df = ingest_file(f;
                time_col  = isempty(args["time-col"])  ? nothing : args["time-col"],
                price_col = isempty(args["price-col"]) ? nothing : args["price-col"],
            )
            @info "  $(basename(f)): $(nrow(df)) half-hourly rows"
            push!(chunks, df)
        catch e
            @warn "  $(basename(f)) failed; skipping" exception=e
        end
    end

    all_hh = isempty(chunks) ? DataFrame(ts_utc = DateTime[], isp = Float64[]) :
                                vcat(chunks...; cols = :union)
    @info "Combined half-hourly rows: $(nrow(all_hh))"

    hourly = aggregate_hourly(all_hh)
    @info "Aggregated hourly rows: $(nrow(hourly))"
    nrow(hourly) == 0 && error("No usable rows after ingest; check the source CSVs")

    Arrow.write(out_path, hourly)
    @info "Wrote $out_path" rows=nrow(hourly) span=(minimum(hourly.ts_utc), maximum(hourly.ts_utc))
end

main()
