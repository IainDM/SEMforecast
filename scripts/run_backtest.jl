#!/usr/bin/env julia
# Run the walk-forward backtest and write a report folder.
#
# Usage:
#   julia --project=. scripts/run_backtest.jl --eval-start 2025-11-01

using Pkg
Pkg.activate(normpath(joinpath(@__DIR__, "..")))

using ArgParse
using Dates
using DataFrames
using Logging
using Printf

using SEMforecast
using SEMforecast: Config, Entsoe, Commodities, Features, Backtest, Report

function parse_args_()
    s = ArgParseSettings(description = "Walk-forward backtest")
    @add_arg_table! s begin
        "--eval-start";  arg_type = String; required = true;  help = "YYYY-MM-DD"
        "--eval-end";    arg_type = String; required = false; default = "";    help = "YYYY-MM-DD"
        "--retrain-every"; arg_type = Int;  default = 7;    help = "days"
        "--initial-train-months"; arg_type = Int; default = 18
        "--verbose";     action = :store_true
    end
    return parse_args(s)
end

function main()
    args = parse_args_()
    Config.load_dotenv()
    Config.ensure_dirs()

    @info "Loading cached data"
    prices = Entsoe.load("dam_prices")
    load   = Entsoe.load("load_forecast")
    wind   = Entsoe.load("wind_forecast")
    solar  = try
        Entsoe.load("solar_forecast")
    catch
        DataFrame(ts_utc = DateTime[], solar_fcst = Float64[])
    end
    com = Commodities.load("commodities")

    panel = Features.build_panel(prices = prices, load = load,
                                 wind = wind, solar = solar, commodities = com)
    @info "Panel assembled" rows=nrow(panel) date_range=(minimum(panel.date), maximum(panel.date))

    eval_start = Date(args["eval-start"])
    eval_end   = isempty(args["eval-end"]) ? nothing : Date(args["eval-end"])

    @info "Starting walk-forward backtest" eval_start eval_end retrain_every=args["retrain-every"]
    results = Backtest.walk_forward(panel;
        eval_start = eval_start,
        eval_end = eval_end,
        initial_train_months = args["initial-train-months"],
        retrain_every_days = args["retrain-every"],
        verbose = args["verbose"],
    )

    if nrow(results) == 0
        error("No backtest rows produced. Check eval-start vs available data.")
    end

    m = Backtest.summary_metrics(results)
    @info "Backtest complete" n=m.n base_mae=m.base_mae mod_mae=m.mod_mae skill=m.skill

    outdir = Report.write_report(results)
    println()
    println("======================================================================")
    @printf "Baseline (naive D-1) MAE: %.2f  RMSE: %.2f\n" m.base_mae m.base_rmse
    @printf "Model                MAE: %.2f  RMSE: %.2f\n" m.mod_mae m.mod_rmse
    @printf "Skill score (MAE):       %+.1f%%  %s\n" 100*m.skill (m.skill > 0 ? "✓" : "✗")
    println("Report written to: $outdir")
    println("======================================================================")
end

main()
