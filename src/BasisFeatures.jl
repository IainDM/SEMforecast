module BasisFeatures

using Dates
using TimeZones
using DataFrames
using Statistics

using ..Config
using ..Calendar
using ..Features

# Reuse Features._to_local for ISP series too. We re-implement here to avoid
# reaching into Features' private helpers.
function _to_local(df::DataFrame)
    out = copy(df)
    out.ts_local = [DateTime(astimezone(ZonedDateTime(t, tz"UTC"), Config.SEM_TZ))
                    for t in out.ts_utc]
    out.date = Date.(out.ts_local)
    out.hour = hour.(out.ts_local)
    return out
end

"""
    build_basis_panel(; prices, load, wind, solar, commodities, imbalance) -> DataFrame

Inner-joins ISP onto the DAM panel. Returns one row per (date, hour) carrying
both the day-ahead price (`price`) and the imbalance settlement price (`isp`).
"""
function build_basis_panel(; prices::DataFrame, load::DataFrame, wind::DataFrame,
                            solar::DataFrame, commodities::DataFrame,
                            imbalance::DataFrame)
    panel = Features.build_panel(prices = prices, load = load,
                                 wind = wind, solar = solar,
                                 commodities = commodities)
    isp = _to_local(imbalance)
    isp_d = combine(groupby(isp, [:date, :hour]), :isp => mean => :isp)
    out = innerjoin(panel, isp_d, on = [:date, :hour])
    out.basis = out.isp .- out.price
    sort!(out, [:date, :hour])
    return out
end

"""
    add_basis_features(panel) -> DataFrame

All features below are knowable at the prediction time (just after the day-ahead
auction clears for day D, before delivery). No information from day D's actual
realised flows is used.

Features added:
  Calendar:
    dow, is_weekend, is_holiday_ie, is_holiday_uk, month,
    sin_doy, cos_doy, sin_hour, cos_hour
  DA-price features (DA is the conditioner; known at predict time):
    da_price, da_price_minus_daymean, da_daily_mean, da_daily_range,
    da_price_rank_30d (rank within trailing 30-day distribution)
  Demand/supply forecasts (same forecasts the auction used):
    load_fcst, wind_fcst, solar_fcst, residual_demand,
    wind_share = wind_fcst / load_fcst, residual_demand_z (30-day z-score),
    daily_peak_load_fcst, daily_mean_wind_fcst
  Lagged basis:
    basis_lag_24h, basis_lag_48h, basis_lag_168h,
    basis_roll7_same_hour, basis_roll7_abs_same_hour (variability proxy),
    basis_daily_mean_d_minus_1, basis_sign_yday (categorical regime)
"""
function add_basis_features(panel::DataFrame)
    df = copy(panel)
    df.dow            = dayofweek.(df.date)
    df.is_weekend     = Int.(df.dow .>= 6)
    df.is_holiday_ie  = Int.(Calendar.is_holiday_ie.(df.date))
    df.is_holiday_uk  = Int.(Calendar.is_holiday_uk.(df.date))
    df.month          = month.(df.date)
    doy               = dayofyear.(df.date)
    df.sin_doy        = sin.(2π .* doy ./ 365.25)
    df.cos_doy        = cos.(2π .* doy ./ 365.25)
    df.sin_hour       = sin.(2π .* df.hour ./ 24.0)
    df.cos_hour       = cos.(2π .* df.hour ./ 24.0)

    df.da_price = df.price
    df.residual_demand = df.load_fcst .- df.wind_fcst .- df.solar_fcst
    df.wind_share = df.wind_fcst ./ max.(df.load_fcst, 1.0)

    # Daily summaries known at predict time (DA prices are all known at once).
    daily = combine(groupby(df, :date),
        :price     => mean    => :da_daily_mean,
        :price     => (x -> maximum(x) - minimum(x)) => :da_daily_range,
        :load_fcst => maximum => :daily_peak_load_fcst,
        :wind_fcst => mean    => :daily_mean_wind_fcst,
    )
    df = leftjoin(df, daily, on = :date)
    df.da_price_minus_daymean = df.da_price .- df.da_daily_mean

    # 30-day rolling z-score / rank of residual demand and DA price.
    # Computed per (date, hour) using only data strictly earlier than date.
    sort!(df, [:date, :hour])
    idx_dh = Dict{Tuple{Date,Int},Int}()
    for i in 1:nrow(df)
        idx_dh[(df.date[i], df.hour[i])] = i
    end

    df.residual_demand_z = Vector{Union{Missing,Float64}}(undef, nrow(df))
    df.da_price_rank_30d = Vector{Union{Missing,Float64}}(undef, nrow(df))

    # Build a per-hour-of-day rolling window using sliding indices.
    for h in 0:23
        rows = sort([i for i in 1:nrow(df) if df.hour[i] == h], by = i -> df.date[i])
        rd_buf = Float64[]
        da_buf = Float64[]
        # Sliding window of last 30 same-hour observations.
        for (k, i) in enumerate(rows)
            if length(rd_buf) >= 5
                μ = mean(rd_buf); σ = std(rd_buf)
                df.residual_demand_z[i] = σ > 1e-6 ? (df.residual_demand[i] - μ) / σ : 0.0
                # Empirical rank in [0, 1] of da_price within recent window.
                df.da_price_rank_30d[i] = mean(da_buf .<= df.da_price[i])
            else
                df.residual_demand_z[i] = missing
                df.da_price_rank_30d[i] = missing
            end
            push!(rd_buf, df.residual_demand[i])
            push!(da_buf, df.da_price[i])
            if length(rd_buf) > 30
                popfirst!(rd_buf); popfirst!(da_buf)
            end
        end
    end

    # Lagged basis features (basis from days strictly before D is known).
    function _lag_basis(d::Date, h::Int, days_back::Int)
        k = (d - Day(days_back), h)
        haskey(idx_dh, k) || return missing
        return df.basis[idx_dh[k]]
    end

    df.basis_lag_24h  = Vector{Union{Missing,Float64}}(undef, nrow(df))
    df.basis_lag_48h  = Vector{Union{Missing,Float64}}(undef, nrow(df))
    df.basis_lag_168h = Vector{Union{Missing,Float64}}(undef, nrow(df))
    df.basis_roll7_same_hour     = Vector{Union{Missing,Float64}}(undef, nrow(df))
    df.basis_roll7_abs_same_hour = Vector{Union{Missing,Float64}}(undef, nrow(df))
    df.basis_daily_mean_d_minus_1 = Vector{Union{Missing,Float64}}(undef, nrow(df))
    df.basis_sign_yday = Vector{Union{Missing,Float64}}(undef, nrow(df))

    daily_basis = combine(groupby(df, :date), :basis => mean => :_daily_mean_basis)
    daily_basis_lookup = Dict(daily_basis.date[i] => daily_basis._daily_mean_basis[i]
                              for i in 1:nrow(daily_basis))

    for i in 1:nrow(df)
        d, h = df.date[i], df.hour[i]
        df.basis_lag_24h[i]  = _lag_basis(d, h, 1)
        df.basis_lag_48h[i]  = _lag_basis(d, h, 2)
        df.basis_lag_168h[i] = _lag_basis(d, h, 7)
        vals = Float64[]
        for k in 1:7
            v = _lag_basis(d, h, k)
            ismissing(v) || push!(vals, v)
        end
        df.basis_roll7_same_hour[i]     = isempty(vals) ? missing : mean(vals)
        df.basis_roll7_abs_same_hour[i] = isempty(vals) ? missing : mean(abs.(vals))
        df.basis_daily_mean_d_minus_1[i] = get(daily_basis_lookup, d - Day(1), missing)
        yday = _lag_basis(d, h, 1)
        df.basis_sign_yday[i] = ismissing(yday) ? missing : Float64(sign(yday))
    end

    required = [:basis, :da_price, :load_fcst, :wind_fcst, :residual_demand,
                :basis_lag_24h, :basis_lag_168h, :basis_roll7_same_hour,
                :residual_demand_z, :da_price_rank_30d]
    df = dropmissing(df, required)
    return df
end

"""
    basis_feature_columns(df)

Model input columns: everything except the target (`basis`), the ISP itself
(would be leakage), and bookkeeping. Importantly, `price` (a.k.a. `da_price`)
is allowed because the DA price is the conditioner — we predict basis given
the DA price has cleared.
"""
function basis_feature_columns(df::DataFrame)
    exclude = Set([:basis, :isp, :ts_utc, :ts_local, :date,
                   :daily_mean_price,
                   :daily_mean_price_d_minus_1])  # comes from Features.add_features path; not present here, safe to ignore
    return [c for c in propertynames(df) if !(c in exclude)]
end

end # module
