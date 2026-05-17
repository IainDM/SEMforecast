# SEMforecast

A forecasting pipeline for **SEM** (Single Electricity Market — Ireland +
Northern Ireland) day-ahead auction prices, written in Julia.

The goal is to beat the naive `same-hour-yesterday` baseline on a walk-forward
backtest.

## What's in the box

```
src/
  Config.jl         constants, paths, .env loader
  Calendar.jl       Irish + UK bank holidays (incl. NI dates, St Brigid's)
  Entsoe.jl         REST client for the ENTSO-E Transparency Platform
  Commodities.jl    Yahoo Finance fetch for TTF gas + EUA carbon
  Features.jl       feature engineering (calendar, lags, residual demand, ...)
  Baseline.jl       the naive D-1 same-hour benchmark
  Model.jl          EvoTrees gradient-boosted regressor (MAE loss)
  Backtest.jl       walk-forward evaluation
  Report.jl         metrics + matplotlib-style charts via Plots.jl
scripts/
  fetch_data.jl     pulls & caches ENTSO-E + commodity data to data/
  run_backtest.jl   runs the backtest, writes reports/backtest_<timestamp>/
  train.jl          fits the final model on all data, serialises it
```

## Setup

Install Julia 1.10 LTS from <https://julialang.org/downloads/>, then:

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

For real data, register at <https://transparency.entsoe.eu> and request a
web-API security token (Account Settings → "Generate a new token"). Then:

```bash
cp .env.example .env
# edit .env, set ENTSOE_API_KEY=<your token>
```

## Run

```bash
# 1. Fetch & cache data (one-time, ~5 min for 3 years)
julia --project=. scripts/fetch_data.jl --start 2022-01-01 --end 2026-05-01

# 2. Backtest
julia --project=. scripts/run_backtest.jl --eval-start 2025-11-01 --verbose

# 3. (Optional) train final model on all data
julia --project=. scripts/train.jl
```

The backtest writes `reports/backtest_<timestamp>/` containing:
- `metrics.json` (headline numbers)
- `per_hour_mae.csv`
- `forecast_vs_actual.png` (last 14 days)
- `daily_mae_timeseries.png`
- `per_hour_mae.png`
- `README.md` (markdown summary)

## Smoke test without an API token

```bash
julia --project=. scripts/fetch_data.jl --synthetic --start 2022-01-01 --end 2026-05-01
julia --project=. scripts/run_backtest.jl --eval-start 2025-11-01
```

The synthetic generator produces plausible-looking series with the right
structural features (two-peak demand, wind-driven price suppression, weekly
cycle, occasional spikes) — enough to verify the pipeline runs end-to-end.

## Model & features

**Target:** hourly SEM day-ahead price (EUPHEMIA), local time (Europe/Dublin).

**Baseline (the thing to beat):** `y_pred[h, d] = y_actual[h, d-1]`.

**Model:** EvoTrees gradient-boosted regressor, MAE loss, single global model
with `hour` as an ordinal feature. 2000 max trees with early stopping on a
21-day eval slice. Hyperparameters live in `src/Config.jl`.

**Features (all known before the D-1 11:00 auction):**
- Calendar: hour-of-day (raw + cyclic), day-of-week, weekend flag, IE/UK
  holiday flags, month, day-of-year (cyclic)
- ENTSO-E day-ahead exogenous: load forecast, wind forecast, solar forecast,
  residual demand (load − wind − solar), daily peak load, daily mean wind
- Lagged prices (D-1 prices are known when forecasting D): 24h / 48h / 168h
  lags at same hour, 7-day rolling mean at same hour, D-1 daily mean
- Commodity proxies (lagged 1 day): TTF gas, EUA carbon, CCGT spark proxy

## Evaluation

Walk-forward with weekly retrains:
1. For each test date D, train on rows where `date <= D − 2`
2. Predict all 24 hours of D
3. Retrain every 7 days (default)

Headline metrics: MAE, RMSE, sMAPE; skill score = `1 − MAE_model / MAE_baseline`
(positive = wins).

## Why these choices

- **Hourly target, not half-hourly**: SEM's EUPHEMIA day-ahead auction is
  hourly by market design; the 30-minute settlement applies to imbalance,
  not DAM.
- **EvoTrees over LightGBM**: pure Julia, no external C dependency, MAE
  support out of the box. Marginal accuracy difference vs LightGBM on
  tabular data of this size.
- **MAE loss**: SEM prices have heavy-tailed spikes (occasional €500+ hours);
  L1 is robust where L2 would chase spikes.
- **Single model with `hour` as feature, not 24 hour-specific models**: more
  data per leaf, learns shared structure; standard in DAM forecasting
  literature.
- **EUR/MWh stays in EUR throughout** (no normalisation to other units).

## Out of scope (v1)

Hyperparameter sweeps; probabilistic / quantile forecasts; outage data;
live inference scheduling; unit tests. The backtest skill score is the
integration test.
