module QuantitativeLib

export QuantitativeCore, Pricers, Instruments

include("./QuantitativeCore.jl")

using .QuantitativeCore  # Bring the submodule's contents into the main scope
export return2           # Pass return2 up to the very top level

include("./Instruments.jl")

include("./Pricers.jl")

using .Pricers
export Pricer, BlackScholesPricer, HullWhitePricer

include("SwapPricing.jl")

end
