# demo/portfolio_demo.jl
#
# Demonstrates the Portfolio module: building a mixed portfolio (zero-coupon
# bonds, coupon bonds, a swap, a nested portfolio), valuing it against a
# zero-rate curve, and computing duration, convexity, key-rate durations,
# yield, and the curve-consistent baseline return.
#
# Run with:
#   julia --project demo/portfolio_demo.jl
# or directly (includes the source):
#   julia --project -e 'include("src/QuantitativeLib.jl"); using .QuantitativeLib; ...'

using QuantitativeLib
using QuantitativeLib.SwapPricing
using Dates

println("==============================================================")
println("  QuantitativeLib  --  Portfolio Management Demo")
println("==============================================================")

# --------------------------------------------------------------------------
# 1. Build a zero-rate curve
# --------------------------------------------------------------------------
issue = Date(2026, 1, 1)
curve = QuantitativeLib.ZeroCurve(issue, [
    (Date(2027, 1, 1), 0.020),
    (Date(2028, 1, 1), 0.030),
    (Date(2029, 1, 1), 0.035),
    (Date(2030, 1, 1), 0.038),
])

println("\n[Curve]")
for (d, z) in curve.nodes
    t = QuantitativeLib.tenor(curve, d)
    println("  $(d)  tenor=$(round(t, digits=2))y  zero_rate=$(round(z * 100, digits=2))%  DF=$(round(QuantitativeLib.discount_factor(curve, d), digits=4))")
end

# --------------------------------------------------------------------------
# 2. Build instruments
# --------------------------------------------------------------------------
println("\n[Instruments]")

zcb = QuantitativeLib.ZeroCouponBond(issue, Date(2028, 1, 1), 100.0)
println("  ZCB    maturity=$(zcb.maturity)  face=$(zcb.face_value)")

cal = QuantitativeLib.InstrumentCalendar([Date(2026, 7, 1), Date(2027, 1, 1)])
cb = QuantitativeLib.CouponBond(issue, cal, 0.04, 100.0)
QuantitativeLib.generate_coupons!(cb)
println("  Coupon bond  maturity=$(cb.maturity)  coupon_rate=$(round(cb.coupon_rate * 100, digits=1))%")

notional = 1_000_000.0
fixed_rate = 0.025
float_rate = 0.025
dates_s = [Date(2027, 1, 1), Date(2028, 1, 1)]
fp = QuantitativeLib.SwapPricing.Payment[QuantitativeLib.SwapPricing.Payment(dates_s[1], notional, fixed_rate, issue, dates_s[1], "ACTUAL_ACTUAL"),
             QuantitativeLib.SwapPricing.Payment(dates_s[2], notional, fixed_rate, dates_s[1], dates_s[2], "ACTUAL_ACTUAL")]
flp = QuantitativeLib.SwapPricing.Payment[QuantitativeLib.SwapPricing.Payment(dates_s[1], notional, float_rate, issue, dates_s[1], "ACTUAL_ACTUAL"),
              QuantitativeLib.SwapPricing.Payment(dates_s[2], notional, float_rate, dates_s[1], dates_s[2], "ACTUAL_ACTUAL")]
swap = QuantitativeLib.SwapPricing.Swap(QuantitativeLib.SwapPricing.SwapLeg(fp), QuantitativeLib.SwapPricing.SwapLeg(flp), issue, dates_s[2], notional, 0.0)
println("  Swap  notional=$(round(notional, digits=0))  fixed=$(round(fixed_rate * 100, digits=2))%")

# --------------------------------------------------------------------------
# 3. Build a mixed portfolio
# --------------------------------------------------------------------------
println("\n[Portfolio]")
portfolio = QuantitativeLib.Portfolio("MixedPortfolio"; valuation_date=issue)
QuantitativeLib.add_instrument!(portfolio, zcb, 5.0, "ZCB_3y")
QuantitativeLib.add_instrument!(portfolio, cb, 2.0, "Coupon_3y")
sleeve = QuantitativeLib.Portfolio("ShortSleeve"; valuation_date=issue)
QuantitativeLib.add_instrument!(sleeve, zcb, 3.0, "ZCB_2y")
QuantitativeLib.add_instrument!(portfolio, sleeve, 1.0, "ShortSleeve")
QuantitativeLib.add_instrument!(portfolio, swap, 1.0, "ParSwap")

println("  Holdings: $(length(QuantitativeLib.holdings(portfolio)))")
for h in QuantitativeLib.holdings(portfolio)
    println("    $(h.name)  qty=$(h.quantity)")
end

# --------------------------------------------------------------------------
# 4. Valuation
# --------------------------------------------------------------------------
println("\n[Valuation]")
v = QuantitativeLib.market_value(portfolio, curve)
println("  Market value = $(round(v, digits=2))")
println("  Per-instrument breakdown:")
for h in QuantitativeLib.holdings(portfolio)
    inst_v = QuantitativeLib.market_value(h.instrument, curve)
    println("    $(h.name): qty=$(h.quantity)  sub_value=$(round(h.quantity * inst_v, digits=2))")
end

# --------------------------------------------------------------------------
# 5. Risk metrics
# --------------------------------------------------------------------------
println("\n[Risk metrics]")
dur = QuantitativeLib.duration(portfolio, curve)
dur_ana = QuantitativeLib.macaulay_duration(portfolio, curve)
println("  Duration (years) = $(round(dur, digits=4))  (analytical Macaulay = $(round(dur_ana, digits=4)))")
println("  Convexity = $(round(QuantitativeLib.convexity(portfolio, curve), digits=4))")
krd = QuantitativeLib.key_rate_durations(portfolio, curve)
println("  Key-rate durations (currency/bp per node):")
for (i, kr) in enumerate(krd)
    t = QuantitativeLib.tenor(curve, curve.nodes[i][1])
    println("    node $i  tenor=$(round(t, digits=2))y  KRD=$(round(kr, digits=2))")
end

# --------------------------------------------------------------------------
# 6. Yield & baseline return
# --------------------------------------------------------------------------
println("\n[Yield & baseline return]")
y = QuantitativeLib.portfolio_yield(portfolio, curve)
println("  Portfolio yield (cc) = $(round(y * 100, digits=4))%")
horizon = Date(2027, 1, 1)
ret = QuantitativeLib.expected_return(portfolio, curve, horizon)
println("  Baseline return [$(issue) -> $(horizon)] = $(round(ret * 100, digits=4))%")

# --------------------------------------------------------------------------
# 7. Stress scenarios
# --------------------------------------------------------------------------
println("\n[Stress scenarios]")
for delta in [-0.01, -0.005, 0.0, 0.005, 0.01]
    v_s = QuantitativeLib.market_value(portfolio, QuantitativeLib.parallel_shifted_curve(curve, delta))
    println("  parallel shift $(round(delta * 100, digits=2))%  ->  V=$(round(v_s, digits=2))")
end

println("\n  Key-rate P&L (10bp shift per node):")
for i in 1:length(curve.nodes)
    v_s = QuantitativeLib.market_value(portfolio, QuantitativeLib.shifted_curve(curve, i, 0.001))
    println("    shift node $i by +10bp  ->  V=$(round(v_s, digits=2))  dV=$(round(v_s - v, digits=2))")
end

println("\n==============================================================")
println("  Demo complete.")
println("==============================================================")
