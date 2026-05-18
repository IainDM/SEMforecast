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
        # All fetchers wrapped: keep going even if a single source breaks.
        function _safe(label, action)
            @info "Fetching $label"
            try
                action()
            catch e
                @warn "$label fetch failed ($e); skipping"
            end
        end
        _safe("ENTSO-E SEM day-ahead prices",   () -> Entsoe.save(Entsoe.fetch_day_ahead_prices(start_date, end_date), "dam_prices"))
        _safe("ENTSO-E SEM load forecast (IE)", () -> Entsoe.save(Entsoe.fetch_load_forecast(start_date, end_date),    "load_forecast"))
        _safe("ENTSO-E SEM wind forecast",      () -> Entsoe.save(Entsoe.fetch_wind_forecast(start_date, end_date),    "wind_forecast"))
        _safe("ENTSO-E SEM solar forecast",     () -> Entsoe.save(Entsoe.fetch_solar_forecast(start_date, end_date),   "solar_forecast"))
        _safe("ENTSO-E SEM actual load + wind (for rolling-MAE)",
              () -> Entsoe.save(Entsoe.fetch_actuals_panel(start_date, end_date),  "actuals"))
        # SEM does not publish imbalance settlement prices to ENTSO-E A85 —
        # the basis model can't be trained on real data without sourcing ISP
        # elsewhere (e.g. SEMO publication portal).
        @info "Skipping imbalance prices: SEM does not publish ISP to ENTSO-E A85"
        # SEM publishes generator unavailability via A80 (zipped XML) rather
        # than A77. Skipping until A80 fetcher is implemented.
        @info "Skipping outages: SEM uses A80 (ZIP) rather than A77; not yet implemented"
        _safe("ELEXON BMRS GB day-ahead prices",
              () -> Gb.save(Gb.fetch_gb_da_prices(start_date, end_date),       "gb_da_prices"))
        _safe("ELEXON BMRS GB wind forecast",
              () -> Gb.save(Gb.fetch_gb_wind_forecast(start_date, end_date),   "gb_wind_forecast"))
        _safe("Met Éireann coastal weather",
              () -> Weather.save(Weather.fetch_metereann_panel(start_date, end_date), "weather"))
        _safe("NOAA CPC NAO index",
              () -> ClimateIndices.save(ClimateIndices.nao_daily(start_date, end_date), "nao_index"))
        _safe("TTF gas + EUA carbon (Yahoo)",
              () -> Commodities.save(Commodities.daily_commodities(start_date, end_date), "commodities"))
    end

    @info "Done. Cache files written to $(Config.RAW_DIR) and $(Config.COMMODITIES_DIR)."
end

main()
