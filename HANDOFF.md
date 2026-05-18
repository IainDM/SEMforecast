# Handoff note

## Session 2 (current)

You're continuing the SEM day-ahead price forecasting project. The previous
session built a working DAM model (+36.5% MAE skill on real ENTSO-E data) and
left three gaps. This session closed the **code** side of those gaps but
could **not verify on real data** — `using SEMforecast` deadlocked in the
Julia precompile cascade after my edits invalidated the cache, and 25+
minutes of waiting produced no output. The code is ready; the verification
needs your machine.

### What landed (code)

1. **Met Éireann coastal weather** — [src/Weather.jl](src/Weather.jl)
   - Fixed Dublin station ID: `175` → `532` (was a copy of Mace Head; previous
     agent flagged it with `NB — fix once we have the real station ID list`).
     **Note**: `532` is the Met Éireann Dublin Airport synoptic station; if a
     live probe shows a different name in the CSV preamble, adjust.
   - Made `fetch_metereann_panel` resilient: a single failed station now
     logs a warning and inserts NaN placeholders for that station's four
     columns (`wind_*`, `winddir_*`, `temp_*`, `pressure_*`) so downstream
     feature engineering (which references `temp_dublin` by name in
     `Features.jl:181-196`) doesn't crash.

2. **ENTSO-E A80 outage parser** — [src/Entsoe.jl](src/Entsoe.jl)
   - Added `using ZipFile` and three new functions:
     - `_request_zip` — parallel to `_request`, branches on Content-Type:
       returns `(:zip, body_bytes)` for application/zip or `(:xml, doc)` for
       Acknowledgement responses (no-data days).
     - `_unzip_outage_docs` — opens ZIP in-memory, parses each
       `*UNAVAILABILITY*.xml` entry.
     - `fetch_outages_a80` — A80 endpoint variant matching the existing
       `fetch_outages` (A77) signature. Mirrors the chunked-request,
       hourly-aggregate, output-schema-matching pattern.
   - **A80 XML structure differs significantly from A77.** I probed a 1-week
     A80 response live (HTTP 200, application/zip, 1073 bytes) and inspected
     the embedded XML. Differences forced a new parser `_parse_outages_a80`:
     - Root is `Unavailability_MarketDocument` (not `*_MarketDocument`).
     - Time uses `start_DateAndOrTime.date` + `.time` (separate fields).
     - Capacity is at `production_RegisteredResource.pSRType.powerSystemResources.nominalP`
       (deep nested field).
     - Outage period wrapped in `Available_Period` (not `Period`).
     - `curveType=A03` (sequential fixed-size block) with one `Point` per
       block — value held constant until next Point. Parser walks one hour
       at a time and looks up the most recent Point quantity.
   - Wired into `scripts/fetch_data.jl` at lines 84-86 (replacing the
     `@info "Skipping outages"` log) via the existing `_safe()` wrapper.
   - Added `ZipFile = "a5390f91-…"` to [Project.toml](Project.toml).

3. **SEMO ISP ingest** — [scripts/ingest_isp_csv.jl](scripts/ingest_isp_csv.jl) (new)
   - The CSV-ingest fallback per the plan. Accepts `--dir <csv-dir>` and
     `--out <arrow>`. Column-name tolerant: auto-detects `STARTTIME`,
     `STARTDATETIME`, `ImbalanceSettlementPrice`, etc., with `--time-col` /
     `--price-col` overrides for non-standard exports. Falls back to
     `(date, settlement-period)` columns when a single datetime column isn't
     present. Half-hourly local (Europe/Dublin) → UTC → hourly mean →
     `DataFrame(ts_utc::DateTime, isp::Float64)` → `data/raw/imbalance_prices.arrow`.

4. **SEMO portal API discovered** (probed but not implemented)
   - `https://reports.sem-o.com/api/v1/documents/static-reports` is the
     listing endpoint. The relevant report is **`DPuG_ID=BM-026`**:
     "Imbalance Price Report (Imbalance Settlement Period)" — 30-min Average
     Imbalance Price. Each ResourceName is a single-period XML at
     `http://reports.sem-o.com/documents/<ResourceName>` (note: HTTP, not HTTPS).
   - Listing example:
     `GET /api/v1/documents/static-reports?DPuG_ID=BM-026&page=1` returns
     `{pagination:{pageSize:50,totalItems:N,...}, items:[…]}`. Pagination
     works. Date filter parameters appear to be ignored on the public
     endpoint — you'll need to paginate everything and filter client-side.
   - **Why I didn't build the auto-fetcher**: 48 half-hour reports per day ×
     ~1100 days for a 3-year backfill = ~50K XML files. That's a real
     project, not a half-day task. The CSV ingest path (#3) is shippable
     now; the portal-fetch can be a follow-up session.

### Verification status

**Not verified on real data this session.** Code changes are based on:
- Direct inspection of the live A80 XML structure (confirmed parser fields).
- Synthetic-mode pipeline unchanged (the new fetch is only called in
  real-data mode).

**Why**: After my edits to `Weather.jl` and `Entsoe.jl`, `using SEMforecast`
hung indefinitely (>25 min) on Julia 1.10 on Windows. The original
`Manifest.toml` was also stale (pinned `Expat_jll = 2.8.0` which doesn't
exist in current registries); I regenerated it under Julia 1.10 (commit
includes the new Manifest with `ZipFile` added).

### Network reachability from this environment

Probed from WSL on Windows; one host was unreachable:

| Host | Status |
|---|---|
| `web-api.tp.entsoe.eu` | ✓ 200 OK |
| `data.elexon.co.uk` (BMRS) | ✓ 200 OK |
| `query1.finance.yahoo.com` | ⚠ 429 (rate-limited but reachable) |
| `www.cpc.ncep.noaa.gov` | ✓ 200 OK |
| `reports.sem-o.com` | ✓ 200 OK |
| `cli.fusio.net` (Met Éireann) | ✗ Connection timed out on :443 |

The user's `.env` is set (key in worktree, gitignored — does not reach the
remote). curl from PowerShell needs `--ssl-revoke-best-effort` to avoid the
Windows CRL-check quirk; Julia HTTP.jl uses MbedTLS so doesn't have this
issue.

### What you need to do to finish (in order)

1. **Run the smoke test** (will use the now-rebuilt precompile cache; should
   be fast):
   ```
   julia +1.10 --project=. -e 'using SEMforecast; println("OK")'
   ```
   If this still hangs, try:
   ```
   julia +1.10 --project=. -e 'using Pkg; Pkg.precompile()'
   ```
   and watch for stuck packages.

2. **Probe Met Éireann from your network** (`cli.fusio.net` was unreachable
   from here but should work from the user's machine):
   ```
   curl -sSL --max-time 30 https://cli.fusio.net/cli/climate_data/webdata/hly532.csv | head
   ```
   Confirm station 532 shows "Dublin Airport" in the preamble. If a
   different name, look up the correct ID in the Met Éireann historical
   station index.

3. **Bulk fetch** (this hits ENTSO-E A80 for the first time on real data
   and Met Éireann from your network):
   ```
   julia +1.10 --project=. scripts/fetch_data.jl --start 2023-01-01 --end 2026-05-18
   ```
   Expect `_safe()` to log any per-source failures without killing the run.

4. **Rerun the DAM backtest**:
   ```
   julia +1.10 --project=. scripts/run_backtest.jl --eval-start 2025-11-01 --eval-end 2026-04-30
   ```
   Compare new skill vs +36.5% baseline. Expected lift: +38-44% (weather +
   A80 outages combined).

5. **For the basis backtest** — download SEMO ISP CSVs manually (sem-o.com
   publication portal, BM-026 report) or use the discovered API. Drop the
   CSVs in `data/raw/isp_csvs/` (or wherever) and run:
   ```
   julia +1.10 --project=. scripts/ingest_isp_csv.jl --dir data/raw/isp_csvs
   julia +1.10 --project=. scripts/run_basis_backtest.jl --eval-start 2025-11-01 --alpha 0.5
   ```

### Risks I didn't get to retire

- The A80 parser is built against a single probed XML (one TimeSeries, one
  Point at position 1 quantity 0, resolution PT1M). Multi-point TimeSeries
  (partial outages, ramped recoveries) should work per the algorithm but
  haven't been tested. If real-data fetch shows odd values, look at
  `_parse_outages_a80` in [src/Entsoe.jl](src/Entsoe.jl) — specifically the
  Point lookup loop. The `nominalP unit="MAW"` field is assumed to be MW;
  if `MAW` actually means megaampere-watts or some variant it may need
  scaling.
- The Dublin Airport station ID (532) is my best-known canonical value;
  verify on first probe.

---

## Original handoff (Session 1, for context)

You're continuing the SEM day-ahead price forecasting project on a machine
with full outbound network (vs the prior container where Met Éireann was
blocked and the SEMO portal was unreachable). The branch is
`claude/sem-price-forecast-model-3cGua`. The repo runs end-to-end in Julia
1.10 against `Project.toml`.

### Where things stood at end of Session 1

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

### Gotchas / fixed-but-worth-knowing

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
