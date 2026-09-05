module QuantitativeLib

export QuantitativeCore, Pricers, Instruments

include("./QuantitativeCore.jl")

using .QuantitativeCore  # Bring the submodule's contents into the main scope
export return2           # Pass return2 up to the very top level

include("./Instruments.jl")

include("./Pricers.jl")

using .Instruments
export Bond, ZeroCouponBond, CouponBond, Coupon, Option, generate_coupons!

using .Pricers
export Pricer, BlackScholesPricer, HullWhitePricer, BondPricer, price
export InterestMode, ContinuousInterest, SimpleInterest

include("./Curves.jl")
using .Curves
export InterestCurve, ZeroCurve
export tenor, zero_rate, discount_factor, forward_rate
export BondQuote, cash_flows, bootstrap_zero_curve

include("./SwapPricing.jl")

include("./MonteCarloPricing.jl")
using .MonteCarloPricing
export colwise_simulate_stock_prices, priceCallOption, priceCallOptionBroadcasted

end
