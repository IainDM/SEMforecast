module Baseline

using DataFrames

"""
    predict_baseline(df) -> Vector{Float64}

Naive "same hour yesterday" forecast: returns the value of `price_lag_24h`
for every row. This is the benchmark every other model must beat.
"""
function predict_baseline(df::DataFrame)
    return Float64.(df.price_lag_24h)
end

end # module
