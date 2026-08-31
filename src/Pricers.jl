# src/QuantitativeLib/Pricers.jl
module Pricers

using ..Instruments: Bond, ZeroCouponBond, CouponBond

using Dates

export Pricer, BlackScholesPricer, HullWhitePricer, BondPricer
export InterestMode, ContinuousInterest, SimpleInterest
export price

"""
Abstract base type for all pricers."""
abstract type Pricer end

struct BlackScholesPricer <: Pricer
    volatility::Float64
    risk_free_rate::Float64
    dividend_yield::Float64

    function BlackScholesPricer(volatility::Float64,
                               risk_free_rate::Float64,
                               dividend_yield::Float64)
        @assert volatility > 0 "Volatility must be positive"
        return new(volatility, risk_free_rate, dividend_yield)
    end
end

"""
Hull-White model pricer for interest rate derivatives."""
struct HullWhitePricer <: Pricer
    a::Float64      # Mean reversion speed
    σ::Float64      # Volatility
    factors::Vector{Float64}

    function HullWhitePricer(a::Float64, σ::Float64, factors::Vector{Float64})
        @assert all(factors .> 0) "All factors must be positive"
        return new(a, σ, factors)
    end
end

"""
Abstract base type for interest compounding modes."""
abstract type InterestMode end

"""
Continuously compounded interest. Discount factor: `exp(-r * t)`.
"""
struct ContinuousInterest <: InterestMode end

"""
Simple (linear) interest. Discount factor: `1 / (1 + r * t)`.
"""
struct SimpleInterest <: InterestMode end

"""
Generic bond pricer.

Takes a bond instrument and prices it according to the type of the instrument:
- A `ZeroCouponBond` is priced as the present value of its face value.
- A `CouponBond` is priced as the sum of each discounted coupon payment plus
  the discounted face value at maturity.

# Fields
- `bond::Bond`: The bond instrument being priced.
- `discount_rate::Float64`: The annual discount rate used for present value.
- `interest::InterestMode`: The compounding mode for the discount factor. Use
  `ContinuousInterest()` (the default) or `SimpleInterest()`.

# Constructor
- `BondPricer(bond::Bond, discount_rate::Float64, interest::InterestMode = ContinuousInterest())`
"""
struct BondPricer <: Pricer
    bond::Bond
    discount_rate::Float64
    interest::InterestMode

    function BondPricer(bond::Bond,
                        discount_rate::Float64,
                        interest::InterestMode = ContinuousInterest())
        @assert discount_rate >= 0.0 "Discount rate must be non-negative"
        @assert start_date(bond) <= maturity_date(bond) "Start date must be before or equal to maturity"
        return new(bond, discount_rate, interest)
    end
end

"""
Start (valuation) date of the bond: the issue date.
"""
function start_date(p::BondPricer)::Date
    return start_date(p.bond)
end

"""
Maturity date of the bond.
"""
function maturity_date(p::BondPricer)::Date
    return maturity_date(p.bond)
end

"""
Maturity date accessor for Bond instruments.
"""
maturity_date(b::Bond)::Date = b.maturity

start_date(b::Bond)::Date = b.issue_date

"""
Time to maturity in years, using an actual/365 day-count convention.
"""
function bond_tenor(p::BondPricer)::Float64
    return (maturity_date(p) - start_date(p)).value / 365.0
end

"""
Discount factor from the bond's start date to `date`, using the pricer's
compounding mode.
"""
function discount_factor(p::BondPricer, date::Date)::Float64
    t = (date - start_date(p)).value / 365.0
    return discount_factor(p.discount_rate, t, p.interest)
end

"""
Discount factor from the start date to maturity, using the pricer's
compounding mode.
"""
function discount_factor(p::BondPricer)::Float64
    return discount_factor(p, maturity_date(p))
end

"""
Discount factor for continuously compounded interest: `exp(-r * t)`.
"""
function discount_factor(rate::Float64, tenor::Float64, ::ContinuousInterest)::Float64
    return exp(-rate * tenor)
end

"""
Discount factor for simple interest: `1 / (1 + r * t)`.
"""
function discount_factor(rate::Float64, tenor::Float64, ::SimpleInterest)::Float64
    return 1.0 / (1.0 + rate * tenor)
end

"""
Price a zero-coupon bond as the present value of its face value discounted
back to the start date: `price = face_value * discount_factor`.
"""
function price(b::ZeroCouponBond, p::BondPricer)::Float64
    return b.face_value * discount_factor(p, b.maturity)
end

"""
Price a coupon bond as the sum of each coupon payment discounted back to the
start date, plus the face value discounted back to the start date at maturity:
`price = Σ coupon.amount * discount_factor(coupon.date) + face_value * discount_factor(maturity)`.
"""
function price(b::CouponBond, p::BondPricer)::Float64
    @assert start_date(p) <= b.maturity "Maturity must be on or after start date"
    for coupon in b.coupons
        @assert start_date(p) <= coupon.date <= b.maturity "Coupon date must be between start and maturity"
    end

    pv = 0.0
    for coupon in b.coupons
        pv += coupon.amount * discount_factor(p, coupon.date)
    end
    return pv + b.face_value * discount_factor(p, b.maturity)
end

"""
Price the bond instrument held by the pricer, dispatching on the bond's type.
"""
function price(p::BondPricer)::Float64
    return price(p.bond, p)
end

end
