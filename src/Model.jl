module Model

using DataFrames
using EvoTrees
using Statistics

using ..Config

# ---------------------------------------------------------------------------
# DataFrame -> matrix conversion
# ---------------------------------------------------------------------------

"""
    matrix(df, cols) -> Matrix{Float32}

Converts a subset of columns to a numeric matrix. Missing values are replaced
with the column mean (cheap imputation; fine because `dropmissing` upstream
removed rows lacking required features — only optional columns can have
missing values here).
"""
function matrix(df::DataFrame, cols::Vector{Symbol})
    n, p = nrow(df), length(cols)
    X = Matrix{Float32}(undef, n, p)
    for (j, c) in enumerate(cols)
        col = df[!, c]
        if eltype(col) <: Union{Missing,Real}
            v = collect(skipmissing(col))
            μ = isempty(v) ? 0.0f0 : Float32(mean(v))
            for i in 1:n
                X[i, j] = ismissing(col[i]) ? μ : Float32(col[i])
            end
        else
            for i in 1:n
                X[i, j] = Float32(col[i])
            end
        end
    end
    return X
end

# ---------------------------------------------------------------------------
# Fit / predict
# ---------------------------------------------------------------------------

struct FittedModel
    booster::Any                 # EvoTrees model
    feature_cols::Vector{Symbol}
end

"""
    fit(train_df, feature_cols; eval_df = nothing) -> FittedModel

Trains an EvoTrees regressor with the hyperparameters in `Config.MODEL_HP`.
Uses early stopping if `eval_df` is provided.
"""
function fit(train_df::DataFrame, feature_cols::Vector{Symbol};
             eval_df::Union{Nothing,DataFrame} = nothing,
             verbose::Bool = false)
    hp = Config.MODEL_HP
    has_eval = eval_df !== nothing && nrow(eval_df) > 0
    config = EvoTreeRegressor(
        loss        = hp.loss,
        nrounds     = hp.nrounds,
        eta         = hp.eta,
        max_depth   = hp.max_depth,
        min_weight  = hp.min_weight,
        rowsample   = hp.rowsample,
        colsample   = hp.colsample,
        L2          = hp.L2,
        early_stopping_rounds = has_eval ? hp.early_stopping_rounds : typemax(Int),
    )
    x_train = matrix(train_df, feature_cols)
    y_train = Float32.(train_df.price)

    kwargs = Dict{Symbol,Any}(
        :x_train => x_train, :y_train => y_train,
        :feature_names => string.(feature_cols),
        :print_every_n => verbose ? 100 : typemax(Int),
        :verbosity => verbose ? 1 : 0,
    )
    if has_eval
        kwargs[:x_eval] = matrix(eval_df, feature_cols)
        kwargs[:y_eval] = Float32.(eval_df.price)
    end

    booster = EvoTrees.fit(config; kwargs...)
    return FittedModel(booster, feature_cols)
end

"""
    predict(model, df) -> Vector{Float64}
"""
function predict(model::FittedModel, df::DataFrame)
    x = matrix(df, model.feature_cols)
    return Float64.(EvoTrees.predict(model.booster, x))
end

end # module
