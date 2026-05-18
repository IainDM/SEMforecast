# SEMforecast

A forecasting pipeline for **SEM** (Single Electricity Market — Ireland +
Northern Ireland) day-ahead auction prices, written in Julia.

The goal is to beat the naive `same-hour-yesterday` baseline on a walk-forward
backtest.

## What's in the box

```
src/
  Config.jl          constants, paths, .env loader
  Calendar.jl        Irish + UK bank holidays (incl. NI dates, St Brigid's)
  Entsoe.jl          REST client for the ENTSO-E Transparency Platform
  Commodities.jl     Yahoo Finance fetch for TTF gas + EUA carbon
  Features.jl        feature engineering (calendar, lags, residual demand, ...)
  Baseline.jl        the naive D-1 same-hour benchmark
  Model.jl           EvoTrees gradient-boosted regressor (MAE loss)
  Backtest.jl        walk-forward evaluation
  Report.jl          metrics + matplotlib-style charts via Plots.jl
  BasisFeatures.jl   features for the ISP − DA basis target
  QuantileModel.jl   EvoTrees quantile trio at q10 / q50 / q90
  Conformal.jl       split-conformal CQR + UP/DOWN/ABSTAIN decision rule
  BasisBacktest.jl   walk-forward eval + selective-prediction metrics
  BasisReport.jl     basis-specific charts and markdown summary
scripts/
  fetch_data.jl          pulls & caches ENTSO-E + commodity + ISP data
  run_backtest.jl        DAM price backtest (reports/backtest_<ts>/)
  train.jl               fits the final DAM model on all data
  run_basis_backtest.jl  basis selective-prediction backtest (reports/basis_<ts>/)
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

## What ENTSO-E actually exposes for SEM

Not everything maps cleanly to ENTSO-E document types. Confirmed on the live API:

| Series | Endpoint | EIC | Status |
|---|---|---|---|
| Day-ahead price | `A44` | `10Y1001A1001A59C` (SEM) | ✓ full coverage |
| Load forecast / actual | `A65` (A01 / A16) | **`10YIE-1001A00010`** (IE only — NI not separately published) | ✓ |
| Wind forecast / actual | `A69` / `A75` (B19) | `10Y1001A1001A59C` (SEM) | ✓ |
| Solar forecast | `A69` (B16) | `10Y1001A1001A59C` (SEM) | ✗ empty — SEM doesn't publish |
| Imbalance settlement price | `A85` | (all variants) | ✗ **not on ENTSO-E** for SEM |
| Generator outages | `A77` | (all variants) | ✗ empty; SEM uses **`A80`** (ZIP) |

Practical impact:
- **Basis (ISP − DA) model**: needs ISP. Source from the SEMO publication
  portal (sem-o.com) and drop a parquet/Arrow file at
  `data/raw/imbalance_prices.arrow` with columns `ts_utc, isp` (hourly mean
  of the two half-hour periods).
- **Outage features**: would help but A80 ZIP parser isn't implemented yet;
  EvoTrees ignores the empty column harmlessly in the meantime.
- **GB wind forecast (BMRS WINDFOR)**: forward-looking only; you can pull
  it live but not backfill years of history. The feature gets zero gain
  on backtest and the model ignores it.

## Real-data backtest results

On 6 months of real SEM DAM data (2025-11 → 2026-04, 2332 valid hours after
DST and gap handling):

| Metric | Naive D-1 | Model |
|---|---:|---:|
| MAE  | 37.68 €/MWh | **23.91 €/MWh** |
| RMSE | 54.36 €/MWh | 35.80 €/MWh |
| Skill (MAE) | — | **+36.5%** |

Top-10 features by gain on real data: `residual_demand`, `price_roll7_same_hour`,
`price_lag_168h`, `wind_fcst`, `load_fcst`, **`wind_fcst_mae_7d`**, `price_lag_24h`,
`daily_mean_wind_fcst`, **`gb_price_lag_24h`**, `daily_mean_price_d_minus_1`.

Forecast-error rolling features and GB cross-market lags both land in the
top 12, validating the v2 feature build. Calendar neighborhood and DST
flags show zero gain on this 6-month slice (too few rare events to learn);
they should recover on a longer training window.

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

Hyperparameter sweeps; outage data; live inference scheduling; unit tests.
The backtest skill score is the integration test.

---

# Bonus: Basis (ISP − DA) selective forecast

A second model predicts whether the **imbalance settlement price (ISP)** —
the half-hourly post-delivery cash-out price, aggregated to hourly — will
end up **above or below** the day-ahead price for each hour, by how much,
and with a confidence the model is allowed to refuse to commit to.

The pitch is **asymmetric**: saying "I'm not sure" is free; saying "UP"
when the basis goes the other way is bad. The model is built around that.

## Approach

- **Target:** `basis = isp_hourly − da_hourly` (€/MWh, can go either way).
- **Prediction time:** just after the DAM auction clears for day D. The DA
  price is known and conditioned on; nothing from day D's delivery itself
  is used as a feature.
- **Model:** three EvoTrees regressors with **quantile loss** at α ∈
  {0.1, 0.5, 0.9}, sharing one feature set. Per-row crossing-quantile fixes
  are applied so q10 ≤ q50 ≤ q90.
- **Calibration:** [**conformalized quantile regression (CQR)**](https://arxiv.org/abs/1905.03222),
  Romano, Patterson, Candès 2019. Split-conformal procedure: hold out the
  last `calibration_days` of the training window, compute non-conformity
  scores `max(q_lo − y, y − q_hi)`, take their `(1−α)` empirical quantile,
  widen the [q_lo, q_hi] interval by that amount on test. This gives the
  calibrated interval a finite-sample marginal-coverage guarantee on
  exchangeable data.
- **Decision rule (the "abstain"):**
  - calibrated `lo > 0` → signal **UP**
  - calibrated `hi < 0` → signal **DOWN**
  - else → **ABSTAIN**
  Confidence on a call = signed distance of the nearer bound from 0.

The feature set adds basis-specific lags (basis at D−1, D−2, D−7 same hour),
recent regime indicators (rolling DA-price percentile, residual-demand
z-score), the DA price itself as conditioner, and DA-daily summary stats —
on top of the calendar / load / wind / solar / commodity features the DAM
model already uses.

## Run

```bash
# (assumes scripts/fetch_data.jl --synthetic has been run — it now also
#  produces data/raw/imbalance_prices.arrow)

# Native CQR at 80% target coverage (very conservative — will likely
# abstain almost always on noisy data; that's the point)
julia --project=. scripts/run_basis_backtest.jl --eval-start 2025-11-01 --alpha 0.2

# 50% target coverage — a more actionable confidence level
julia --project=. scripts/run_basis_backtest.jl --eval-start 2025-11-01 --alpha 0.5
```

Each run writes `reports/basis_<timestamp>/` containing:
- `metrics.json` — signal rate, selective accuracy, calibrated coverage, sharpness
- `per_hour.csv` — per-hour breakdown
- `coverage_curve.csv` — sweep over an interval-scale knob, so a downstream
  user can pick the operating point that suits their cost/benefit trade-off
- `basis_timeseries.png`, `predicted_vs_actual.png`,
  `calibration_intervals.png`, `confidence_vs_accuracy.png`
- `README.md` — markdown summary

## Headline numbers on the synthetic dataset

The synthetic basis is built to be predictable in regimes but mostly noise
(mean ≈ 0, std ≈ 8.6 €/MWh, heavy tails). On 3 months of held-out test data
(2025-11-01 → 2026-01-31, 2208 hours, weekly retrains):

| α (target coverage) | signal rate | selective accuracy | empirical coverage |
|---:|---:|---:|---:|
| 0.2 (80%) | 0%  | n/a (never signals) | 80% |
| 0.5 (50%) | 10% | **83%** | 51% |
| (scale=0.3, ad-hoc tighter rule) | 36% | 74% | 29% |

Read these as: **when the model does call a direction at 50% nominal
coverage, it's right 83% of the time** — vs a 50% no-skill rate. It
abstains on 90% of hours because, honestly, most hours are too close to
zero basis to call confidently. The empirical interval coverage closely
matches the nominal target, so the "I don't know" is statistically honest,
not just heuristic.

## Why these choices

- **Quantile regression, not classification + magnitude regression**: one
  model produces both the direction-with-confidence and the magnitude
  forecast (q50). The interval is the natural carrier of uncertainty.
- **Conformal calibration on top of quantile**: raw quantile predictions
  aren't well-calibrated out of the box (gradient-boosted quantiles are
  notoriously under- or over-confident depending on regime). CQR fixes
  marginal coverage with a finite-sample guarantee.
- **Abstention as a first-class output, not a post-hoc threshold**: the
  model is built around the rule that an undecided interval is a valid
  answer. This is the right behavior for the asymmetric loss the user
  asked for.
- **No information from delivery day**: features are strictly from the
  information set at DAM clear time. No look-ahead, no leakage.
