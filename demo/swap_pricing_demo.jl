# demo/swap_pricing_demo.jl
#
# Demonstrates the SwapPricing module: building a swap, pricing it with a
# StandardSwapPricer, computing the par rate and Macaulay duration, and
# settling the swap early.

using QuantitativeLib
using QuantitativeLib.SwapPricing
using Dates

# --------------------------------------------------------------------------
# 1. Build a discount curve
# --------------------------------------------------------------------------
# The swap pricer stores discount factors directly (not zero rates). We
# convert from continuously-compounded zero rates here.
const _issue_date = Date(2020, 1, 1)
_zero_rates = [(0.0,  0.02), (1.0,  0.025), (2.0,  0.03)]  # (tenor, zero rate)
_curve_nodes = [(Date(2020, 1, 1) + Dates.Year(Int(round(y))), exp(-r * y)) for (y, r) in _zero_rates]

pricer = StandardSwapPricer(_curve_nodes)

println("=" ^ 60)
println("  Swap Pricing Demo")
println("=" ^ 60)

println("\n[Discount curve]")
for (d, df) in _curve_nodes
    t = SwapPricing.time_to_maturity(_issue_date, d)
    # Recover the zero rate from the discount factor for display.
    zr = t > 0 ? -log(df) / t : _zero_rates[1][2]
    println("  $(d)  tenor=$(round(t, digits=2))y  DF=$(round(df, digits=4))  z=$(round(zr * 100, digits=2))%")
end

# --------------------------------------------------------------------------
# 2. Build a plain-vanilla interest-rate swap
# --------------------------------------------------------------------------
# Notional: $1,000,000 · Fixed rate: 3.0% · Semi-annual payments
# Fixed leg and floating leg share the same payment schedule for this demo.
notional = 1_000_000.0
fixed_rate = 0.03
start_date = Date(2020, 1, 1)
end_date   = Date(2022, 1, 1)

fixed_payments = Payment[
    Payment(Date(2020, 7, 1), notional, fixed_rate, start_date, Date(2020, 7, 1), "ACTUAL_ACTUAL"),
    Payment(Date(2021, 1, 1), notional, fixed_rate, Date(2020, 7, 1), Date(2021, 1, 1), "ACTUAL_ACTUAL"),
    Payment(Date(2021, 7, 1), notional, fixed_rate, Date(2021, 1, 1), Date(2021, 7, 1), "ACTUAL_ACTUAL"),
    Payment(Date(2022, 1, 1), notional, fixed_rate, Date(2021, 7, 1), end_date,   "ACTUAL_ACTUAL"),
]

floating_rate = 0.025   # assumed floating rate for the demo
floating_payments = Payment[
    Payment(Date(2020, 7, 1), notional, floating_rate, start_date, Date(2020, 7, 1), "ACTUAL_ACTUAL"),
    Payment(Date(2021, 1, 1), notional, floating_rate, Date(2020, 7, 1), Date(2021, 1, 1), "ACTUAL_ACTUAL"),
    Payment(Date(2021, 7, 1), notional, floating_rate, Date(2021, 1, 1), Date(2021, 7, 1), "ACTUAL_ACTUAL"),
    Payment(Date(2022, 1, 1), notional, floating_rate, Date(2021, 7, 1), end_date,   "ACTUAL_ACTUAL"),
]

fixed_leg = SwapLeg(fixed_payments, "ACTUAL_ACTUAL")
floating_leg = SwapLeg(floating_payments, "ACTUAL_ACTUAL")
swap = Swap(fixed_leg, floating_leg, start_date, end_date, notional, 0.0)

println("\n[Swap structure]")
println("  Notional:     $(round(notional, digits=2))")
println("  Fixed rate:   $(round(fixed_rate * 100, digits=2))%")
println("  Floating rate: $(round(floating_rate * 100, digits=2))% (assumed)")
println("  Tenor:        $start_date → $end_date")
println("  Payments:")
for (leg_name, leg) in [("Fixed", fixed_leg), ("Floating", floating_leg)]
    for p in leg.payments
        println("    $leg_name  $(p.date)  amount=$(round(p.amount, digits=2))")
    end
end

# --------------------------------------------------------------------------
# 3. Present value of each leg
# --------------------------------------------------------------------------
fixed_pv  = present_value(fixed_leg.payments,  pricer)
float_pv  = present_value(floating_leg.payments, pricer)

println("\n[Present values]")
println("  Fixed leg   PV = $(round(fixed_pv,  digits=2))")
println("  Floating leg PV = $(round(float_pv, digits=2))")
println("  Swap NPV    = $(round(fixed_pv - float_pv, digits=2))  (fixed − floating)")

# --------------------------------------------------------------------------
# 4. Par rate
# --------------------------------------------------------------------------
par = par_rate(swap, pricer)
println("\n[Par rate]")
println("  Par fixed rate = $(round(par * 100, digits=4))%")
println("  (The rate that makes the swap NPV = 0 at valuation)")

# --------------------------------------------------------------------------
# 5. Macaulay duration
# --------------------------------------------------------------------------
dur = modified_duration(swap, pricer)
println("\n[Macaulay duration]")
println("  Duration = $(round(dur, digits=4)) years")
println("  (Weighted-average time to fixed-leg cash flows, discounted)")

# --------------------------------------------------------------------------
# 6. Early settlement
# --------------------------------------------------------------------------
settle_date = Date(2020, 10, 1)   # settle mid-period, between 2nd and 3rd payment
settled = settle_swap(swap, settle_date, notional)

println("\n[Early settlement]")
println("  Settlement date: $settle_date")
if isempty(settled)
    println("  No remaining accrued payments.")
else
    for sp in settled
        leg_type = sp.original_payment ∈ fixed_leg.payments ? "Fixed" : "Floating"
        println("  $leg_type  $(sp.original_payment.date)  accrued=$(round(sp.adjusted_amount, digits=2))")
    end
end

# --------------------------------------------------------------------------
# 7. Discount-factor lookup (demonstrates the new error behaviour)
# --------------------------------------------------------------------------
println("\n[Discount-factor lookup]")
df_1y = SwapPricing.discount_factor(pricer, Date(2021, 1, 1))
println("  DF(2021-01-01) = $(round(df_1y, digits=6))")

# Extrapolation beyond the curve (flat at last forward rate) — no error.
df_3y = SwapPricing.discount_factor(pricer, Date(2023, 1, 1))
println("  DF(2023-01-01) = $(round(df_3y, digits=6))  (extrapolated)")

println("\n" * "=" ^ 60)
println("  Demo complete.")
println("=" ^ 60)
