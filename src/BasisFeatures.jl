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
    build_basis_panel(; prices, load, wind, solar, commodities, imbalance,
                        weather = nothing, gb_price = nothing,
                        gb_wind = nothing, outages = nothing,
                        actuals = nothing, nao = nothing) -> DataFrame

Inner-joins ISP onto the DAM panel. The optional weather/GB/outages/actuals/NAO
args are passed through to `Features.build_panel`.
"""
function build_basis_panel(; prices::DataFrame, load::DataFrame, wind::DataFrame,
                            solar::DataFrame, commodities::DataFrame,
                            imbalance::DataFrame,
                            weather::Union{Nothing,DataFrame} = nothing,
                            gb_price::Union{Nothing,DataFrame} = nothing,
                            gb_wind::Union{Nothing,DataFrame}  = nothing,
                            outages::Union{Nothing,DataFrame}  = nothing,
                            actuals::Union{Nothing,DataFrame}  = nothing,
                            nao::Union{Nothing,DataFrame}      = nothing)
    panel = Features.build_panel(
        prices = prices, load = load, wind = wind, solar = solar,
        commodities = commodities,
        weather = weather, gb_price = gb_price, gb_wind = gb_wind,
        outages = outages, actuals = actuals, nao = nao,
    )
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
    # Reuse the full DAM-side feature engineering: calendar, weather, GB,
    # outages, commodities, lagged prices, recent regime flags, rolling
    # forecast-MAE, etc. — all the v2 features are inherited.
    df = Features.add_features(panel)

    # ----- Basis-target-specific extras layered on top -----
    df.da_price = df.price
    df.wind_share = df.wind_fcst ./ max.(df.load_fcst, 1.0)

    # Daily DA-price summaries (known at predict time since all 24h of D
    # cleared together in the auction).
    daily = combine(groupby(df, :date),
        :price => mean                              => :da_daily_mean,
        :price => (x -> maximum(x) - minimum(x))    => :da_daily_range)
    df = leftjoin(df, daily, on = :date)
    df.da_price_minus_daymean = df.da_price .- df.da_daily_mean

    # 30-day per-hour-of-day rolling z-score / rank.
    sort!(df, [:date, :hour])
    idx_dh = Dict{Tuple{Date,Int},Int}()
    for i in 1:nrow(df)
        idx_dh[(df.date[i], df.hour[i])] = i
    end
    df.residual_demand_z = Vector{Union{Missing,Float64}}(undef, nrow(df))
    df.da_price_rank_30d = Vector{Union{Missing,Float64}}(undef, nrow(df))
    for h in 0:23
        rows = sort([i for i in 1:nrow(df) if df.hour[i] == h],
                    by = i -> df.date[i])
        rd_buf = Float64[]
        da_buf = Float64[]
        for i in rows
            if length(rd_buf) >= 5
                μ = mean(rd_buf); σ = std(rd_buf)
                df.residual_demand_z[i] = σ > 1e-6 ? (df.residual_demand[i] - μ) / σ : 0.0
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

    # Lagged basis features.
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

    # ----- Basis-specific cross-market signal: IE−GB spread yesterday -----
    if :gb_price_lag_24h in propertynames(df)
        # da_price[D,h] − gb_price[D-1,h] (proxy for the cross-market regime
        # at the same delivery hour yesterday). Today's GB price is on the panel
        # — use it directly when present.
        if :gb_price in propertynames(df)
            df.ie_gb_spread = df.da_price .- coalesce.(df.gb_price, df.gb_price_lag_24h)
        else
            df.ie_gb_spread = df.da_price .- df.gb_price_lag_24h
        end
    end

    required = [:basis, :da_price, :load_fcst, :wind_fcst, :residual_demand,
                :basis_lag_24h, :basis_lag_168h, :basis_roll7_same_hour,
                :residual_demand_z, :da_price_rank_30d]
    df = dropmissing(df, required)
    return df
end

"""
    basis_feature_columns(df)

Model input columns. Excludes:
  - target (`basis`) and its component (`isp`)
  - bookkeeping (`ts_utc`, `ts_local`, `date`)
  - daily mean price (intermediate derived column)
  - post-delivery actuals (`wind_actual`, `load_actual`)
  - same-hour unplanned outages (`unplanned_outage_mw`, `large_outage_flag`) —
    these can include events not yet visible at predict time. `outage_capacity_mw`
    is kept since planned outages are knowable.

`price` / `da_price` is allowed because the DA price has cleared at predict time
and conditions the basis. `gb_price` (today's value) is also allowed because GB
DAM clears in the same window as SEM DAM.
"""
function basis_feature_columns(df::DataFrame)
    exclude = Set([
        :basis, :isp, :ts_utc, :ts_local, :date,
        :daily_mean_price,
        # post-delivery
        :wind_actual, :load_actual,
        # potential same-hour leakage; lag_24h variants are the safe features
        :unplanned_outage_mw, :large_outage_flag,
    ])
    return [c for c in propertynames(df) if !(c in exclude)]
end

end # module
