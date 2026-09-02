# SPDX-License-Identifier: MIT

# src/Instruments.jl

module Instruments

using ..QuantitativeCore: InstrumentCalendar, PeriodDays

using Dates
using .Dates: Date, Period, Day
import Dates: Date

export Instrument, Bond, Coupon, ZeroCouponBond, CouponBond, generate_coupons!

import Base: isless

isless(p1::PeriodDays, p2::PeriodDays) = isless(p1.days, p2.days)

# --- Instrument Types ---

"""
Abstract base type for all financial instruments.
"""
abstract type Instrument end

"""
Abstract base type for all bond instruments.
"""
abstract type Bond <: Instrument end

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
Represents a zero-coupon bond instrument.

# Fields:
- `issue_date::Date`: The date when the bond is issued.
- `maturity::Date`: The maturity date of the bond.
- `face_value::Float64`: The face (par) value paid at maturity.

# Constructor:
- `ZeroCouponBond(issue_date::Date, maturity::Date, face_value::Float64 = 100.0)`
"""
struct ZeroCouponBond <: Bond
    issue_date::Date
    maturity::Date
    face_value::Float64

    function ZeroCouponBond(issue_date::Date, maturity::Date, face_value::Float64 = 100.0)
        @assert maturity >= issue_date "Maturity date must be on or after the issue date"
        @assert face_value > 0.0 "Face value must be positive"
        return new(issue_date, maturity, face_value)
    end
end

"""
Represents a coupon bond instrument.

# Fields:
- `issue_date::Date`: The date when the bond is issued.
- `maturity::Date`: The maturity date of the bond: the last entry of the
  payment schedule, i.e. the date of the final coupon payment.
- `coupon_rate::Float64`: The annual coupon rate of the bond.
- `payment_schedule::InstrumentCalendar`: The calendar of payment dates.
- `coupons::Vector{Coupon}`: The vector of Coupon instances associated with the bond.
- `face_value::Float64`: The face (par) value repaid at maturity.

# Payment schedule convention:
- Every entry of `payment_schedule.days` is a coupon payment date, except that
  a first entry equal to `issue_date` is treated as an anchor only (this is
  the layout produced by `add_periods`) and does not receive a coupon.
- The last entry of the schedule is the maturity date and receives the final
  coupon. Make sure the schedule contains exactly one entry per coupon
  payment you intend to model, or the maturity will be shifted.

# Constructor:
- `CouponBond(issue_date::Date, payment_schedule::InstrumentCalendar, coupon_rate::Float64,
              face_value::Float64 = 100.0)`
"""
struct CouponBond <: Bond
    issue_date::Date
    maturity::Date
    coupon_rate::Float64
    payment_schedule::InstrumentCalendar
    coupons::Vector{Coupon}
    face_value::Float64

    function CouponBond(issue_date::Date, payment_schedule::InstrumentCalendar, coupon_rate::Float64, face_value::Float64 = 100.0)
        days = payment_schedule.days
        @assert !isempty(days) "Payment schedule must contain at least one date"
        @assert all(d -> d >= issue_date, days) "Payment schedule entries must be on or after the issue date"
        @assert all(i -> i == 1 || days[i - 1] < days[i], eachindex(days)) "Payment schedule entries must be strictly increasing"
        @assert coupon_rate >= 0.0 "Coupon rate must be non-negative"
        @assert face_value > 0.0 "Face value must be positive"

        # The maturity is the last payment date of the schedule
        maturity = days[end]

        # Coupons are populated by generate_coupons!
        coupons = Coupon[]

        return new(issue_date, maturity, coupon_rate, payment_schedule, coupons, face_value)
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

"""
Generate all coupons for the bond from its payment schedule.

Every schedule entry is a coupon payment date, except that a first entry equal
to the issue date is an anchor only (as produced by `add_periods`) and
receives no coupon. The first coupon accrues from the issue date to the first
payment date (which may be a short or long period), and each subsequent coupon
accrues from the previous payment date to the current one, using an
actual/365.25 day-count convention.
"""
function generate_coupons!(bond::CouponBond)
    empty!(bond.coupons)
    prev_date = bond.issue_date
    for day in bond.payment_schedule.days
        if day <= prev_date
            # Anchor entry (the issue date itself): not a payment date.
            continue
        end
        period_days = (day - prev_date).value
        coupon_amt = bond.coupon_rate * (period_days / 365.25) * bond.face_value
        if coupon_amt > 0.0
            push!(bond.coupons, Coupon(day, coupon_amt))
        end
        prev_date = day
    end
end


end # module Instruments
