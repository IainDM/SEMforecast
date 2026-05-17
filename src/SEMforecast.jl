module SEMforecast

include("Config.jl")
include("Calendar.jl")
include("Entsoe.jl")
include("Commodities.jl")
include("Features.jl")
include("Baseline.jl")
include("Model.jl")
include("Backtest.jl")
include("Report.jl")

# Basis (ISP − DA) prediction with conformal-calibrated abstention.
include("BasisFeatures.jl")
include("QuantileModel.jl")
include("Conformal.jl")
include("BasisBacktest.jl")
include("BasisReport.jl")

using .Config
using .Calendar
using .Entsoe
using .Commodities
using .Features
using .Baseline
using .Model
using .Backtest
using .Report
using .BasisFeatures
using .QuantileModel
using .Conformal
using .BasisBacktest
using .BasisReport

export Config, Calendar, Entsoe, Commodities, Features,
       Baseline, Model, Backtest, Report,
       BasisFeatures, QuantileModel, Conformal, BasisBacktest, BasisReport

end # module
