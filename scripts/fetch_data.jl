#!/usr/bin/env julia
# Fetch ENTSO-E SEM data + commodity series and cache to data/.
#
# Usage:
#   julia --project=. scripts/fetch_data.jl --start 2022-01-01 --end 2026-05-01
#   julia --project=. scripts/fetch_data.jl --synthetic --start 2022-01-01 --end 2026-05-01

using Pkg
Pkg.activate(normpath(joinpath(@__DIR__, "..")))

using ArgParse
using Dates
using DataFrames
using Logging

using SEMforecast
using SEMforecast: Config, Entsoe, Commodities

function parse_args_()
    s = ArgParseSettings(description = "Fetch SEM data and cache to data/")
    @add_arg_table! s begin
        "--start";    arg_type = String;  required = true; help = "Start date YYYY-MM-DD"
        "--end";      arg_type = String;  required = true; help = "End date YYYY-MM-DD (exclusive)"
        "--synthetic"; action = :store_true;               help = "Use synthetic data (no API token needed)"
    end
    return parse_args(s)
end

function main()
    args = parse_args_()
    Config.load_dotenv()
    Config.ensure_dirs()

    start_date = Date(args["start"])
    end_date   = Date(args["end"])

    if args["synthetic"]
        @info "Generating synthetic SEM dataset" start_date end_date
        ds = Entsoe.synthetic_dataset(start_date, end_date)
        Entsoe.save(ds.prices,    "dam_prices")
        Entsoe.save(ds.load,      "load_forecast")
        Entsoe.save(ds.wind,      "wind_forecast")
        Entsoe.save(ds.solar,     "solar_forecast")
        Entsoe.save(ds.imbalance, "imbalance_prices")
        @info "Generating synthetic commodities"
        com = Commodities.synthetic_commodities(start_date, end_date)
        Commodities.save(com, "commodities")
    else
        @info "Fetching ENTSO-E SEM day-ahead prices"
        Entsoe.save(Entsoe.fetch_day_ahead_prices(start_date, end_date), "dam_prices")
        @info "Fetching ENTSO-E SEM load forecast"
        Entsoe.save(Entsoe.fetch_load_forecast(start_date, end_date),    "load_forecast")
        @info "Fetching ENTSO-E SEM wind forecast"
        Entsoe.save(Entsoe.fetch_wind_forecast(start_date, end_date),    "wind_forecast")
        @info "Fetching ENTSO-E SEM solar forecast"
        Entsoe.save(Entsoe.fetch_solar_forecast(start_date, end_date),   "solar_forecast")
        @info "Fetching ENTSO-E SEM imbalance settlement prices"
        Entsoe.save(Entsoe.fetch_imbalance_prices(start_date, end_date), "imbalance_prices")
        @info "Fetching TTF gas + EUA carbon (Yahoo Finance)"
        Commodities.save(Commodities.daily_commodities(start_date, end_date), "commodities")
    end

    @info "Done. Cache files written to $(Config.RAW_DIR) and $(Config.COMMODITIES_DIR)."
end

main()
