module Conformal

using DataFrames
using Statistics

using ..QuantileModel

# Decision symbols.
const UP     = :up
const DOWN   = :down
const ABSTAIN = :abstain

"""
    cqr_calibrate(q_lo_cal, q_hi_cal, y_cal; alpha = 0.2) -> Float64

Split-conformal Quantile Regression calibration constant (Romano et al. 2019).

Given the lower/upper quantile predictions on a calibration set and the true
targets, returns `q_hat` such that the calibrated interval
`[q_lo - q_hat, q_hi + q_hat]` has marginal coverage at least `1 - alpha`
on exchangeable data.

`alpha` is the miscoverage rate of the *interval* (default 0.2 → 80%
coverage). It is NOT the quantile level — those are fixed by the underlying
quantile model (typically 0.1 / 0.9).
"""
function cqr_calibrate(q_lo_cal::AbstractVector, q_hi_cal::AbstractVector,
                       y_cal::AbstractVector; alpha::Float64 = 0.2)
    n = length(y_cal)
    @assert length(q_lo_cal) == n == length(q_hi_cal)
    scores = max.(q_lo_cal .- y_cal, y_cal .- q_hi_cal)
    # The (1 - alpha) quantile, with the +1 correction for finite-sample
    # exchangeable coverage guarantee.
    level = min(1.0, ceil((n + 1) * (1 - alpha)) / n)
    return quantile(scores, level)
end

"""
    decide(q_lo, q_hi; q_hat = 0.0, margin = 0.0) -> Symbol, Float64

Selective decision rule for a single basis prediction.

- Calibrated interval: `[lo, hi] = [q_lo - q_hat, q_hi + q_hat]`.
- Signal UP if `lo > margin`.
- Signal DOWN if `hi < -margin`.
- Otherwise ABSTAIN.

Returns `(decision, confidence)` where `confidence` is the signed distance of
the nearer interval bound from 0 (positive for UP, negative for DOWN,
0 for ABSTAIN). Larger |confidence| = the interval sits further from zero
= more conservative call.

The optional `margin` arg lets callers require the interval to clear zero by
a hard buffer (in €/MWh) before signalling — useful when the user wants to
trade off coverage of signals vs accuracy more aggressively than CQR alone.
"""
function decide(q_lo::Real, q_hi::Real;
                q_hat::Float64 = 0.0,
                margin::Float64 = 0.0)
    lo = q_lo - q_hat
    hi = q_hi + q_hat
    if lo > margin
        return (UP, Float64(lo))
    elseif hi < -margin
        return (DOWN, Float64(hi))
    else
        return (ABSTAIN, 0.0)
    end
end

"""
    apply_decisions(q_lo, q_hi, q_mid; q_hat, margin) -> DataFrame

Vectorised version. Returns a DataFrame with columns
  cal_lo, cal_hi, q_mid, decision::Symbol, confidence::Float64
where cal_lo/cal_hi are the conformally-adjusted interval bounds.
"""
function apply_decisions(q_lo::AbstractVector, q_hi::AbstractVector,
                         q_mid::AbstractVector;
                         q_hat::Float64 = 0.0, margin::Float64 = 0.0)
    n = length(q_lo)
    cal_lo = q_lo .- q_hat
    cal_hi = q_hi .+ q_hat
    decisions  = Vector{Symbol}(undef, n)
    confidences = Vector{Float64}(undef, n)
    for i in 1:n
        d, c = decide(q_lo[i], q_hi[i]; q_hat = q_hat, margin = margin)
        decisions[i]   = d
        confidences[i] = c
    end
    return DataFrame(
        cal_lo     = cal_lo,
        cal_hi     = cal_hi,
        q_mid      = collect(q_mid),
        decision   = decisions,
        confidence = confidences,
    )
end

end # module
