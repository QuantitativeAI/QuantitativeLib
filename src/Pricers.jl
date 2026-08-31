# src/QuantitativeLib/Pricers.jl
module Pricers

using ..QuantitativeCore: InstrumentCalendar

using Dates
using .Dates: Date

export Pricer, BlackScholesPricer, HullWhitePricer, BondPricer
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
Zero-coupon bond pricer.

Prices a zero-coupon bond by discounting its face value back to the start date
using a present value calculation.

# Fields
- `calendar::InstrumentCalendar`: The instrument calendar. The first date is the
  start (valuation) date and the last date is the maturity date (the full term).
- `discount_rate::Float64`: The annual discount rate (continuously compounded) used for present value.
- `face_value::Float64`: The face (par) value paid at maturity.

# Constructor
- `BondPricer(calendar::InstrumentCalendar, discount_rate::Float64, face_value::Float64 = 100.0)`
"""
struct BondPricer <: Pricer
    calendar::InstrumentCalendar
    discount_rate::Float64
    face_value::Float64

    function BondPricer(calendar::InstrumentCalendar,
                        discount_rate::Float64,
                        face_value::Float64 = 100.0)
        @assert length(calendar.days) >= 2 "Calendar must contain at least two dates (start and maturity)"
        @assert calendar.days[end] >= calendar.days[1] "Maturity date must be on or after the start date"
        @assert discount_rate >= 0.0 "Discount rate must be non-negative"
        @assert face_value > 0.0 "Face value must be positive"
        return new(calendar, discount_rate, face_value)
    end
end

"""
Start (valuation) date of the bond: the first date in the calendar.
"""
function start_date(p::BondPricer)::Date
    return p.calendar.days[1]
end

"""
Maturity date of the bond: the last date in the calendar (the full term).
"""
function maturity_date(p::BondPricer)::Date
    return p.calendar.days[end]
end

"""
Time to maturity in years, using an actual/365 day-count convention.
"""
function bond_tenor(p::BondPricer)::Float64
    return (maturity_date(p) - start_date(p)).value / 365.0
end

"""
Discount factor from the start date to maturity, using continuous compounding.
"""
function discount_factor(p::BondPricer)::Float64
    return exp(-p.discount_rate * bond_tenor(p))
end

"""
Price the zero-coupon bond as the present value of its face value discounted
back to the start date: `price = face_value * discount_factor`.
"""
function price(p::BondPricer)::Float64
    return p.face_value * discount_factor(p)
end

end
