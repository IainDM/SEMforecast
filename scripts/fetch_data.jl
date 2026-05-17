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
using SEMforecast: Config, Entsoe, Commodities, Weather, Gb, ClimateIndices

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
        @info "Generating synthetic weather (Met Éireann coastal + Dublin temp)"
        weather = Weather.synthetic_weather(start_date, end_date)
        Weather.save(weather, "weather")

        @info "Generating synthetic SEM dataset (weather-driven)" start_date end_date
        ds = Entsoe.synthetic_dataset(start_date, end_date; weather_df = weather)
        Entsoe.save(ds.prices,    "dam_prices")
        Entsoe.save(ds.load,      "load_forecast")
        Entsoe.save(ds.wind,      "wind_forecast")
        Entsoe.save(ds.solar,     "solar_forecast")
        Entsoe.save(ds.imbalance, "imbalance_prices")
        Entsoe.save(ds.actuals,   "actuals")
        Entsoe.save(ds.outages,   "outages")

        @info "Generating synthetic GB price + wind (Atlantic-correlated)"
        gb = Gb.synthetic_gb(start_date, end_date, weather)
        Gb.save(gb.price, "gb_da_prices")
        Gb.save(gb.wind,  "gb_wind_forecast")

        @info "Generating synthetic NAO (no NOAA fetch needed in synthetic mode)"
        ClimateIndices.save(
            ClimateIndices.synthetic_nao_daily(start_date, end_date), "nao_index")

        @info "Generating synthetic commodities"
        Commodities.save(Commodities.synthetic_commodities(start_date, end_date),
                         "commodities")
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
        @info "Fetching ENTSO-E SEM generator outages (A77)"
        try
            Entsoe.save(Entsoe.fetch_outages(start_date, end_date), "outages")
        catch e
            @warn "Outage fetch failed ($e); skipping (rerun once issue resolved)"
        end
        @info "Fetching ELEXON BMRS GB day-ahead prices"
        try
            Gb.save(Gb.fetch_gb_da_prices(start_date, end_date), "gb_da_prices")
        catch e
            @warn "GB price fetch failed ($e); skipping"
        end
        @info "Fetching ELEXON BMRS GB wind forecast"
        try
            Gb.save(Gb.fetch_gb_wind_forecast(start_date, end_date), "gb_wind_forecast")
        catch e
            @warn "GB wind fetch failed ($e); skipping"
        end
        @info "Fetching Met Éireann coastal weather"
        try
            Weather.save(Weather.fetch_metereann_panel(start_date, end_date), "weather")
        catch e
            @warn "Met Éireann fetch failed ($e); will fall back to no-weather features"
        end
        @info "Fetching NOAA CPC NAO index"
        try
            ClimateIndices.save(
                ClimateIndices.nao_daily(start_date, end_date), "nao_index")
        catch e
            @warn "NAO fetch failed ($e); skipping"
        end
        @info "Fetching TTF gas + EUA carbon (Yahoo Finance)"
        Commodities.save(Commodities.daily_commodities(start_date, end_date), "commodities")
    end

    @info "Done. Cache files written to $(Config.RAW_DIR) and $(Config.COMMODITIES_DIR)."
end

main()
