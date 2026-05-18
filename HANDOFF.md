# Handoff note — desktop session

You're continuing the SEM day-ahead price forecasting project on a machine
with full outbound network (vs the prior container where Met Éireann was
blocked and the SEMO portal was unreachable). The branch is
`claude/sem-price-forecast-model-3cGua`. The repo runs end-to-end in Julia
1.10 against `Project.toml`.

## Where things stand

Two models built and tested:

- **DAM regressor** (`src/Model.jl`, EvoTrees MAE loss) — runs on real
  ENTSO-E data, beats naive D-1 by **+36.5%** on a 6-month walk-forward
  (Nov 2025 – Apr 2026, 2332 valid hours). For comparison, the user's
  PyPSA model on the same market gets **22%**, so we're ahead but the
  next improvements below should push higher.
- **Basis (ISP − DA) selective forecast** (`src/QuantileModel.jl` +
  `src/Conformal.jl`) — works end-to-end on synthetic, but **can't run on
  real data yet** because SEM does not publish ISP to ENTSO-E A85.

Top features on the real-data DAM run: `residual_demand`,
`price_roll7_same_hour`, `price_lag_168h`, `wind_fcst`, `load_fcst`,
`wind_fcst_mae_7d`, `gb_price_lag_24h`, `gb_price_lag_48h`. Calendar
neighborhood and DST flags showed zero gain on 6 months — keep them; they
should activate on longer training windows.

## What this container couldn't do (you now can)

1. **Met Éireann coastal weather**. `Weather.fetch_metereann_panel(...)`
   in `src/Weather.jl` is coded against `cli.fusio.net/cli/climate_data/webdata/hly{ID}.csv`
   but every request timed out from here. Station IDs are in `ME_STATIONS`
   (Mace Head, Belmullet, Malin Head, Valentia, Roches Point, Dublin).
   Real wind speeds at these stations were the user's first-named
   priority — expect a meaningful skill bump once they go in.
2. **SEMO Imbalance Settlement Price**. The SEMO publication portal
   (sem-o.com / reports.sem-o.com) was unreachable as an API from here.
   You should be able to either hit their public-reports API (browser
   dev-tools → "Copy as cURL" on a dynamic-reports XHR) or download
   half-hourly CSVs manually. Aggregate to hourly mean and drop a
   `ts_utc, isp` Arrow file at `data/raw/imbalance_prices.arrow`. That
   unblocks `scripts/run_basis_backtest.jl` immediately.
3. **Outages via ENTSO-E A80**. SEM does NOT publish A77; it uses A80
   (zipped XML) which my fetcher doesn't yet handle. Probe response is
   a `001-UNAVAILABILITY_OF_PRODUCTION_AND_GENERATION_UNITS_*.xml` ZIP.
   Add a fetcher in `src/Entsoe.jl` (parallel to `fetch_outages`),
   unzip, parse, aggregate to hourly. Synthetic outages already proved
   the feature is worth it (`outage_capacity_lag_24h` was #2 by gain
   there).

## Suggested order (best-bang-per-hour first)

1. **Weather pull + retrain.** Half day. Wires up the user's headline ask.
2. **SEMO ISP pull → basis model on real data.** Half day. Unblocks the
   "trickier task" the user originally posed.
3. **A80 outage parser.** Half day. Likely 2–3 pp DAM skill on real data
   based on synthetic feature importance.
4. **Longer eval window + hyperparameter sweep** if skill is still under
   the user's target. The current backtest is 6 months; widening to 12+
   should let the calendar/holiday/DST flags learn rare-event patterns.

## Quick start

```bash
cp .env.example .env       # set ENTSOE_API_KEY (token already in shared .env)
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. scripts/fetch_data.jl --start 2023-01-01 --end <today>
julia --project=. scripts/run_backtest.jl --eval-start 2025-11-01 --eval-end 2026-04-30
```

For the basis run, once you've dropped `data/raw/imbalance_prices.arrow`:

```bash
julia --project=. scripts/run_basis_backtest.jl --eval-start 2025-11-01 --alpha 0.5
```

## Gotchas / fixed-but-worth-knowing

- **SEM load EIC is `10YIE-1001A00010` (IE only)**, NOT the unified
  `10Y1001A1001A59C`. The unified EIC works for DAM price and wind but
  silently returns an Acknowledgement document for load. Already fixed
  in `Entsoe.fetch_load_forecast` / `fetch_load_actual`.
- **Solar forecast on ENTSO-E is empty for SEM.** Solar capacity exists
  but isn't published as A69/B16. `solar_fcst` features will be zero;
  EvoTrees correctly ignores them.
- **BMRS WINDFOR has a 7-day window limit.** Chunked accordingly in
  `Gb.fetch_gb_wind_forecast`. Also it's forward-only — you can't
  backfill years of GB wind forecasts; the feature will be near-empty
  for backtest and the model ignores it. If you want historical GB
  wind use BMRS `FUELHH` (actual generation by fuel) instead and call
  it `gb_wind_actual` with a 24h lag.
- **Yahoo (TTF, EUA) returns JSON null** for non-trading days; converted
  to `missing` in `Commodities.fetch_yahoo_daily` so dropmissing works.
- **`.env` is gitignored.** Token doesn't reach the remote.

The detailed plan with full Tier-3 (Copernicus ERA5) costs is in
`/root/.claude/plans/create-a-modell-to-whimsical-fountain.md` if it
travels with you; if not, the README captures most of it.
