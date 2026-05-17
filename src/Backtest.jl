module Backtest

using Dates
using DataFrames
using Statistics

using ..Features
using ..Baseline
using ..Model

"""
    walk_forward(panel; eval_start, eval_end = nothing,
                        initial_train_months = 18, retrain_every_days = 7,
                        verbose = false)

Walk-forward backtest. For each test date D in [eval_start, eval_end]:
  - Trains on all rows with date <= D - Day(2) (so D-1 prices are available
    as lag features but D's own data is unseen)
  - Predicts all hours of D with both the baseline and the model
  - Retrains every `retrain_every_days` days (uses the most recent fit
    between retrains)

Returns a DataFrame: ts_local, date, hour, price, baseline_pred, model_pred.
"""
function walk_forward(panel::DataFrame;
                      eval_start::Date,
                      eval_end::Union{Date,Nothing} = nothing,
                      initial_train_months::Int = 18,
                      retrain_every_days::Int = 7,
                      verbose::Bool = false)
    feat = Features.add_features(panel)
    sort!(feat, [:date, :hour])

    fc = Features.feature_columns(feat)

    test_end = eval_end === nothing ? maximum(feat.date) : eval_end
    test_dates = sort(unique(feat.date[(feat.date .>= eval_start) .&
                                       (feat.date .<= test_end)]))

    out_rows = DataFrame(
        ts_local      = DateTime[],
        date          = Date[],
        hour          = Int[],
        price         = Float64[],
        baseline_pred = Float64[],
        model_pred    = Float64[],
    )

    fitted_model = nothing
    last_retrain::Union{Date,Nothing} = nothing
    min_train_start = minimum(feat.date)
    initial_train_window = Day(initial_train_months * 30)

    for (k, d) in enumerate(test_dates)
        if fitted_model === nothing ||
           (d - last_retrain) >= Day(retrain_every_days)
            train_cutoff = d - Day(2)
            train_start = max(min_train_start, train_cutoff - initial_train_window)
            train = feat[(feat.date .>= train_start) .& (feat.date .<= train_cutoff), :]
            if nrow(train) < 24 * 30
                @warn "Skipping $d: insufficient training rows ($(nrow(train)))"
                continue
            end
            # Use last 21 days of train as the early-stopping eval window.
            eval_cut = train_cutoff - Day(21)
            train_in = train[train.date .<= eval_cut, :]
            train_ev = train[train.date .> eval_cut, :]
            verbose && @info "Retraining" date=d train_rows=nrow(train_in) eval_rows=nrow(train_ev)
            fitted_model = Model.fit(train_in, fc;
                                     eval_df = train_ev, verbose = false)
            last_retrain = d
        end

        test = feat[feat.date .== d, :]
        nrow(test) == 0 && continue
        bpred = Baseline.predict_baseline(test)
        mpred = Model.predict(fitted_model, test)
        for i in 1:nrow(test)
            ts = DateTime(test.date[i]) + Hour(test.hour[i])
            push!(out_rows, (
                ts, test.date[i], test.hour[i],
                Float64(test.price[i]), Float64(bpred[i]), Float64(mpred[i]),
            ))
        end

        if verbose && (k % 30 == 0)
            @info "Backtest progress" tested=k of=length(test_dates)
        end
    end
    return out_rows
end

# ---------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------

mae(yhat, y) = mean(abs.(yhat .- y))
rmse(yhat, y) = sqrt(mean((yhat .- y) .^ 2))

function smape(yhat, y)
    denom = (abs.(yhat) .+ abs.(y)) ./ 2
    valid = denom .> 1e-6
    sum(valid) == 0 && return NaN
    return mean(abs.(yhat[valid] .- y[valid]) ./ denom[valid])
end

"""
    summary_metrics(results) -> NamedTuple

Overall MAE/RMSE/sMAPE for baseline and model, plus the skill score.
"""
function summary_metrics(results::DataFrame)
    y = results.price
    bp = results.baseline_pred
    mp = results.model_pred
    base_mae, base_rmse, base_smape = mae(bp, y), rmse(bp, y), smape(bp, y)
    mod_mae,  mod_rmse,  mod_smape  = mae(mp, y), rmse(mp, y), smape(mp, y)
    skill = 1 - mod_mae / base_mae
    return (; base_mae, base_rmse, base_smape,
              mod_mae, mod_rmse, mod_smape, skill, n = nrow(results))
end

"""
    per_hour_mae(results) -> DataFrame

24-row breakdown of baseline vs model MAE by hour-of-day.
"""
function per_hour_mae(results::DataFrame)
    combine(groupby(results, :hour),
        [:baseline_pred, :price] => ((b, p) -> mae(b, p)) => :baseline_mae,
        [:model_pred,    :price] => ((m, p) -> mae(m, p)) => :model_mae,
    ) |> df -> sort!(df, :hour)
end

end # module
