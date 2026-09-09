# Quick Start Guide

A minimal guide to get up and running with QuantitativeLib in under 5 minutes.

## What is QuantitativeLib?

A Julia library for fixed-income pricing, interest-rate curve construction, swap analytics, and Monte Carlo option pricing.

## Installation

Start Julia and run:

```julia
using Pkg
Pkg.add(path="./QuantitativeLib")   # if cloned locally
# or
Pkg.add("QuantitativeLib")          # if registered
```

No external packages are required beyond the Julia standard library (the only third-party dependency is `Interpolations`, pulled in automatically).

## First 30 seconds

```julia
using QuantitativeLib
using Dates

# Price a zero-coupon bond
bond = ZeroCouponBond(Date(2024, 1, 1), Date(2026, 1, 1), 100.0)
price = QuantitativeLib.price(BondPricer(bond, 0.05))
println("Bond price: $price")   # → 90.4837
```

That's it — you're pricing.

---

## Feature Walkthroughs

### 1. Bond Pricing

```julia
using QuantitativeLib
using QuantitativeLib.QuantitativeCore: InstrumentCalendar, add_periods
using Dates

# Zero-coupon bond
zcb = ZeroCouponBond(Date(2024, 1, 1), Date(2026, 1, 1), 100.0)
p_c = BondPricer(zcb, 0.05)
println("Zero-coupon price (continuous): $(price(p_c))")

# Coupon bond — build a semiannual payment schedule
cal = InstrumentCalendar([Date(2024, 1, 1)])       # anchor = issue date
add_periods(cal, Date(2024, 7, 1), 182, 4)          # 4 semiannual payments
cb = CouponBond(Date(2024, 1, 1), cal, 0.05, 100.0)
generate_coupons!(cb)

p_cb = BondPricer(cb, 0.05)
println("Coupon bond price: $(price(p_cb))")

# Simple compounding (instead of the default continuous)
p_simple = BondPricer(zcb, 0.05, SimpleInterest())
println("Zero-coupon price (simple):   $(price(p_simple))")
```

### 2. Interest-Rate Curves

```julia
using QuantitativeLib
using Dates

issue = Date(2026, 1, 1)
curve = ZeroCurve(issue, [
    (Date(2027, 1, 1), 0.02),
    (Date(2028, 1, 1), 0.03),
])

# Query the curve
println("Zero rate at 1y: $(zero_rate(curve, Date(2027, 1, 1)))")
println("DF at 1.5y:    $(discount_factor(curve, Date(2027, 7, 1)))")
println("Forward 1y→2y: $(forward_rate(curve, Date(2027, 1, 1), Date(2028, 1, 1)))")

# Bootstrap a curve from bond quotes
q1 = BondQuote(ZeroCouponBond(issue, Date(2027, 1, 1)), 98.0)
q2 = BondQuote(ZeroCouponBond(issue, Date(2028, 1, 1)), 95.0)
bootstrapped = bootstrap_zero_curve(issue, [q1, q2])
```

### 3. Swap Pricing

```julia
using QuantitativeLib
using QuantitativeLib.SwapPricing
using Dates

notional   = 1_000_000.0
fixed_rate = 0.03
start      = Date(2020, 1, 1)
maturity   = Date(2022, 1, 1)

# Build a discount curve (continuously-compounded zero rates → DFs)
curve_nodes = [(start + Year(y), exp(-r * y)) for (y, r) in [(0.0, 0.02), (1.0, 0.025), (2.0, 0.03)]]
pricer = StandardSwapPricer(curve_nodes)

# Build the swap legs
fixed_payments = Payment[
    Payment(Date(2020, 7, 1), notional, fixed_rate, start, Date(2020, 7, 1), "ACTUAL_ACTUAL"),
    Payment(Date(2021, 1, 1), notional, fixed_rate, Date(2020, 7, 1), Date(2021, 1, 1), "ACTUAL_ACTUAL"),
    Payment(Date(2021, 7, 1), notional, fixed_rate, Date(2021, 1, 1), Date(2021, 7, 1), "ACTUAL_ACTUAL"),
    Payment(Date(2022, 1, 1), notional, fixed_rate, Date(2021, 7, 1), maturity,   "ACTUAL_ACTUAL"),
]
floating_payments = copy(fixed_payments)   # same schedule, different rate for demo

swap = Swap(SwapLeg(fixed_payments), SwapLeg(floating_payments), start, maturity, notional)

println("Swap NPV:   $(round(present_value(fixed_payments, pricer) - present_value(floating_payments, pricer), digits=2))")
println("Par rate:   $(round(par_rate(swap, pricer) * 100, digits=4))%")
println("Duration:   $(round(modified_duration(swap, pricer), digits=4)) years")
```

### 4. Monte Carlo Option Pricing

```julia
using QuantitativeLib
using QuantitativeLib.Instruments: Option
using Dates

option = Option(100.0, 100.0, Date(2027, 1, 1), 0.2, 0.05, 0.0)

trading_days = Int(floor((option.expiry_date - Date(2026, 9, 4)).value * 252 / 365))
prices = colwise_simulate_stock_prices(
    option.underlying_price, option.risk_free_rate,
    option.volatility, trading_days, 10_000
)

price_bc   = priceCallOptionBroadcasted(prices, option.risk_free_rate,
                                        trading_days / 252.0, option.strike_price)
price_thr  = priceCallOption(prices, option.risk_free_rate,
                             trading_days / 252.0, option.strike_price)

println("Broadcasted price: $(price_bc)")
println("Threaded price:    $(price_thr)")
```

---

## Running Demos

Each demo lives in `demo/` and can be run directly:

```bash
# From the project root
julia --project demo/coupon_bond_demo.jl
julia --project demo/swap_pricing_demo.jl
julia --project demo/monte_carlo_pricing_demo.jl
julia --project demo/market_env_demo.jl
```

## Running Tests

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

Or run a specific test file:

```bash
julia --project -e 'using QuantitativeLib; include("test/montecarlo_test.jl")'
```

---

## Configuration

Day-count conventions and default precision are read from `config/quantitative_lib.toml` at load time. Edit that file to customise without changing code.

```toml
[day_counts]
ACT_365   = 365.0
ACT_360   = 360.0
ACT_36525 = 365.25
DE300_D   = 360.0

[defaults]
default_digits      = 8
trading_days_year   = 252
```

---

## Where to go next

- **[README.md](README.md)** — full feature list and project structure
- **[demo/](demo/)** — complete runnable examples for every module
- **[test/](test/)** — unit tests double as usage examples
- **Source** — `src/` is well-structured; each submodule maps to one file
