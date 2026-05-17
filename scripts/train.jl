#!/usr/bin/env julia
# Train the final model on all available cached data and serialise it.
#
# Usage:
#   julia --project=. scripts/train.jl [--out models_cache/sem_model.jls]

using Pkg
Pkg.activate(normpath(joinpath(@__DIR__, "..")))

using ArgParse
using Dates
using DataFrames
using Logging
using Serialization

using SEMforecast
using SEMforecast: Config, Entsoe, Commodities, Features, Model

function parse_args_()
    s = ArgParseSettings(description = "Train final SEM DAM forecast model")
    @add_arg_table! s begin
        "--out"; arg_type = String; default = ""; help = "Output path (.jls)"
    end
    return parse_args(s)
end

function main()
    args = parse_args_()
    Config.load_dotenv()
    Config.ensure_dirs()
    outpath = isempty(args["out"]) ?
              joinpath(Config.MODELS_DIR, "sem_model.jls") :
              args["out"]

    @info "Loading cached data"
    prices = Entsoe.load("dam_prices")
    load   = Entsoe.load("load_forecast")
    wind   = Entsoe.load("wind_forecast")
    solar  = try; Entsoe.load("solar_forecast"); catch
        DataFrame(ts_utc = DateTime[], solar_fcst = Float64[])
    end
    com = Commodities.load("commodities")

    panel = Features.build_panel(prices = prices, load = load,
                                 wind = wind, solar = solar, commodities = com)
    feat = Features.add_features(panel)
    sort!(feat, [:date, :hour])
    fc = Features.feature_columns(feat)

    cut = maximum(feat.date) - Day(21)
    train = feat[feat.date .<= cut, :]
    eval  = feat[feat.date .>  cut, :]
    @info "Training" train_rows=nrow(train) eval_rows=nrow(eval) features=length(fc)

    model = Model.fit(train, fc; eval_df = eval, verbose = true)
    serialize(outpath, (model = model, trained_at = now(),
                        feature_cols = fc))
    @info "Model serialised" path=outpath
end

main()
