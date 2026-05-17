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
    build_panel(; prices, load, wind, solar, commodities,
                  weather = nothing, gb_price = nothing, gb_wind = nothing,
                  outages = nothing, actuals = nothing, nao = nothing) -> DataFrame

Inner-joins the hourly signals into one panel keyed on (date, hour). The
new optional args (weather/GB/outages/actuals/NAO) are left-joined when
supplied so the panel works on either the original feature set or the
v2 enriched set.
"""
function build_panel(; prices::DataFrame, load::DataFrame, wind::DataFrame,
                     solar::DataFrame, commodities::DataFrame,
                     weather::Union{Nothing,DataFrame} = nothing,
                     gb_price::Union{Nothing,DataFrame} = nothing,
                     gb_wind::Union{Nothing,DataFrame}  = nothing,
                     outages::Union{Nothing,DataFrame}  = nothing,
                     actuals::Union{Nothing,DataFrame}  = nothing,
                     nao::Union{Nothing,DataFrame}      = nothing)
    p = _to_local(prices)
    l = _to_local(load)
    w = _to_local(wind)
    s = _to_local(solar)

    # Average duplicate (date, hour) rows that DST fall-back creates.
    function _dedupe(df, value_cols::Vector{Symbol})
        gd = groupby(df, [:date, :hour])
        aggs = [c => mean => c for c in value_cols]
        return combine(gd, aggs...)
    end
    p = _dedupe(p, [:price])
    l = _dedupe(l, [:load_fcst])
    w = _dedupe(w, [:wind_fcst])
    s = isempty(s) ? DataFrame(date = Date[], hour = Int[], solar_fcst = Float64[]) :
                     _dedupe(s, [:solar_fcst])

    panel = innerjoin(p, l, on = [:date, :hour])
    panel = leftjoin(panel, w, on = [:date, :hour])
    panel = leftjoin(panel, s, on = [:date, :hour])
    panel.wind_fcst = coalesce.(panel.wind_fcst, 0.0)
    panel.solar_fcst = coalesce.(panel.solar_fcst, 0.0)

    # --- Weather (Met Éireann / synthetic) ---
    if weather !== nothing && nrow(weather) > 0
        wx = _to_local(weather)
        wx_cols = [c for c in propertynames(wx)
                   if !(c in (:ts_utc, :ts_local, :date, :hour))]
        wx = _dedupe(wx, wx_cols)
        panel = leftjoin(panel, wx, on = [:date, :hour])
    end

    # --- GB price + wind ---
    if gb_price !== nothing && nrow(gb_price) > 0
        gp = _to_local(gb_price)
        gp = _dedupe(gp, [:gb_price])
        panel = leftjoin(panel, gp, on = [:date, :hour])
    end
    if gb_wind !== nothing && nrow(gb_wind) > 0
        gw = _to_local(gb_wind)
        gw = _dedupe(gw, [:gb_wind_fcst])
        panel = leftjoin(panel, gw, on = [:date, :hour])
    end

    # --- Outages ---
    if outages !== nothing && nrow(outages) > 0
        ox = _to_local(outages)
        ox_cols = [c for c in propertynames(ox)
                   if !(c in (:ts_utc, :ts_local, :date, :hour))]
        ox = _dedupe(ox, ox_cols)
        panel = leftjoin(panel, ox, on = [:date, :hour])
        # Outage columns must be 0, not missing, when not present in that hour.
        for c in ox_cols
            panel[!, c] = coalesce.(panel[!, c], 0.0)
        end
    end

    # --- Actuals (load_actual, wind_actual) for rolling-MAE features ---
    if actuals !== nothing && nrow(actuals) > 0
        ax = _to_local(actuals)
        ax_cols = [c for c in propertynames(ax)
                   if !(c in (:ts_utc, :ts_local, :date, :hour))]
        ax = _dedupe(ax, ax_cols)
        panel = leftjoin(panel, ax, on = [:date, :hour])
    end

    # --- Commodities (daily) ---
    panel = leftjoin(panel, commodities, on = :date)
    # Forward-fill commodities (defensive: leading rows may be missing).
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

    # --- NAO (daily, broadcast) ---
    if nao !== nothing && nrow(nao) > 0
        panel = leftjoin(panel, nao, on = :date)
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

    # ----- Holiday neighbourhood + DST (no new data needed) -----
    df.is_holiday_eve         = Int.(Calendar.is_holiday_eve.(df.date))
    df.is_post_holiday        = Int.(Calendar.is_post_holiday.(df.date))
    df.days_to_next_holiday   = Calendar.days_to_next_holiday.(df.date)
    df.days_since_last_holiday = Calendar.days_since_last_holiday.(df.date)
    df.is_bridge_day          = Int.(Calendar.is_bridge_day.(df.date))
    df.is_dst_transition_day  = Int.(Calendar.is_dst_transition_day.(df.date))
    df.days_since_dst_change  = Calendar.days_since_dst_change.(df.date)

    df.residual_demand = df.load_fcst .- df.wind_fcst .- df.solar_fcst

    # ----- Weather aggregates -----
    wind_station_cols = [:wind_mace_head, :wind_belmullet, :wind_malin_head,
                         :wind_valentia, :wind_roches_point]
    if all(c -> c in propertynames(df), wind_station_cols)
        ws = hcat([df[!, c] for c in wind_station_cols]...)
        df.wind_spatial_stdev = [std(ws[i, :]) for i in 1:nrow(df)]
        df.wind_coastal_mean  = [mean(ws[i, :]) for i in 1:nrow(df)]
    end
    if :winddir_mace_head in propertynames(df)
        df.winddir_mace_sin = sin.(2π .* df.winddir_mace_head ./ 360.0)
        df.winddir_mace_cos = cos.(2π .* df.winddir_mace_head ./ 360.0)
    end
    if :temp_dublin in propertynames(df)
        df.hdd_dublin = max.(0.0, 15.5 .- df.temp_dublin)
        df.cdd_dublin = max.(0.0, df.temp_dublin .- 22.0)
    end

    # ----- Daily aggregates (same value for all 24 hours of a date) -----
    daily = combine(groupby(df, :date),
        :load_fcst => maximum => :daily_peak_load_fcst,
        :wind_fcst => mean    => :daily_mean_wind_fcst,
        :price     => mean    => :daily_mean_price)
    df = leftjoin(df, daily, on = :date)

    # ----- (date, hour) -> row index for lag lookups -----
    idx = Dict{Tuple{Date,Int},Int}()
    for i in 1:nrow(df)
        idx[(df.date[i], df.hour[i])] = i
    end

    _lookup(col_sym) = function(d::Date, h::Int, k::Int)
        key = (d - Day(k), h)
        haskey(idx, key) || return missing
        return df[idx[key], col_sym]
    end

    # ----- Lagged DAM prices -----
    df.price_lag_24h  = Vector{Union{Missing,Float64}}(undef, nrow(df))
    df.price_lag_48h  = Vector{Union{Missing,Float64}}(undef, nrow(df))
    df.price_lag_168h = Vector{Union{Missing,Float64}}(undef, nrow(df))
    df.daily_mean_price_d_minus_1 = Vector{Union{Missing,Float64}}(undef, nrow(df))
    df.price_roll7_same_hour = Vector{Union{Missing,Float64}}(undef, nrow(df))

    daily_mean = Dict(daily.date[i] => daily.daily_mean_price[i] for i in 1:nrow(daily))
    lookup_price = _lookup(:price)

    for i in 1:nrow(df)
        d, h = df.date[i], df.hour[i]
        df.price_lag_24h[i]  = lookup_price(d, h, 1)
        df.price_lag_48h[i]  = lookup_price(d, h, 2)
        df.price_lag_168h[i] = lookup_price(d, h, 7)
        df.daily_mean_price_d_minus_1[i] = get(daily_mean, d - Day(1), missing)
        vals = Float64[]
        for k in 1:7
            v = lookup_price(d, h, k)
            ismissing(v) || push!(vals, v)
        end
        df.price_roll7_same_hour[i] = isempty(vals) ? missing : mean(vals)
    end

    # ----- Commodities & spark proxy -----
    if :ttf_gas in propertynames(df) && :eua_carbon in propertynames(df)
        df.spark_proxy = df.ttf_gas ./ Config.CCGT_HEAT_RATE .+
                         df.eua_carbon .* Config.CCGT_EMISSIONS
        df.ttf_gas_d1 = Vector{Union{Missing,Float64}}(undef, nrow(df))
        df.eua_carbon_d1 = Vector{Union{Missing,Float64}}(undef, nrow(df))
        df.spark_proxy_d1 = Vector{Union{Missing,Float64}}(undef, nrow(df))
        prev_day = Dict{Date,Tuple{Union{Missing,Float64},Union{Missing,Float64},Union{Missing,Float64}}}()
        for sub in groupby(df, :date)
            d = sub.date[1]
            prev_day[d] = (sub.ttf_gas[1], sub.eua_carbon[1], sub.spark_proxy[1])
        end
        for i in 1:nrow(df)
            t = get(prev_day, df.date[i] - Day(1), (missing, missing, missing))
            df.ttf_gas_d1[i], df.eua_carbon_d1[i], df.spark_proxy_d1[i] = t
        end
    end

    # ----- GB price lags (today's GB price isn't known when forecasting SEM DAM) -----
    if :gb_price in propertynames(df)
        df.gb_price_lag_24h = Vector{Union{Missing,Float64}}(undef, nrow(df))
        df.gb_price_lag_48h = Vector{Union{Missing,Float64}}(undef, nrow(df))
        lookup_gb = _lookup(:gb_price)
        for i in 1:nrow(df)
            d, h = df.date[i], df.hour[i]
            df.gb_price_lag_24h[i] = lookup_gb(d, h, 1)
            df.gb_price_lag_48h[i] = lookup_gb(d, h, 2)
        end
    end
    # GB wind forecast for D IS known pre-auction (NESO publishes ~D-2 evening).
    # No lag needed; keep `gb_wind_fcst` if present.

    # ----- Outages: use lagged values (today's may include unplanned events) -----
    if :outage_capacity_mw in propertynames(df)
        df.outage_capacity_lag_24h = Vector{Union{Missing,Float64}}(undef, nrow(df))
        df.unplanned_outage_lag_24h = Vector{Union{Missing,Float64}}(undef, nrow(df))
        df.large_outage_flag_lag_24h = Vector{Union{Missing,Int}}(undef, nrow(df))
        lookup_out  = _lookup(:outage_capacity_mw)
        lookup_unp  = _lookup(:unplanned_outage_mw)
        lookup_lflg = _lookup(:large_outage_flag)
        for i in 1:nrow(df)
            d, h = df.date[i], df.hour[i]
            df.outage_capacity_lag_24h[i]   = lookup_out(d, h, 1)
            df.unplanned_outage_lag_24h[i]  = lookup_unp(d, h, 1)
            df.large_outage_flag_lag_24h[i] = lookup_lflg(d, h, 1)
        end
    end

    # ----- Forecast-MAE rolling 7d (needs actuals from D-2 backwards) -----
    if :wind_actual in propertynames(df) && :load_actual in propertynames(df)
        df.wind_fcst_mae_7d = Vector{Union{Missing,Float64}}(undef, nrow(df))
        df.load_fcst_mae_7d = Vector{Union{Missing,Float64}}(undef, nrow(df))
        for i in 1:nrow(df)
            d, h = df.date[i], df.hour[i]
            wmae = Float64[]; lmae = Float64[]
            # Use lags k = 2 .. 8 so we only use information known by D-2 (actuals
            # for D-1 might not be settled at predict time).
            for k in 2:8
                key = (d - Day(k), h)
                haskey(idx, key) || continue
                ridx = idx[key]
                wmae_val = abs(df.wind_fcst[ridx] - df.wind_actual[ridx])
                lmae_val = abs(df.load_fcst[ridx] - df.load_actual[ridx])
                push!(wmae, wmae_val); push!(lmae, lmae_val)
            end
            df.wind_fcst_mae_7d[i] = isempty(wmae) ? missing : mean(wmae)
            df.load_fcst_mae_7d[i] = isempty(lmae) ? missing : mean(lmae)
        end
    end

    # ----- Recent regime flags (computed from D-1 prices, known at predict time) -----
    df.spike_count_24h   = Vector{Union{Missing,Int}}(undef, nrow(df))
    df.negprice_count_24h = Vector{Union{Missing,Int}}(undef, nrow(df))
    daily_by_date = groupby(df, :date)
    daily_lookup = Dict{Date,Tuple{Int,Int}}()
    for sub in daily_by_date
        d = sub.date[1]
        sc = sum(sub.price .> 200.0)
        nc = sum(sub.price .< 0.0)
        daily_lookup[d] = (sc, nc)
    end
    for i in 1:nrow(df)
        t = get(daily_lookup, df.date[i] - Day(1), (missing, missing))
        df.spike_count_24h[i], df.negprice_count_24h[i] = t
    end

    # ----- Drop rows missing any required feature -----
    required = [:price, :price_lag_24h, :price_lag_168h,
                :price_roll7_same_hour, :load_fcst, :wind_fcst,
                :residual_demand]
    df = dropmissing(df, required)
    return df
end

"""
    feature_columns(df)

Returns the column names used as model inputs. Excludes:
  - the target (`price`)
  - bookkeeping (`ts_utc`, `ts_local`, `date`, `daily_mean_price`)
  - post-delivery actuals (`wind_actual`, `load_actual`) — used to derive
    rolling-MAE features but never input directly (would leak future info)
  - same-hour outage levels (`outage_capacity_mw` etc.) — these can include
    unplanned events not yet visible at predict time; only the lag_24h
    variants are safe
  - ISP / basis columns if present (basis model uses different target)
  - raw `gb_price` (only the lag_24h / lag_48h variants are pre-auction)
"""
function feature_columns(df::DataFrame)
    exclude = Set([
        :price, :ts_utc, :ts_local, :date, :daily_mean_price,
        # post-delivery — never input directly
        :wind_actual, :load_actual,
        # potential leakage — only the lag_24h variants are safe
        :outage_capacity_mw, :unplanned_outage_mw, :large_outage_flag,
        :gb_price,
        # basis-model-only columns
        :isp, :basis,
    ])
    return [c for c in propertynames(df) if !(c in exclude)]
end

end # module
