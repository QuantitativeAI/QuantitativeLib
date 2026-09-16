include("src/QuantitativeLib.jl")
using Dates
using Test

println("=== Portfolio tests ===")
issue = Date(2026, 1, 1)
curve = QuantitativeLib.ZeroCurve(issue, [
    (Date(2027, 1, 1), 0.02),
    (Date(2028, 1, 1), 0.03),
    (Date(2029, 1, 1), 0.035),
])

zcb = QuantitativeLib.ZeroCouponBond(issue, Date(2028, 1, 1), 100.0)
v_zcb = QuantitativeLib.market_value(zcb, curve)
@test v_zcb ≈ 100.0 * QuantitativeLib.discount_factor(curve, Date(2028, 1, 1))
println("ZCB value ok ($(round(v_zcb, digits=4)))")

cal = QuantitativeLib.InstrumentCalendar([Date(2026, 7, 1), Date(2027, 1, 1)])
cb = QuantitativeLib.CouponBond(issue, cal, 0.04, 100.0)
# Call through the module path to avoid any name resolution issues
QuantitativeLib.Instruments.generate_coupons!(cb)
v_cb = QuantitativeLib.market_value(cb, curve)
@test v_cb ≈ sum(amount * QuantitativeLib.discount_factor(curve, date) for (date, amount) in QuantitativeLib.cash_flows(cb))
println("Coupon bond value ok ($(round(v_cb, digits=4)))")

p = QuantitativeLib.Portfolio("Test"; valuation_date=issue)
QuantitativeLib.add_instrument!(p, zcb, 2.0)
QuantitativeLib.add_instrument!(p, cb, 1.0)
v_p = QuantitativeLib.market_value(p, curve)
@test v_p ≈ 2.0 * v_zcb + 1.0 * v_cb
println("Portfolio value ok ($(round(v_p, digits=4)))")

inner = QuantitativeLib.Portfolio("Inner"; valuation_date=issue)
QuantitativeLib.add_instrument!(inner, zcb, 1.0)
outer = QuantitativeLib.Portfolio("Outer"; valuation_date=issue)
QuantitativeLib.add_instrument!(outer, inner, 3.0)
QuantitativeLib.add_instrument!(outer, cb, 1.0)
@test QuantitativeLib.market_value(outer, curve) ≈ 3.0 * v_zcb + 1.0 * v_cb
println("Nested portfolio ok")

dur_num = QuantitativeLib.duration(p, curve)
dur_ana = QuantitativeLib.macaulay_duration(p, curve)
@test abs(dur_num - dur_ana) < 1e-6
println("Duration match ok (num=$dur_num, ana=$dur_ana)")

@test QuantitativeLib.convexity(p, curve) > 0
println("Convexity ok")

krd = QuantitativeLib.key_rate_durations(p, curve)
@test length(krd) == 3
@test krd[1] < 0.0
@test krd[2] < 0.0
@test krd[3] == 0.0  # no cash flows beyond node 2
println("KRD ok (length=$(length(krd)))")

y = QuantitativeLib.portfolio_yield(p, curve)
flows = QuantitativeLib.cash_flows(p)
pv_y = sum(amount * exp(-y * QuantitativeLib.tenor(curve, date)) for (date, amount) in flows)
@test abs(pv_y - v_p) < 1e-8
println("Yield ok ($(round(y*100, digits=4))%)")

horizon = Date(2027, 1, 1)
ret = QuantitativeLib.expected_return(p, curve, horizon)
@test abs(ret - (1.0 / QuantitativeLib.discount_factor(curve, horizon) - 1.0)) < 1e-10
println("Expected return ok ($(round(ret*100, digits=4))%)")

using QuantitativeLib.SwapPricing
notional = 1_000_000.0
fixed_rate = 0.02
float_rate = 0.02
dates_s = [Date(2027, 1, 1), Date(2028, 1, 1)]
fp = QuantitativeLib.SwapPricing.Payment[QuantitativeLib.SwapPricing.Payment(dates_s[1], notional, fixed_rate, issue, dates_s[1], "ACTUAL_ACTUAL"),
             QuantitativeLib.SwapPricing.Payment(dates_s[2], notional, fixed_rate, dates_s[1], dates_s[2], "ACTUAL_ACTUAL")]
flp = QuantitativeLib.SwapPricing.Payment[]
prev = issue
for px in fp
    push!(flp, QuantitativeLib.SwapPricing.Payment(px.date, notional, float_rate, prev, px.date, px.convention))
    global prev = px.date
end
sw = QuantitativeLib.SwapPricing.Swap(QuantitativeLib.SwapPricing.SwapLeg(fp), QuantitativeLib.SwapPricing.SwapLeg(flp), issue, dates_s[2], notional, 0.0)
@test abs(QuantitativeLib.market_value(sw, curve)) < 1e-5
println("Par swap value ok")

shifted = QuantitativeLib.shifted_curve(curve, 2, 0.001)
@test shifted.nodes[2][2] == curve.nodes[2][2] + 0.001
parallel = QuantitativeLib.parallel_shifted_curve(curve, -0.0005)
@test all(n[2] == c[2] - 0.0005 for (c, n) in zip(curve.nodes, parallel.nodes))
println("Curve shifts ok")

println("\nAll portfolio tests passed!")
