module Report

using Dates
using DataFrames
using Statistics
using Printf
using JSON3
using CSV
using Plots

using ..Config
using ..Backtest

ENV["GKSwstype"] = "100"  # headless / offscreen rendering
gr()

"""
    write_report(results; outdir = nothing) -> String

Writes a full backtest report to disk and returns the output directory.
Includes metrics.json, per_hour_mae.csv, two PNG charts, and a markdown
README summarising the headline numbers.
"""
function write_report(results::DataFrame; outdir::Union{Nothing,AbstractString} = nothing)
    Config.ensure_dirs()
    if outdir === nothing
        stamp = Dates.format(now(), "yyyy-mm-dd_HHMMSS")
        outdir = joinpath(Config.REPORTS_DIR, "backtest_$stamp")
    end
    isdir(outdir) || mkpath(outdir)

    m = Backtest.summary_metrics(results)
    per_h = Backtest.per_hour_mae(results)

    # metrics.json
    open(joinpath(outdir, "metrics.json"), "w") do io
        JSON3.pretty(io, Dict(
            "n_observations"  => m.n,
            "baseline_mae"    => m.base_mae,
            "baseline_rmse"   => m.base_rmse,
            "baseline_smape"  => m.base_smape,
            "model_mae"       => m.mod_mae,
            "model_rmse"      => m.mod_rmse,
            "model_smape"     => m.mod_smape,
            "skill_score_mae" => m.skill,
            "eval_start"      => string(minimum(results.date)),
            "eval_end"        => string(maximum(results.date)),
        ))
    end

    # per-hour MAE
    CSV.write(joinpath(outdir, "per_hour_mae.csv"), per_h)

    # Chart 1: forecast vs actual, last 14 days
    last_cut = maximum(results.date) - Day(14)
    tail = results[results.date .>= last_cut, :]
    if nrow(tail) > 0
        p1 = plot(tail.ts_local, tail.price;
                  label = "actual", lw = 1.8, color = :black,
                  xlabel = "time (local)", ylabel = "€/MWh",
                  title = "SEM DAM: actual vs forecast (last 14 days)",
                  legend = :topright, size = (1000, 400))
        plot!(p1, tail.ts_local, tail.baseline_pred;
              label = "naive D-1", lw = 1.0, color = :gray, alpha = 0.7)
        plot!(p1, tail.ts_local, tail.model_pred;
              label = "model", lw = 1.2, color = :red, alpha = 0.85)
        savefig(p1, joinpath(outdir, "forecast_vs_actual.png"))
    end

    # Chart 2: daily MAE time-series
    daily = combine(groupby(results, :date),
        [:baseline_pred, :price] => ((b, p) -> Backtest.mae(b, p)) => :baseline_mae,
        [:model_pred,    :price] => ((m, p) -> Backtest.mae(m, p)) => :model_mae,
    )
    sort!(daily, :date)
    if nrow(daily) > 0
        p2 = plot(daily.date, daily.baseline_mae;
                  label = "naive D-1", lw = 1.2, color = :gray,
                  xlabel = "date", ylabel = "MAE (€/MWh)",
                  title = "Daily MAE over backtest period",
                  size = (1000, 400))
        plot!(p2, daily.date, daily.model_mae;
              label = "model", lw = 1.4, color = :red)
        savefig(p2, joinpath(outdir, "daily_mae_timeseries.png"))
    end

    # Chart 3: per-hour MAE (two overlaid bars per hour, offset on x)
    if nrow(per_h) > 0
        p3 = bar(per_h.hour .- 0.2, per_h.baseline_mae;
                 bar_width = 0.4, label = "naive D-1", color = :gray,
                 xlabel = "hour of day", ylabel = "MAE (€/MWh)",
                 title = "Per-hour MAE",
                 size = (1000, 400))
        bar!(p3, per_h.hour .+ 0.2, per_h.model_mae;
             bar_width = 0.4, label = "model", color = :red)
        savefig(p3, joinpath(outdir, "per_hour_mae.png"))
    end

    # README summary
    open(joinpath(outdir, "README.md"), "w") do io
        write(io, _markdown_summary(m, per_h, results))
    end

    return outdir
end

function _markdown_summary(m, per_h, results)
    head = """
    # SEM DAM Forecast Backtest

    **Evaluation window:** $(minimum(results.date)) → $(maximum(results.date))
    **Observations:** $(m.n)

    ## Headline metrics

    | Metric | Naive D-1 | Model | Δ |
    |---|---:|---:|---:|
    | MAE (€/MWh)  | $(@sprintf("%.2f", m.base_mae))  | $(@sprintf("%.2f", m.mod_mae))  | $(@sprintf("%+.2f", m.mod_mae - m.base_mae)) |
    | RMSE (€/MWh) | $(@sprintf("%.2f", m.base_rmse)) | $(@sprintf("%.2f", m.mod_rmse)) | $(@sprintf("%+.2f", m.mod_rmse - m.base_rmse)) |
    | sMAPE        | $(@sprintf("%.3f", m.base_smape)) | $(@sprintf("%.3f", m.mod_smape)) | $(@sprintf("%+.3f", m.mod_smape - m.base_smape)) |

    **Skill score (MAE):** $(@sprintf("%+.1f%%", 100 * m.skill))
    $(m.skill > 0 ? "✓ beats baseline" : "✗ does NOT beat baseline — investigate")

    ## Per hour-of-day MAE

    | Hour | Naive | Model | Δ |
    |---:|---:|---:|---:|
    """
    rows = ""
    for r in eachrow(per_h)
        rows *= "| $(r.hour) | $(@sprintf("%.2f", r.baseline_mae)) | $(@sprintf("%.2f", r.model_mae)) | $(@sprintf("%+.2f", r.model_mae - r.baseline_mae)) |\n"
    end
    tail = """

    ## Artifacts

    - `metrics.json` — machine-readable summary
    - `per_hour_mae.csv` — per-hour breakdown
    - `forecast_vs_actual.png` — last 14 days, model + baseline vs actual
    - `daily_mae_timeseries.png` — daily MAE over the whole window
    - `per_hour_mae.png` — per-hour MAE bars
    """
    return head * rows * tail
end

end # module
