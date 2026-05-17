module Features

using Dates
using TimeZones
using DataFrames
using Statistics

using ..Config
using ..Calendar

# ---------------------------------------------------------------------------
# Time conversion
# ---------------------------------------------------------------------------

# Converts a UTC DateTime column into a Europe/Dublin local-time DateTime
# (timezone-naive after conversion). DAM clears in local time; features and
# targets are aligned there.
function _to_local(df::DataFrame, src_col::Symbol = :ts_utc)
    df = copy(df)
    df.ts_local = [DateTime(astimezone(ZonedDateTime(t, tz"UTC"), Config.SEM_TZ))
                   for t in df[!, src_col]]
    df.date = Date.(df.ts_local)
    df.hour = hour.(df.ts_local)
    return df
end

# ---------------------------------------------------------------------------
# Assemble panel: one row per (date, hour) with all raw signals
# ---------------------------------------------------------------------------

"""
    build_panel(; prices, load, wind, solar, commodities) -> DataFrame

Inner-joins the hourly signals into one panel keyed on (date, hour). All
inputs are assumed to be in UTC initially. Commodities are daily and
left-joined on date.
"""
function build_panel(; prices::DataFrame, load::DataFrame, wind::DataFrame,
                     solar::DataFrame, commodities::DataFrame)
    p = _to_local(prices)
    l = _to_local(load)
    w = _to_local(wind)
    s = _to_local(solar)

    # Average duplicate (date, hour) rows that DST fall-back creates.
    function _dedupe(df, value_col)
        gd = groupby(df, [:date, :hour])
        combine(gd, value_col => mean => value_col)
    end
    p = _dedupe(p, :price)
    l = _dedupe(l, :load_fcst)
    w = _dedupe(w, :wind_fcst)
    s = isempty(s) ? DataFrame(date = Date[], hour = Int[], solar_fcst = Float64[]) :
                     _dedupe(s, :solar_fcst)

    panel = innerjoin(p, l, on = [:date, :hour])
    panel = leftjoin(panel, w, on = [:date, :hour])
    panel = leftjoin(panel, s, on = [:date, :hour])
    panel.wind_fcst = coalesce.(panel.wind_fcst, 0.0)
    panel.solar_fcst = coalesce.(panel.solar_fcst, 0.0)

    panel = leftjoin(panel, commodities, on = :date)
    # Forward-fill commodities within the panel (already filled day-by-day but
    # be defensive: leading rows may have missing values if commodity series
    # starts later than price series).
    for col in (:ttf_gas, :eua_carbon)
        if col in propertynames(panel)
            sort!(panel, [:date, :hour])
            last_val = missing
            for i in 1:nrow(panel)
                v = panel[i, col]
                if ismissing(v)
                    panel[i, col] = last_val
                else
                    last_val = v
                end
            end
        end
    end

    sort!(panel, [:date, :hour])
    return panel
end

# ---------------------------------------------------------------------------
# Feature engineering
# ---------------------------------------------------------------------------

"""
    add_features(panel) -> DataFrame

Adds calendar, lag, rolling and commodity-derived columns. All features are
values **knowable before the day-ahead auction closes** for the target day.

Returns a new DataFrame with the target column `price` and feature columns.
Rows with missing required features (e.g. early rows lacking 7-day lags)
are dropped.
"""
function add_features(panel::DataFrame)
    df = copy(panel)
    n = nrow(df)
    df.dow          = dayofweek.(df.date)
    df.is_weekend   = Int.(df.dow .>= 6)
    df.is_holiday_ie = Int.(Calendar.is_holiday_ie.(df.date))
    df.is_holiday_uk = Int.(Calendar.is_holiday_uk.(df.date))
    df.month        = month.(df.date)
    doy = dayofyear.(df.date)
    df.sin_doy = sin.(2π .* doy ./ 365.25)
    df.cos_doy = cos.(2π .* doy ./ 365.25)
    df.sin_hour = sin.(2π .* df.hour ./ 24.0)
    df.cos_hour = cos.(2π .* df.hour ./ 24.0)

    df.residual_demand = df.load_fcst .- df.wind_fcst .- df.solar_fcst

    # Daily aggregates (same value for all 24 hours of a date).
    daily = combine(groupby(df, :date),
        :load_fcst => maximum => :daily_peak_load_fcst,
        :wind_fcst => mean    => :daily_mean_wind_fcst,
        :price     => mean    => :daily_mean_price)
    df = leftjoin(df, daily, on = :date)

    # Build a (date, hour) -> row index map for lag lookups.
    idx = Dict{Tuple{Date,Int},Int}()
    for i in 1:nrow(df)
        idx[(df.date[i], df.hour[i])] = i
    end

    function _lag_price(d::Date, h::Int, days_back::Int)
        k = (d - Day(days_back), h)
        haskey(idx, k) || return missing
        return df.price[idx[k]]
    end

    df.price_lag_24h  = Vector{Union{Missing,Float64}}(undef, nrow(df))
    df.price_lag_48h  = Vector{Union{Missing,Float64}}(undef, nrow(df))
    df.price_lag_168h = Vector{Union{Missing,Float64}}(undef, nrow(df))
    df.daily_mean_price_d_minus_1 = Vector{Union{Missing,Float64}}(undef, nrow(df))
    df.price_roll7_same_hour = Vector{Union{Missing,Float64}}(undef, nrow(df))

    # Daily mean lookup.
    daily_mean = Dict(daily.date[i] => daily.daily_mean_price[i] for i in 1:nrow(daily))

    for i in 1:nrow(df)
        d, h = df.date[i], df.hour[i]
        df.price_lag_24h[i]  = _lag_price(d, h, 1)
        df.price_lag_48h[i]  = _lag_price(d, h, 2)
        df.price_lag_168h[i] = _lag_price(d, h, 7)
        df.daily_mean_price_d_minus_1[i] = get(daily_mean, d - Day(1), missing)
        vals = Float64[]
        for k in 1:7
            v = _lag_price(d, h, k)
            ismissing(v) || push!(vals, v)
        end
        df.price_roll7_same_hour[i] = isempty(vals) ? missing : mean(vals)
    end

    # Commodity-derived spark proxy (CCGT short-run marginal cost).
    if :ttf_gas in propertynames(df) && :eua_carbon in propertynames(df)
        df.spark_proxy = df.ttf_gas ./ Config.CCGT_HEAT_RATE .+
                         df.eua_carbon .* Config.CCGT_EMISSIONS
        # Lag commodities by 1 day (use D-1 close when forecasting D).
        df.ttf_gas_d1 = Vector{Union{Missing,Float64}}(undef, nrow(df))
        df.eua_carbon_d1 = Vector{Union{Missing,Float64}}(undef, nrow(df))
        df.spark_proxy_d1 = Vector{Union{Missing,Float64}}(undef, nrow(df))
        prev_day = Dict{Date,Tuple{Union{Missing,Float64},Union{Missing,Float64},Union{Missing,Float64}}}()
        # collect one row per date (commodities are flat per day)
        for sub in groupby(df, :date)
            d = sub.date[1]
            prev_day[d] = (sub.ttf_gas[1], sub.eua_carbon[1], sub.spark_proxy[1])
        end
        for i in 1:nrow(df)
            t = get(prev_day, df.date[i] - Day(1), (missing, missing, missing))
            df.ttf_gas_d1[i], df.eua_carbon_d1[i], df.spark_proxy_d1[i] = t
        end
    end

    # Drop rows missing any required feature.
    required = [:price, :price_lag_24h, :price_lag_168h,
                :price_roll7_same_hour, :load_fcst, :wind_fcst,
                :residual_demand]
    df = dropmissing(df, required)
    return df
end

"""
    feature_columns(df)

Returns the column names used as model inputs (everything except the target
and bookkeeping columns).
"""
function feature_columns(df::DataFrame)
    exclude = Set([:price, :ts_utc, :ts_local, :date, :daily_mean_price])
    return [c for c in propertynames(df) if !(c in exclude)]
end

end # module
