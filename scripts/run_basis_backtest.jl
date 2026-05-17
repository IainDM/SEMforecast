#!/usr/bin/env julia
# Walk-forward backtest of the basis (ISP − DA) prediction model with
# conformal-calibrated selective abstention.
#
# Usage:
#   julia --project=. scripts/run_basis_backtest.jl --eval-start 2025-11-01
#   julia --project=. scripts/run_basis_backtest.jl --eval-start 2025-09-01 \
#         --alpha 0.2 --margin 0 --retrain-every 14 --verbose

using Pkg
Pkg.activate(normpath(joinpath(@__DIR__, "..")))

using ArgParse
using Dates
using DataFrames
using Logging
using Printf

using SEMforecast
using SEMforecast: Config, Entsoe, Commodities, Weather, Gb, ClimateIndices,
                   BasisFeatures, BasisBacktest, BasisReport, Conformal

function _try_load(loader::Function, name::AbstractString)
    try
        return loader(name)
    catch e
        @warn "$name not loadable ($e); proceeding without it"
        return nothing
    end
end

function parse_args_()
    s = ArgParseSettings(description = "Walk-forward backtest: basis (ISP − DA) with abstention")
    @add_arg_table! s begin
        "--eval-start";    arg_type = String; required = true;  help = "YYYY-MM-DD"
        "--eval-end";      arg_type = String; required = false; default = ""
        "--alpha";         arg_type = Float64; default = 0.2;   help = "miscoverage rate; coverage = 1-alpha"
        "--margin";        arg_type = Float64; default = 0.0;   help = "extra €/MWh buffer that the calibrated interval must clear zero by before we'll signal"
        "--retrain-every"; arg_type = Int;     default = 14
        "--calibration-days"; arg_type = Int;  default = 60
        "--initial-train-months"; arg_type = Int; default = 18
        "--verbose";       action = :store_true
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
    imb = Entsoe.load("imbalance_prices")
    com = Commodities.load("commodities")

    weather  = _try_load(Weather.load,        "weather")
    gb_price = _try_load(Gb.load,             "gb_da_prices")
    gb_wind  = _try_load(Gb.load,             "gb_wind_forecast")
    outages  = _try_load(Entsoe.load,         "outages")
    actuals  = _try_load(Entsoe.load,         "actuals")
    nao      = _try_load(ClimateIndices.load, "nao_index")

    panel = BasisFeatures.build_basis_panel(
        prices = prices, load = load, wind = wind, solar = solar,
        commodities = com, imbalance = imb,
        weather = weather, gb_price = gb_price, gb_wind = gb_wind,
        outages = outages, actuals = actuals, nao = nao,
    )
    @info "Basis panel assembled" rows=nrow(panel) date_range=(minimum(panel.date), maximum(panel.date))
    basis_stats = (
        mean = sum(panel.basis) / nrow(panel),
        std  = sqrt(sum((panel.basis .- sum(panel.basis)/nrow(panel)).^2) / nrow(panel)),
        min  = minimum(panel.basis), max = maximum(panel.basis),
    )
    @info "Basis distribution (whole sample)" basis_stats

    eval_start = Date(args["eval-start"])
    eval_end   = isempty(args["eval-end"]) ? nothing : Date(args["eval-end"])

    @info "Starting walk-forward basis backtest" eval_start eval_end alpha=args["alpha"] margin=args["margin"] retrain_every=args["retrain-every"]
    results = BasisBacktest.walk_forward(panel;
        eval_start = eval_start,
        eval_end = eval_end,
        initial_train_months = args["initial-train-months"],
        calibration_days = args["calibration-days"],
        retrain_every_days = args["retrain-every"],
        alpha = args["alpha"],
        margin = args["margin"],
        verbose = args["verbose"],
    )

    if nrow(results) == 0
        error("No basis backtest rows produced. Check eval-start vs available data.")
    end

    m = BasisBacktest.summary_metrics(results)
    @info "Basis backtest complete" n=m.n_total signals=m.n_signal accuracy=m.selective_accuracy coverage=m.interval_coverage

    outdir = BasisReport.write_report(results; alpha = args["alpha"])
    println()
    println("======================================================================")
    _fmt(x, fmt) = (x isa Real && isnan(x)) ? "n/a" : Printf.format(Printf.Format(fmt), x)
    @printf "Rows evaluated:        %d\n" m.n_total
    @printf "Signals issued:        %d  (%.1f%% of rows)\n" m.n_signal 100*m.signal_rate
    println("Selective accuracy:    $(_fmt(100*m.selective_accuracy, "%.1f%%"))   (target: anything >>50%%)")
    println("Selective MAE (q50):   $(_fmt(m.selective_mae, "%.2f €/MWh"))")
    println("Mean |basis| signal:   $(_fmt(m.signal_basis_mean, "%.2f €/MWh"))")
    println("Mean |basis| abstain:  $(_fmt(m.abstain_basis_mean, "%.2f €/MWh"))")
    @printf "Interval coverage:     %.1f%%  (target: %.0f%%)\n" 100*m.interval_coverage 100*(1-args["alpha"])
    @printf "Mean interval width:   %.2f €/MWh\n" m.mean_interval_width
    println("---")
    @printf "Baseline ISP=DA MAE:        %.2f €/MWh (full eval window)\n" m.baseline_zero_mae
    @printf "Baseline lagged-basis MAE:  %.2f €/MWh (full eval window)\n" m.baseline_lag_mae
    println("Selective skill vs zero:    $(_fmt(100*m.selective_skill, "%+.1f%%"))   (on signalled rows)")
    println("Report written to: $outdir")
    println("======================================================================")
end

main()
