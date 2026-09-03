# demo/coupon_bond_demo.jl
#
# Demonstrates pricing a 4-year $100 face-value CouponBond with a 5%
# semiannual coupon using a risk-free rate of 4.6% under continuous
# compounding.
#
# Also shows: tenor, per-period discount factors, individual cash-flow
# contributions, and the two compounding modes supported by BondPricer.

using QuantitativeLib
using QuantitativeLib.Pricers
using QuantitativeLib.QuantitativeCore: InstrumentCalendar, PeriodDays, add_period!, add_periods
using Dates

# --------------------------------------------------------------------------
# 1. Bond parameters
# --------------------------------------------------------------------------
issue_date  = Date(2020, 1, 1)
maturity    = Date(2024, 1, 1)          # 4 years
face_value  = 100.0
coupon_rate = 0.05                      # 5% annual, paid semiannually
risk_free   = 0.046                     # 4.6% annual discount rate
semi        = PeriodDays(182)           # approximate 6-month spacing

# --------------------------------------------------------------------------
# 2. Build the payment schedule
# --------------------------------------------------------------------------
# Build the payment schedule manually: 8 semiannual periods over 4 years.
# 2020–2024 contains one leap day, so the total span is 1461 days.
# We alternate 182 / 183-day periods to land exactly on the maturity date.
_schedule_dates = Date[issue_date,
    Date(2020, 7, 1), Date(2020, 12, 31),
    Date(2021, 6, 30), Date(2021, 12, 31),
    Date(2022, 6, 30), Date(2022, 12, 30),
    Date(2023, 6, 30), maturity,
]
cal = InstrumentCalendar(_schedule_dates)

@assert cal.days[1] == issue_date "First entry must be the issue date"
@assert cal.days[end] == maturity "Last entry must be the maturity date"

bond = CouponBond(issue_date, cal, coupon_rate, face_value)
generate_coupons!(bond)

println("=" ^ 70)
println("  Coupon Bond Pricing Demo")
println("=" ^ 70)

println("\n[Bond parameters]")
println("  Issue date:        $issue_date")
println("  Maturity:          $maturity  ($((maturity - issue_date).value / 365.0) years)")
println("  Face value:        $(bond.face_value)")
println("  Coupon rate:       $(round(coupon_rate * 100, digits=1))%  (semiannual)")
println("  Number of coupons: $(length(bond.coupons))")

# --------------------------------------------------------------------------
# 3. Continuous-compounding pricer
# --------------------------------------------------------------------------
pricer_c = BondPricer(bond, risk_free, ContinuousInterest())
price_c  = price(pricer_c)

println("\n[Pricing — continuous compounding]")
println("  Discount rate:     $(round(risk_free * 100, digits=1))%")
println("  Bond price:        $(round(price_c, digits=4))")
println("  Par:               $(round(face_value, digits=2))")
println("  Premium / (discount): $(round(price_c - face_value, digits=4))")

println("\n[Cash flows and discounted contributions]")
header = "  " * lpad("Date", 12) * "  " * lpad("Coupon", 10) * "  " * lpad("DF", 10) * "  " * lpad("PV", 12)
println(header)
println("  " * "-" ^ 50)
for cf in bond.coupons
    df   = Pricers.discount_factor(pricer_c, cf.date)
    pv   = cf.amount * df
    println("  $(string(cf.date))  $(round(cf.amount, digits=4))  $(round(df, digits=6))  $(round(pv, digits=4))")
end
# Face value at maturity is added by price() but not stored as a Coupon.
df_m  = Pricers.discount_factor(pricer_c, maturity)
pv_mv = face_value * df_m
println("  $(string(maturity))  $(round(face_value, digits=4))  $(round(df_m, digits=6))  $(round(pv_mv, digits=4))")
println("  " * "-" ^ 50)
println("  " * lpad("", 12) * "  " * lpad("TOTAL", 10) * "  " * lpad("", 10) * "  $(round(price_c, digits=4))")

# --------------------------------------------------------------------------
# 4. Simple-compounding pricer for comparison
# --------------------------------------------------------------------------
pricer_s = BondPricer(bond, risk_free, SimpleInterest())
price_s  = price(pricer_s)

println("\n[Pricing — simple compounding]")
println("  Discount rate:     $(round(risk_free * 100, digits=1))%")
println("  Bond price:        $(round(price_s, digits=4))")

# --------------------------------------------------------------------------
# 5. Per-period discount factors
# --------------------------------------------------------------------------
println("\n[Per-period discount factors (continuous)]")
println("  " * lpad("Period", 8) * "  " * lpad("Date", 12) * "  " * lpad("Tenor(y)", 10) * "  " * lpad("DF", 10))
println("  " * "-" ^ 45)
total_tenor = (maturity - issue_date).value / 365.0
for (i, cf) in enumerate(bond.coupons)
    t_actual = (cf.date - issue_date).value / 365.0
    df = Pricers.discount_factor(pricer_c, cf.date)
    marker = cf.date == maturity ? "  + face" : ""
    println("  $(i)        $(string(cf.date))  $(round(t_actual, digits=4))  $(round(df, digits=6))$marker")
end

# --------------------------------------------------------------------------
# 6. Sensitivity: price at nearby rates
# --------------------------------------------------------------------------
println("\n[Yield–price sensitivity]")
println("  " * lpad("Rate", 8) * "  " * lpad("Price", 12) * "  " * lpad("Chg", 10))
println("  " * "-" ^ 35)
for dr in [0.02, 0.03, 0.04, 0.046, 0.05, 0.06, 0.07]
    p = price(BondPricer(bond, dr, ContinuousInterest()))
   chg = round(p - price_c, digits=4)
    sign_str = chg > 0 ? "+" : ""
    println("  $(round(dr * 100, digits=1))%      $(round(p, digits=4))  $(sign_str)$(round(chg, digits=4))")
end

println("\n" * "=" ^ 70)
println("  Demo complete.")
println("=" ^ 70)
