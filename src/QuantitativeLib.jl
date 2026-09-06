module QuantitativeLib

export QuantitativeCore, Pricers, Instruments

include("./SystemConfig.jl")
using .SystemConfig
export Config

include("./QuantitativeCore.jl")

using .QuantitativeCore  # Bring the submodule's contents into the main scope
export return2           # Pass return2 up to the very top level

include("./Instruments.jl")

include("./Pricers.jl")

using .Instruments
export Bond, ZeroCouponBond, CouponBond, Coupon, Option, generate_coupons!
using .Instruments: Option  # Ensure Option is available in main scope

using .Pricers
export Pricer, BlackScholesPricer, HullWhitePricer, BondPricer, price
export InterestMode, ContinuousInterest, SimpleInterest

include("./Curves.jl")
using .Curves
export InterestCurve, ZeroCurve
export tenor, zero_rate, discount_factor, forward_rate
export BondQuote, cash_flows, bootstrap_zero_curve
export AbstractInterpolation, Linear, CubicSpline
export make_curve, get_rate, get_discount_factor, get_forward_rate
export RateType, RateNode, yearfrac, VolSurface
export ZeroRate, ForwardRate, DiscountFactor, SwapRate, LiborRate, SofrRate
export YieldCurve, ForwardCurve, DiscountCurve, BasisCurve, CreditCurve
export interpolate_vol, bootstrap_yield_curve

include("./SwapPricing.jl")

include("./MonteCarloPricing.jl")
using .MonteCarloPricing
export colwise_simulate_stock_prices, priceCallOption, priceCallOptionBroadcasted

# Re-export SystemConfig accessors at top level for convenience
export day_count, default_digits, trading_days_year, default_day_count, curve_day_count

end
