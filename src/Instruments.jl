# SPDX-License-Identifier: MIT

# src/Instruments.jl

module Instruments

using ..QuantitativeCore: InstrumentCalendar, PeriodDays

using Dates
using .Dates: Date, Period, Day
import Dates: Date

export Instrument
export Coupon
export CouponBond

import Base: isless

isless(p1::PeriodDays, p2::PeriodDays) = isless(p1.days, p2.days)

# --- Instrument Types ---

"""
Abstract base type for all financial instruments.
"""
abstract type Instrument end

"""
Represents a coupon payment.
"""
struct Coupon
    date::Date
    amount::Float64

    function Coupon(date::Date, amount::Float64)
        @assert amount > 0.0 "Coupon amount must be positive"
        return new(date, amount)
    end
end

"""
Represents a bond instrument.

# Fields:
- `issue_date::Date`: The date when the bond is issued.
- `maturity::Date`: The maturity date of the bond
- `coupon_rate::Float64`: The annual coupon rate of the bond.
- `payment_frequency::Period`: The frequency of coupon payments (e.g., Year(1) or Month(6)).
- `coupons::Vector{Coupon}`: The vector of Coupon instances associated with the bond.

# Constructor:
- `Bond(issue_date::Date, maturity::Date, coupon_rate::Float64, payment_frequency::Period)`
"""
struct CouponBond
    issue_date::Date
    maturity::Date
    coupon_rate::Float64
    payment_schedule::InstrumentCalendar
    coupons::Vector{Coupon}

    function CouponBond(issue_date::Date, maturity::Date, coupon_rate::Float64, payment_schedule::InstrumentCalendar)
        @assert coupon_rate >= 0.0 "Coupon rate must be non-negative"

        # Generate coupon schedule
        coupons = Coupon[]
        return new(issue_date, maturity, coupon_rate, payment_schedule, coupons)
    end
end

"""
Represents an option instrument.

# Fields:
- `underlying_price::Float64`: The price of the underlying asset.
- `strike_price::Float64`: The strike price of the option.
- `expiry_date::Date`: The expiry date of the option.
- `volatility::Float64`: The implied volatility of the underlying asset.
- `risk_free_rate::Float64`: The risk-free interest rate.
- `dividend_yield::Float64`: The dividend yield of the underlying asset.

# Constructor:
- `Option(underlying_price::Float64, strike_price::Float64,
         expiry_date::Date, volatility::Float64, risk_free_rate::Float64,
         dividend_yield::Float64)`: Creates a new instance of `Option`.
"""
struct Option <: Instrument
    underlying_price::Float64
    strike_price::Float64
    expiry_date::Date
    volatility::Float64
    risk_free_rate::Float64
    dividend_yield::Float64

    function Option(underlying_price::Float64,
                    strike_price::Float64,
                    expiry_date::Date,
                    volatility::Float64,
                    risk_free_rate::Float64,
                    dividend_yield::Float64)
        @assert underlying_price > 0.0 "Underlying price must be positive"
        @assert strike_price > 0.0 "Strike price must be positive"
        @assert expiry_date > Date(now()) "Expiry date must be in the future"
        return new(underlying_price, strike_price, expiry_date, volatility,
                   risk_free_rate, dividend_yield)
    end
end

"""
Represents a swap instrument.

# Fields:
- `notional::Float64`: The notional amount of the swap.
- `fixed_rate::Float64`: The fixed rate of the swap.
- `payment_frequency::Period`: The frequency of payment periods.
- `start_date::Date`: The start date of the swap.
- `maturity::Date`: The maturity date of the swap.

# Constructor:
- `Swap(notional::Float64, fixed_rate::Float64,
       payment_frequency::PeriodDays, start_date::Date, maturity::Date)`: Creates a new instance of `Swap`.
"""
struct Swap <: Instrument
    notional::Float64
    fixed_rate::Float64
    payment_frequency::PeriodDays
    start_date::Date
    maturity::Date

    function Swap(notional::Float64, fixed_rate::Float64,
                  payment_frequency::PeriodDays, start_date::Date,
                  maturity::Date)
        @assert notional > 0.0 "Notional must be positive"
        return new(notional, fixed_rate, payment_frequency, start_date, maturity)
    end
end

# Generate all coupons for bond
function generate_coupons!(bond::CouponBond)
    # Implementation to generate coupons for a bond
    # This is a placeholder for the actual logic
    # For now, we just add a dummy coupon
    push!(bond.coupons, Coupon(Date(2023, 1, 1), 0.05))
end

""" Generate all coupons for swap
function generate_coupons!(swap::Swap)
    # Implementation to generate cash flows for a swap
    # This is a placeholder for the actual logic
    # For now, we just add a dummy cash flow
    push!(swap.cash_flows, CashFlow(Date(2023, 1, 1), 0.0, 1000.0))
end
"""

end # module Instruments
