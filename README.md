# QuantitativeLib

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

A Julia library for quantitative finance — fixed-income pricing, interest-rate curve construction, swap analytics, and Monte Carlo option pricing.

## Overview

QuantitativeLib provides a modular framework for modeling and pricing financial instruments in Julia. It covers the full lifecycle from instrument definition through curve bootstrapping to pricing and risk analytics, with a focus on clarity and extensibility.

### What's included

- **Instruments** — `Bond`, `ZeroCouponBond`, `CouponBond`, `Option`, `Swap`
- **Pricers** — `BondPricer` (continuous & simple compounding), `BlackScholesPricer`, `HullWhitePricer`
- **Interest-rate curves** — `ZeroCurve`, `YieldCurve`, `ForwardCurve`, `DiscountCurve`, `BasisCurve`, `CreditCurve` with linear and cubic-spline interpolation
- **Curve bootstrapping** — from zero-coupon and coupon-bond quotes
- **Swap analytics** — standard, Hull-White, and Black-Desclozel pricers; PV, par rate, modified duration, and cash settlement
- **Monte Carlo** — GBM simulation and European call pricing (broadcasted + threaded)
- **Market environment** — unified container for curves, vol surfaces, spot/FX rates, and regime metadata
- **Configuration** — TOML-driven defaults for day-count conventions and numeric precision (built-in minimal TOML parser, no extra deps)

## Installation

Add the package in Julia:

```julia
using Pkg
Pkg.add(path="/path/to/QuantitativeLib")
```

Or register it and add as a normal package. The only third-party dependency is `Interpolations`.

## Quick Start

### Bond pricing

```julia
using QuantitativeLib

bond = ZeroCouponBond(Date(2024, 1, 1), Date(2026, 1, 1), 100.0)
p = BondPricer(bond, 0.05)   # 5% discount rate, continuous compounding
price = QuantitativeLib.price(p)
```

### Curve construction & bootstrapping

```julia
using QuantitativeLib

issue = Date(2026, 1, 1)
curve = ZeroCurve(issue, [
    (Date(2027, 1, 1), 0.02),
    (Date(2028, 1, 1), 0.03),
])

df = discount_factor(curve, Date(2027, 7, 1))
fr = forward_rate(curve, Date(2027, 1, 1), Date(2028, 1, 1))
```

### Monte Carlo option pricing

```julia
using QuantitativeLib
using QuantitativeLib.Instruments: Option
using Dates

option = Option(100.0, 100.0, Date(2027, 1, 1), 0.2, 0.05, 0.0)

trading_days = Int(floor((option.expiry_date - Date(2026, 9, 4)).value * 252 / 365))
prices = colwise_simulate_stock_prices(option.underlying_price,
                                       option.risk_free_rate,
                                       option.volatility,
                                       trading_days, 10_000)

price = priceCallOptionBroadcasted(prices, option.risk_free_rate,
                                   trading_days / 252.0, option.strike_price)
```

## Project Structure

```
src/
  QuantitativeLib.jl          # Top-level module & exports
  SystemConfig.jl             # Config loader & accessors
  QuantitativeCore.jl         # Calendar & date utilities
  Instruments.jl              # Bond, Option, Swap types
  Pricers.jl                  # BondPricer, BlackScholesPricer, HullWhitePricer
  Curves.jl                   # ZeroCurve, interpolation, bootstrapping
  SwapPricing.jl              # IRS pricers & analytics
  MonteCarloPricing.jl        # GBM simulation & option pricing
  MarketEnv.jl                # MarketEnvironment container
config/
  quantitative_lib.toml       # Day-count & default configuration
test/
  runtests.jl                 # Full test suite
  montecarlo_test.jl          # Monte Carlo tests
demo/
  coupon_bond_demo.jl
  market_env_demo.jl
  monte_carlo_pricing_demo.jl
  swap_pricing_demo.jl
```

## Running Tests

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

## Demos

```bash
julia --project demo/coupon_bond_demo.jl
julia --project demo/swap_pricing_demo.jl
julia --project demo/monte_carlo_pricing_demo.jl
julia --project demo/market_env_demo.jl
```

## Configuration

Edit `config/quantitative_lib.toml` to customize day-count conventions, default precision, and curve settings. The library ships with sensible defaults and a built-in TOML parser — no extra dependencies are required.

## License

GPL-3.0 — see [LICENSE](LICENSE) for details.
