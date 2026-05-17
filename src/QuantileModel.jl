module QuantileModel

using DataFrames
using EvoTrees
using Statistics

using ..Config
using ..Model: matrix  # reuse the matrix conversion helper

# Quantile levels used everywhere downstream. Edit here if you want a different
# nominal coverage; conformal calibration will adjust to match the empirical
# coverage anyway, but tighter raw quantiles make the abstention rule kick in
# more often.
const QUANTILES = (lo = 0.1, mid = 0.5, hi = 0.9)

struct FittedQuantileModel
    booster_lo::Any
    booster_mid::Any
    booster_hi::Any
    feature_cols::Vector{Symbol}
    target::Symbol
end

# Build an EvoTreeRegressor at a specific quantile level.
function _config(alpha::Float64; nrounds::Int, eta::Float64, max_depth::Int,
                 min_weight::Float64, rowsample::Float64, colsample::Float64,
                 L2::Float64, early_stopping_rounds::Int, has_eval::Bool)
    return EvoTreeRegressor(
        loss       = :quantile,
        alpha      = alpha,
        nrounds    = nrounds,
        eta        = eta,
        max_depth  = max_depth,
        min_weight = min_weight,
        rowsample  = rowsample,
        colsample  = colsample,
        L2         = L2,
        early_stopping_rounds = has_eval ? early_stopping_rounds : typemax(Int),
    )
end

"""
    fit(train_df, feature_cols; target = :basis, eval_df = nothing, hp = nothing)

Fits three quantile EvoTrees at QUANTILES.lo / .mid / .hi. Uses early stopping
when `eval_df` is provided.

Defaults to lighter hyperparameters than the DAM regression model — quantile
loss is noisier and overfits more easily, so depth and rounds are reduced.
"""
function fit(train_df::DataFrame, feature_cols::Vector{Symbol};
             target::Symbol = :basis,
             eval_df::Union{Nothing,DataFrame} = nothing,
             nrounds::Int = 800,
             eta::Float64 = 0.04,
             max_depth::Int = 6,
             min_weight::Float64 = 30.0,
             rowsample::Float64 = 0.8,
             colsample::Float64 = 0.8,
             L2::Float64 = 1.0,
             early_stopping_rounds::Int = 80,
             verbose::Bool = false)
    has_eval = eval_df !== nothing && nrow(eval_df) > 0
    x_train = matrix(train_df, feature_cols)
    y_train = Float32.(train_df[!, target])
    x_eval = has_eval ? matrix(eval_df, feature_cols) : nothing
    y_eval = has_eval ? Float32.(eval_df[!, target]) : nothing

    function _fit(alpha)
        cfg = _config(alpha; nrounds, eta, max_depth, min_weight,
                      rowsample, colsample, L2, early_stopping_rounds, has_eval)
        kwargs = Dict{Symbol,Any}(
            :x_train => x_train, :y_train => y_train,
            :feature_names => string.(feature_cols),
            :print_every_n => verbose ? 100 : typemax(Int),
            :verbosity => verbose ? 1 : 0,
        )
        if has_eval
            kwargs[:x_eval] = x_eval
            kwargs[:y_eval] = y_eval
        end
        return EvoTrees.fit(cfg; kwargs...)
    end

    b_lo  = _fit(QUANTILES.lo)
    b_mid = _fit(QUANTILES.mid)
    b_hi  = _fit(QUANTILES.hi)
    return FittedQuantileModel(b_lo, b_mid, b_hi, feature_cols, target)
end

"""
    predict(model, df) -> NamedTuple{(:q_lo, :q_mid, :q_hi)}

Returns the three quantile predictions for every row. Crossing quantiles are
clamped in-place: q_lo <= q_mid <= q_hi after a `_sort_quantiles!` step.
"""
function predict(model::FittedQuantileModel, df::DataFrame)
    x = matrix(df, model.feature_cols)
    q_lo  = Float64.(EvoTrees.predict(model.booster_lo,  x))
    q_mid = Float64.(EvoTrees.predict(model.booster_mid, x))
    q_hi  = Float64.(EvoTrees.predict(model.booster_hi,  x))
    _sort_quantiles!(q_lo, q_mid, q_hi)
    return (; q_lo, q_mid, q_hi)
end

# Quantile crossing can happen because the three regressors are fit independently.
# Cheapest fix: sort each row's three predictions.
function _sort_quantiles!(q_lo, q_mid, q_hi)
    @inbounds for i in eachindex(q_lo)
        a, b, c = q_lo[i], q_mid[i], q_hi[i]
        # 3-element sort.
        if a > b; a, b = b, a; end
        if b > c; b, c = c, b; end
        if a > b; a, b = b, a; end
        q_lo[i], q_mid[i], q_hi[i] = a, b, c
    end
    return nothing
end

end # module
