module BasisBacktest

using Dates
using DataFrames
using Statistics

using ..BasisFeatures
using ..QuantileModel
using ..Conformal

"""
    walk_forward(panel; eval_start, eval_end = nothing,
                        initial_train_months = 18,
                        calibration_days = 60,
                        retrain_every_days = 14,
                        alpha = 0.2,
                        margin = 0.0,
                        verbose = false)

Walk-forward backtest of the basis-prediction model.

Per test date D the procedure is:
  1. Slice training data ending on D - Day(2). Hold out the last
     `calibration_days` days as the conformal calibration set; the rest is the
     quantile-fit set (further internally split — last 21 days reserved as the
     early-stopping eval window for EvoTrees).
  2. Fit quantile EvoTrees (q10, q50, q90) on the fit set.
  3. Predict on the calibration set, compute the CQR adjustment `q_hat` at
     coverage `1 - alpha`.
  4. Predict on day D and apply the selective decision rule
     (`Conformal.decide`) with the calibrated `q_hat` and optional `margin`.
  5. Retrain every `retrain_every_days` days; reuse the fitted model and
     `q_hat` between retrains.

Returns a DataFrame with one row per (date, hour) tested:
  ts_local, date, hour, da_price, isp, basis,
  q_lo, q_mid, q_hi, cal_lo, cal_hi, q_hat, decision, confidence,
  baseline_pred (zero — i.e. assume ISP = DA),
  baseline_lag_pred (use yesterday's basis at the same hour).
"""
function walk_forward(panel::DataFrame;
                      eval_start::Date,
                      eval_end::Union{Date,Nothing} = nothing,
                      initial_train_months::Int = 18,
                      calibration_days::Int = 60,
                      retrain_every_days::Int = 14,
                      alpha::Float64 = 0.2,
                      margin::Float64 = 0.0,
                      verbose::Bool = false)
    feat = BasisFeatures.add_basis_features(panel)
    sort!(feat, [:date, :hour])
    fc = BasisFeatures.basis_feature_columns(feat)

    test_end = eval_end === nothing ? maximum(feat.date) : eval_end
    test_dates = sort(unique(feat.date[(feat.date .>= eval_start) .&
                                       (feat.date .<= test_end)]))

    out = DataFrame(
        ts_local          = DateTime[],
        date              = Date[],
        hour              = Int[],
        da_price          = Float64[],
        isp               = Float64[],
        basis             = Float64[],
        q_lo              = Float64[],
        q_mid             = Float64[],
        q_hi              = Float64[],
        cal_lo            = Float64[],
        cal_hi            = Float64[],
        q_hat             = Float64[],
        decision          = Symbol[],
        confidence        = Float64[],
        baseline_pred     = Float64[],
        baseline_lag_pred = Float64[],
    )

    fitted = nothing
    q_hat::Float64 = 0.0
    last_retrain::Union{Date,Nothing} = nothing
    min_train_start = minimum(feat.date)
    initial_train_window = Day(initial_train_months * 30)

    for (k, d) in enumerate(test_dates)
        if fitted === nothing || (d - last_retrain) >= Day(retrain_every_days)
            train_cutoff = d - Day(2)
            train_start  = max(min_train_start, train_cutoff - initial_train_window)
            train_all = feat[(feat.date .>= train_start) .& (feat.date .<= train_cutoff), :]
            if nrow(train_all) < 24 * 90
                @warn "Skipping $d: not enough training rows ($(nrow(train_all)))"
                continue
            end
            # Hold out last calibration_days days as the calibration set.
            cal_start = train_cutoff - Day(calibration_days - 1)
            fit_part = train_all[train_all.date .<  cal_start, :]
            cal_part = train_all[train_all.date .>= cal_start, :]
            if nrow(cal_part) < 24 * 14
                @warn "Calibration set tiny at $d ($(nrow(cal_part)) rows); CQR adjustment will be noisy"
            end
            # Inside the fit set, reserve last 21 days as the early-stopping eval window.
            eval_cut = maximum(fit_part.date) - Day(21)
            fit_in = fit_part[fit_part.date .<= eval_cut, :]
            fit_ev = fit_part[fit_part.date .>  eval_cut, :]
            verbose && @info "Retraining basis model" date=d fit_rows=nrow(fit_in) eval_rows=nrow(fit_ev) cal_rows=nrow(cal_part)
            fitted = QuantileModel.fit(fit_in, fc;
                                       target = :basis,
                                       eval_df = fit_ev,
                                       verbose = false)
            # Calibrate.
            cal_pred = QuantileModel.predict(fitted, cal_part)
            q_hat = Conformal.cqr_calibrate(cal_pred.q_lo, cal_pred.q_hi,
                                            Float64.(cal_part.basis); alpha = alpha)
            last_retrain = d
            verbose && @info "Calibrated" q_hat
        end

        test = feat[feat.date .== d, :]
        nrow(test) == 0 && continue
        pred = QuantileModel.predict(fitted, test)
        decisions = Conformal.apply_decisions(pred.q_lo, pred.q_hi, pred.q_mid;
                                              q_hat = q_hat, margin = margin)

        for i in 1:nrow(test)
            ts = DateTime(test.date[i]) + Hour(test.hour[i])
            push!(out, (
                ts, test.date[i], test.hour[i],
                Float64(test.da_price[i]),
                Float64(test.isp[i]),
                Float64(test.basis[i]),
                Float64(pred.q_lo[i]),
                Float64(pred.q_mid[i]),
                Float64(pred.q_hi[i]),
                decisions.cal_lo[i],
                decisions.cal_hi[i],
                q_hat,
                decisions.decision[i],
                decisions.confidence[i],
                0.0,
                Float64(test.basis_lag_24h[i]),
            ))
        end

        if verbose && (k % 30 == 0)
            @info "Basis backtest progress" tested=k of=length(test_dates)
        end
    end
    return out
end

# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

mae(yhat, y) = mean(abs.(yhat .- y))

# Sign-classification accuracy with a "must beat zero" margin so we don't
# accidentally count near-zero basis values as correct hits.
function _direction_correct(decision::Symbol, basis::Float64; eps::Float64 = 0.0)
    if decision == Conformal.UP
        return basis > eps
    elseif decision == Conformal.DOWN
        return basis < -eps
    else
        return false  # abstained — never counted as correct in selective metrics
    end
end

"""
    summary_metrics(results; eps = 0.0) -> NamedTuple

`eps` is a tolerance (€/MWh) around zero below which an actual basis is
treated as a "tie" — only used for the directional accuracy on signals.

Returns:
  n_total      : rows in eval window
  n_signal     : rows where the model made a UP or DOWN call
  signal_rate  : n_signal / n_total
  selective_accuracy   : fraction of signals with correct sign (excluding ties)
  selective_mae        : MAE of q_mid vs basis, restricted to signalled rows
  abstain_basis_mean   : mean |basis| on rows where we abstained
  signal_basis_mean    : mean |basis| on rows where we signalled
  interval_coverage    : empirical coverage of the calibrated [cal_lo, cal_hi]
                         interval (target = 1 - alpha)
  mean_interval_width  : average interval width (sharpness)
  q_mid_mae_all        : MAE of q_mid vs basis on the full eval window
  baseline_zero_mae    : MAE of "ISP = DA" baseline (i.e. basis predicted 0)
  baseline_lag_mae     : MAE of "yesterday's basis at same hour" baseline
  selective_skill      : 1 - selective_mae / baseline_zero_signal_mae,
                         where the denominator is restricted to the same rows
                         (apples-to-apples).
"""
function summary_metrics(results::DataFrame; eps::Float64 = 0.0)
    n = nrow(results)
    signal_mask = results.decision .!= Conformal.ABSTAIN
    n_signal = sum(signal_mask)
    signal_rate = n == 0 ? 0.0 : n_signal / n

    # Directional accuracy on signals.
    correct = 0
    ties = 0
    for i in 1:n
        if signal_mask[i]
            if abs(results.basis[i]) <= eps
                ties += 1
                continue
            end
            _direction_correct(results.decision[i], results.basis[i]; eps = eps) && (correct += 1)
        end
    end
    eligible = n_signal - ties
    selective_accuracy = eligible == 0 ? NaN : correct / eligible

    # Magnitude error on signalled rows (using the median quantile q_mid).
    sel_idx = findall(signal_mask)
    abst_idx = findall(.!signal_mask)
    selective_mae = isempty(sel_idx) ? NaN : mae(results.q_mid[sel_idx], results.basis[sel_idx])
    q_mid_mae_all = n == 0 ? NaN : mae(results.q_mid, results.basis)

    # Means of |basis| on each subgroup — sanity check that abstentions
    # really do correspond to small/ambiguous basis.
    abstain_basis_mean = isempty(abst_idx) ? NaN : mean(abs.(results.basis[abst_idx]))
    signal_basis_mean  = isempty(sel_idx)  ? NaN : mean(abs.(results.basis[sel_idx]))

    # Interval coverage and sharpness.
    inside = (results.basis .>= results.cal_lo) .& (results.basis .<= results.cal_hi)
    interval_coverage = n == 0 ? NaN : mean(inside)
    mean_interval_width = n == 0 ? NaN : mean(results.cal_hi .- results.cal_lo)

    # Baselines.
    baseline_zero_mae = n == 0 ? NaN : mae(results.baseline_pred, results.basis)
    baseline_lag_mae  = n == 0 ? NaN : mae(results.baseline_lag_pred, results.basis)
    # Apples-to-apples: on the SAME rows the model chose to signal, how would
    # "always predict 0" have done?
    baseline_zero_signal_mae = isempty(sel_idx) ? NaN : mae(zeros(length(sel_idx)), results.basis[sel_idx])
    selective_skill = (isnan(selective_mae) || isnan(baseline_zero_signal_mae) || baseline_zero_signal_mae == 0) ?
                      NaN : (1 - selective_mae / baseline_zero_signal_mae)

    return (;
        n_total = n,
        n_signal,
        signal_rate,
        selective_accuracy,
        selective_mae,
        q_mid_mae_all,
        abstain_basis_mean,
        signal_basis_mean,
        interval_coverage,
        mean_interval_width,
        baseline_zero_mae,
        baseline_lag_mae,
        baseline_zero_signal_mae,
        selective_skill,
    )
end

"""
    per_hour_breakdown(results) -> DataFrame

Per hour-of-day: signal_rate, selective_accuracy, selective_mae,
interval_coverage. Useful for spotting hours where the model is over- or
under-confident.
"""
function per_hour_breakdown(results::DataFrame)
    combine(groupby(results, :hour),
        nrow => :n,
        :decision => (d -> mean(d .!= Conformal.ABSTAIN)) => :signal_rate,
        [:decision, :basis] => ((d, b) -> begin
            mask = d .!= Conformal.ABSTAIN
            sum(mask) == 0 && return NaN
            correct = sum(@. (d[mask] == Conformal.UP   && b[mask] > 0) |
                            (d[mask] == Conformal.DOWN && b[mask] < 0))
            return correct / sum(mask)
        end) => :selective_accuracy,
        [:q_mid, :basis, :decision] => ((m, b, d) -> begin
            mask = d .!= Conformal.ABSTAIN
            sum(mask) == 0 ? NaN : mae(m[mask], b[mask])
        end) => :selective_mae,
        [:basis, :cal_lo, :cal_hi] => ((b, l, h) -> mean((b .>= l) .& (b .<= h))) => :interval_coverage,
    ) |> df -> sort!(df, :hour)
end

"""
    coverage_curve(results; scales = nothing) -> DataFrame

Trade-off curve. Sweeps an interval-scale factor `s` ∈ [0, 1.5] that pivots
the calibrated interval around q_mid:

    new_lo = q_mid - s · (q_mid − cal_lo)
    new_hi = q_mid + s · (cal_hi − q_mid)

`s = 1.0` is the native CQR rule (calibrated to 1−α coverage). Smaller `s`
shrinks the interval → more signals, lower empirical coverage, usually
lower accuracy. Larger `s` is more conservative.

This is the right knob when α = 0.2 leaves the model abstaining always:
shrink the interval to extract signal at lower per-call confidence and
inspect the accuracy/signal-rate trade-off.

Returns columns: scale, signal_rate, selective_accuracy, selective_mae,
empirical_coverage (of the rescaled interval).
"""
function coverage_curve(results::DataFrame;
                        scales::AbstractVector{<:Real} =
                            [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9,
                             1.0, 1.1, 1.25, 1.5])
    rows = NamedTuple[]
    for s in scales
        lo = results.q_mid .- s .* (results.q_mid .- results.cal_lo)
        hi = results.q_mid .+ s .* (results.cal_hi .- results.q_mid)
        new_decision = [lo[i] > 0 ? Conformal.UP :
                        (hi[i] < 0 ? Conformal.DOWN : Conformal.ABSTAIN)
                        for i in 1:nrow(results)]
        signal_mask = new_decision .!= Conformal.ABSTAIN
        sigrate = mean(signal_mask)
        emp_cov = mean((results.basis .>= lo) .& (results.basis .<= hi))
        if any(signal_mask)
            correct = 0; eligible = 0
            for i in 1:nrow(results)
                signal_mask[i] || continue
                eligible += 1
                if (new_decision[i] == Conformal.UP   && results.basis[i] > 0) ||
                   (new_decision[i] == Conformal.DOWN && results.basis[i] < 0)
                    correct += 1
                end
            end
            acc = eligible == 0 ? NaN : correct / eligible
            sel_mae = mae(results.q_mid[signal_mask], results.basis[signal_mask])
        else
            acc = NaN
            sel_mae = NaN
        end
        push!(rows, (scale = Float64(s), signal_rate = sigrate,
                     selective_accuracy = acc, selective_mae = sel_mae,
                     empirical_coverage = emp_cov))
    end
    return DataFrame(rows)
end

end # module
