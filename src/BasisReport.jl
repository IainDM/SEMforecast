module BasisReport

using Dates
using DataFrames
using Statistics
using Printf
using JSON3
using CSV
using Plots

using ..Config
using ..BasisBacktest
using ..Conformal

ENV["GKSwstype"] = "100"
gr()

"""
    write_report(results; outdir = nothing, alpha = 0.2) -> String

Writes the basis-prediction backtest artifacts:
  metrics.json, per_hour.csv, coverage_curve.csv,
  calibration_intervals.png, confidence_vs_accuracy.png,
  predicted_vs_actual.png, basis_timeseries.png, README.md
"""
function write_report(results::DataFrame;
                      outdir::Union{Nothing,AbstractString} = nothing,
                      alpha::Float64 = 0.2)
    Config.ensure_dirs()
    if outdir === nothing
        stamp = Dates.format(now(), "yyyy-mm-dd_HHMMSS")
        outdir = joinpath(Config.REPORTS_DIR, "basis_$stamp")
    end
    isdir(outdir) || mkpath(outdir)

    m = BasisBacktest.summary_metrics(results)
    per_h = BasisBacktest.per_hour_breakdown(results)
    cov   = BasisBacktest.coverage_curve(results)

    # JSON spec doesn't allow NaN; coerce to nothing (-> JSON null) so the
    # report is parseable even when zero signals were issued.
    _j(x) = (x isa Real && isnan(x)) ? nothing : x
    open(joinpath(outdir, "metrics.json"), "w") do io
        JSON3.pretty(io, Dict(
            "n_total"                  => m.n_total,
            "n_signal"                 => m.n_signal,
            "signal_rate"              => _j(m.signal_rate),
            "selective_accuracy"       => _j(m.selective_accuracy),
            "selective_mae"            => _j(m.selective_mae),
            "q_mid_mae_all"            => _j(m.q_mid_mae_all),
            "abstain_basis_mean_abs"   => _j(m.abstain_basis_mean),
            "signal_basis_mean_abs"    => _j(m.signal_basis_mean),
            "interval_coverage"        => _j(m.interval_coverage),
            "interval_target_coverage" => 1 - alpha,
            "mean_interval_width"      => _j(m.mean_interval_width),
            "baseline_zero_mae"        => _j(m.baseline_zero_mae),
            "baseline_lag_mae"         => _j(m.baseline_lag_mae),
            "baseline_zero_signal_mae" => _j(m.baseline_zero_signal_mae),
            "selective_skill"          => _j(m.selective_skill),
            "alpha"                    => alpha,
            "eval_start"               => string(minimum(results.date)),
            "eval_end"                 => string(maximum(results.date)),
        ))
    end

    CSV.write(joinpath(outdir, "per_hour.csv"), per_h)
    CSV.write(joinpath(outdir, "coverage_curve.csv"), cov)

    _plot_basis_timeseries(results, outdir)
    _plot_predicted_vs_actual(results, outdir)
    _plot_calibration_intervals(results, outdir, alpha)
    _plot_confidence_vs_accuracy(cov, outdir)

    open(joinpath(outdir, "README.md"), "w") do io
        write(io, _markdown_summary(m, per_h, cov, results, alpha))
    end
    return outdir
end

function _plot_basis_timeseries(results::DataFrame, outdir::String)
    last_cut = maximum(results.date) - Day(14)
    tail = results[results.date .>= last_cut, :]
    nrow(tail) == 0 && return
    p = plot(tail.ts_local, tail.basis;
             label = "actual basis (ISP − DA)", lw = 1.6, color = :black,
             xlabel = "time (local)", ylabel = "€/MWh",
             title = "Basis: actual vs predicted (last 14 days)",
             size = (1100, 420), legend = :topright)
    plot!(p, tail.ts_local, tail.q_mid;
          label = "q50 (median forecast)", lw = 1.2, color = :red)
    plot!(p, tail.ts_local, tail.cal_lo;
          label = "calibrated lower", lw = 0.8, color = :gray, ls = :dash)
    plot!(p, tail.ts_local, tail.cal_hi;
          label = "calibrated upper", lw = 0.8, color = :gray, ls = :dash)
    hline!(p, [0]; label = "", color = :blue, ls = :dot, alpha = 0.5)
    # Highlight signalled rows.
    up_mask   = tail.decision .== Conformal.UP
    down_mask = tail.decision .== Conformal.DOWN
    if any(up_mask)
        scatter!(p, tail.ts_local[up_mask], tail.basis[up_mask];
                 marker = (:utriangle, 5, :green), label = "UP signal")
    end
    if any(down_mask)
        scatter!(p, tail.ts_local[down_mask], tail.basis[down_mask];
                 marker = (:dtriangle, 5, :red), label = "DOWN signal")
    end
    savefig(p, joinpath(outdir, "basis_timeseries.png"))
end

function _plot_predicted_vs_actual(results::DataFrame, outdir::String)
    mask = results.decision .!= Conformal.ABSTAIN
    n = sum(mask)
    n == 0 && return
    sub = results[mask, :]
    minv = min(minimum(sub.q_mid), minimum(sub.basis))
    maxv = max(maximum(sub.q_mid), maximum(sub.basis))
    cols = [d == Conformal.UP ? :green : :red for d in sub.decision]
    p = scatter(sub.q_mid, sub.basis;
                marker_z = nothing, color = cols, alpha = 0.45, ms = 3,
                xlabel = "predicted basis q50 (€/MWh)",
                ylabel = "actual basis (€/MWh)",
                title = "Signalled rows only: q50 vs actual basis",
                legend = false, size = (700, 700))
    plot!(p, [minv, maxv], [minv, maxv]; color = :black, ls = :dash, label = "")
    hline!(p, [0]; color = :gray, ls = :dot, alpha = 0.7, label = "")
    vline!(p, [0]; color = :gray, ls = :dot, alpha = 0.7, label = "")
    savefig(p, joinpath(outdir, "predicted_vs_actual.png"))
end

function _plot_calibration_intervals(results::DataFrame, outdir::String, alpha::Float64)
    target = 1 - alpha
    nominal_levels = 0.5:0.05:0.99
    empirical = Float64[]
    # Sweep over interval shrinkage factors to get a calibration curve.
    for lvl in nominal_levels
        # Scale the calibrated interval around q_mid so the nominal width
        # corresponds to coverage level `lvl`. Use the ratio of inverse normal
        # quantiles as a rough scaling (independent of the model).
        scale = quantile_scale(lvl, target)
        lo = results.q_mid .- scale .* (results.q_mid .- results.cal_lo)
        hi = results.q_mid .+ scale .* (results.cal_hi .- results.q_mid)
        push!(empirical, mean((results.basis .>= lo) .& (results.basis .<= hi)))
    end
    p = plot(collect(nominal_levels), empirical;
             marker = :circle, lw = 1.5, color = :red,
             xlabel = "nominal coverage", ylabel = "empirical coverage",
             title = "Interval calibration", legend = false,
             size = (650, 600), xlim = (0.5, 1.0), ylim = (0.5, 1.0))
    plot!(p, collect(nominal_levels), collect(nominal_levels);
          color = :black, ls = :dash)
    scatter!(p, [target], [mean((results.basis .>= results.cal_lo) .&
                               (results.basis .<= results.cal_hi))];
             marker = (:star5, 10, :blue), label = "")
    savefig(p, joinpath(outdir, "calibration_intervals.png"))
end

# Rough scaling: ratio of normal quantiles. Works well enough since the
# calibrated interval is symmetric-ish around q_mid after CQR.
function quantile_scale(target_lvl::Float64, base_lvl::Float64)
    # Normal CDF inverse approximation (Beasley-Springer-Moro is overkill;
    # use a 5-term Pade for both levels).
    z(p) = let q = p - 0.5; q == 0 ? 0.0 :
        2 * q * (2.515517 + 0.802853 * abs(q) + 0.010328 * q^2) /
        (1 + 1.432788 * abs(q) + 0.189269 * q^2 + 0.001308 * abs(q)^3)
    end
    # We need the half-interval at level `lvl`: z((1 + lvl)/2)
    return z((1 + target_lvl) / 2) / max(z((1 + base_lvl) / 2), 1e-6)
end

function _plot_confidence_vs_accuracy(cov::DataFrame, outdir::String)
    nrow(cov) == 0 && return
    # Drop rows where no signals were issued (accuracy is NaN).
    sub = cov[.!isnan.(cov.selective_accuracy), :]
    nrow(sub) == 0 && return
    p = plot(sub.signal_rate, sub.selective_accuracy;
             marker = :circle, lw = 1.5, color = :red,
             xlabel = "fraction of rows signalled",
             ylabel = "accuracy when signalling",
             title = "Signal-rate vs accuracy (varying interval scale)",
             ylim = (0.4, 1.0), legend = false, size = (700, 500))
    hline!(p, [0.5]; color = :gray, ls = :dot, alpha = 0.7)
    # Star the native rule (scale = 1.0) if present.
    native_row = findfirst(s -> abs(s - 1.0) < 1e-9, sub.scale)
    if native_row !== nothing
        scatter!(p, [sub.signal_rate[native_row]], [sub.selective_accuracy[native_row]];
                 marker = (:star5, 12, :blue), label = "")
    end
    savefig(p, joinpath(outdir, "confidence_vs_accuracy.png"))
end

function _markdown_summary(m, per_h, cov, results, alpha)
    head = """
    # SEM Basis (ISP − DA) Selective Forecast

    **Evaluation window:** $(minimum(results.date)) → $(maximum(results.date))
    **Total rows:** $(m.n_total)
    **Target coverage (1 − α):** $(@sprintf("%.0f%%", 100 * (1 - alpha)))

    Predicts the spread between the SEM imbalance settlement price (ISP,
    hourly average of the two half-hour periods) and the day-ahead price
    (DAM). Outputs three quantiles (q10, q50, q90) per hour; CQR-calibrates
    the q10–q90 interval to the nominal coverage; signals UP/DOWN only when
    the calibrated interval clears zero, otherwise abstains.

    ## Headline numbers

    | Metric | Value |
    |---|---:|
    | Signal rate (fraction of rows acted on) | $(@sprintf("%.1f%%", 100 * m.signal_rate)) |
    | **Selective accuracy (correct sign when signalling)** | $(@sprintf("%.1f%%", 100 * m.selective_accuracy)) |
    | Selective MAE (q50 error, signalled rows)    | $(@sprintf("%.2f €/MWh", m.selective_mae)) |
    | q50 MAE over ALL rows                         | $(@sprintf("%.2f €/MWh", m.q_mid_mae_all)) |
    | Mean \\|basis\\| when we signalled           | $(@sprintf("%.2f €/MWh", m.signal_basis_mean)) |
    | Mean \\|basis\\| when we abstained           | $(@sprintf("%.2f €/MWh", m.abstain_basis_mean)) |
    | Empirical interval coverage  | $(@sprintf("%.1f%%", 100 * m.interval_coverage)) (target $(@sprintf("%.0f%%", 100 * (1 - alpha)))) |
    | Mean interval width (sharpness)              | $(@sprintf("%.2f €/MWh", m.mean_interval_width)) |
    | Baseline 1: \"ISP = DA\" MAE (full window)    | $(@sprintf("%.2f €/MWh", m.baseline_zero_mae)) |
    | Baseline 2: lagged-basis MAE (full window)    | $(@sprintf("%.2f €/MWh", m.baseline_lag_mae)) |
    | Selective skill vs zero-baseline on same rows | $(@sprintf("%+.1f%%", 100 * m.selective_skill)) |

    ## Interpretation

    - **Selective accuracy** is the most important number. With the abstention
      rule "don't act unless the calibrated $(@sprintf("%.0f%%", 100*(1-alpha))) interval clears zero", how
      often does the call go the right way? Anything above the no-skill
      baseline of 50% on signalled rows is genuine edge; the abstention
      keeps it from being diluted by the easy-to-miss cases.
    - **`abstain_basis_mean` < `signal_basis_mean`** is the sanity check
      that the model is abstaining on the right rows — small / ambiguous
      basis values, where saying \"not sure\" is honest.
    - **`interval_coverage` ≈ target** confirms the CQR calibration worked.
      Big drift either way means the held-out calibration set is too small
      or the basis distribution shifted faster than the retrain cadence.

    ## Per hour-of-day

    | Hour | n | signal rate | selective accuracy | selective MAE | interval coverage |
    |---:|---:|---:|---:|---:|---:|
    """
    rows = ""
    for r in eachrow(per_h)
        rows *= "| $(r.hour) | $(r.n) | " *
                "$(@sprintf("%.0f%%", 100 * r.signal_rate)) | " *
                (isnan(r.selective_accuracy) ? "n/a" : @sprintf("%.0f%%", 100 * r.selective_accuracy)) * " | " *
                (isnan(r.selective_mae) ? "n/a" : @sprintf("%.2f", r.selective_mae)) * " | " *
                "$(@sprintf("%.0f%%", 100 * r.interval_coverage)) |\n"
    end

    cov_section = """

    ## Signal-rate vs accuracy trade-off

    Sweeps an **interval-scale factor** that pivots the calibrated
    [cal_lo, cal_hi] around q_mid. `scale = 1.0` is the native CQR rule;
    smaller scale shrinks the interval → more signals, lower per-call
    coverage; larger scale is more conservative.

    | scale | empirical coverage | signal rate | selective accuracy | selective MAE |
    |---:|---:|---:|---:|---:|
    """
    cov_rows = ""
    for r in eachrow(cov)
        cov_rows *= "| $(@sprintf("%.2f", r.scale)) | " *
                    "$(@sprintf("%.0f%%", 100 * r.empirical_coverage)) | " *
                    "$(@sprintf("%.0f%%", 100 * r.signal_rate)) | " *
                    (isnan(r.selective_accuracy) ? "n/a" : @sprintf("%.0f%%", 100 * r.selective_accuracy)) * " | " *
                    (isnan(r.selective_mae) ? "n/a" : @sprintf("%.2f", r.selective_mae)) * " |\n"
    end

    tail = """

    ## Artifacts

    - `metrics.json` — machine-readable summary
    - `per_hour.csv` — per-hour breakdown
    - `coverage_curve.csv` — full interval-scale sweep
    - `basis_timeseries.png` — last 14 days, actual vs q50 with signal markers
    - `predicted_vs_actual.png` — q50 vs actual basis on signalled rows
      (only written if any signals were issued)
    - `calibration_intervals.png` — nominal vs empirical coverage curve
    - `confidence_vs_accuracy.png` — signal-rate vs accuracy trade-off
    """
    return head * rows * cov_section * cov_rows * tail
end

end # module
