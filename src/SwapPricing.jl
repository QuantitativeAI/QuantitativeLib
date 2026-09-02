# src/SwapPricing.jl
module SwapPricing

using Dates
using .Dates: Date
using ..Pricers: Pricer

export Payment, SwapLeg, Swap, SettledPayment
export StandardSwapPricer, HullWhiteSwapPricer, BlackDesclozelPricer
export discount_factor, present_value, par_rate, modified_duration, time_to_maturity, settle_swap

# Represents a single payment in a swap leg.
struct Payment
    date::Date
    amount::Float64
    convention::String

    function Payment(date::Date, notional::Float64, rate::Float64,
                     start_date::Date, end_date::Date, convention::String)

        if convention == "ACTUAL_ACTUAL"
            days = count_days(start_date, end_date)
        elseif convention == "30E/360"
            days = count_30e_360(start_date, end_date)
        else
            @warn("Unknown convention: $convention using ACTUAL_ACTUAL")
            convention = "ACTUAL_ACTUAL"
            days = count_days(start_date, end_date)
        end

        amount = (notional * rate * days) / 365.0

        return new(date, amount, convention)
    end
end

# Helper functions to calculate days and durations based on the convention
function count_days(start_date::Date, end_date::Date)
    return (end_date - start_date).value
end

function count_30e_360(start_date::Date, end_date::Date)
    year_start = Dates.year(start_date)
    month_start = Dates.month(start_date)
    day_start = Dates.day(start_date)
    year_end = Dates.year(end_date)
    month_end = Dates.month(end_date)
    day_end = Dates.day(end_date)

    if day_start == 31
        day_start = 30
    end
    if day_end == 31 && (day_start == 30 || day_start == 31)
        day_end = 30
    end

    return (year_end - year_start) * 360 +
           (month_end - month_start) * 30 +
           (day_end - day_start)
end

# Calculates actual days between two dates.
function count_actual_days(start::Date, end_date::Date)::Int
    return diff(end_date, start).value
end

"""
Swapped payment with cash adjustment for settlement.
"""
struct SettledPayment
    original_payment::Payment
    adjusted_amount::Float64

    function SettledPayment(p::Payment, adjusted_amount::Float64)
        return new(p, adjusted_amount)
    end
end

"""
Represents a swap leg (either fixed or floating).
"""
struct SwapLeg
    payments::Vector{Payment}
    convention::String

    function SwapLeg(convention::String)
        return new(Vector{Payment}(), convention)
    end

    function SwapLeg(payments::Vector{Payment}, convention::String = "ACTUAL_ACTUAL")
        return new(payments, convention)
    end
end

# Represents a complete swap.
struct Swap
    fixed_leg::SwapLeg
    floating_leg::SwapLeg
    start_date::Date
    end_date::Date
    notional::Float64
    spread::Float64

    function Swap(fixed_leg::SwapLeg, floating_leg::SwapLeg,
                  start_date::Date, end_date::Date, notional::Float64, spread::Float64 = 0.0)
        return new(fixed_leg, floating_leg, start_date, end_date, notional, spread)
    end
end

# Helper function to calculate time to maturity
function time_to_maturity(date::Date, maturity_date::Date)::Float64
    return (maturity_date - date).value / 365.0
end

# Hull-White model pricer for interest rate swaps.
struct HullWhiteSwapPricer <: Pricer
    a::Float64
    sigma::Float64
    discount_curve::Vector{Tuple{Date, Float64}}

    function HullWhiteSwapPricer(a::Float64, sigma::Float64,
                                discount_curve::Vector{Tuple{Date, Float64}})
        @assert all(d -> d[2] > 0, discount_curve) "Discount factors must be positive"
        return new(a, sigma, discount_curve)
    end
end

# Black-Desclozel model for swap pricing.
struct BlackDesclozelPricer <: Pricer
    alpha::Float64
    sigma::Float64
    discount_curve::Vector{Tuple{Date, Float64}}

    function BlackDesclozelPricer(alpha::Float64, sigma::Float64,
                                  discount_curve::Vector{Tuple{Date, Float64}})
        @assert all(d -> d[2] > 0, discount_curve) "Discount factors must be positive"
        return new(alpha, sigma, discount_curve)
    end
end

# Standard swap pricer using discount curve.
struct StandardSwapPricer <: Pricer
    discount_curve::Vector{Tuple{Date, Float64}}

    function StandardSwapPricer(discount_curve::Vector{Tuple{Date, Float64}})
        @assert all(d -> d[2] > 0, discount_curve) "Discount factors must be positive"
        return new(discount_curve)
    end
end

# Implement discount_factor for StandardSwapPricer
function discount_factor(pricer::StandardSwapPricer, date::Date)::Float64
    for (d, df) in pricer.discount_curve
        if d == date
            return df
        end
    end
    return 1.0
end

# Implement discount_factor for HullWhiteSwapPricer
function discount_factor(pricer::HullWhiteSwapPricer, date::Date)::Float64
    for (d, df) in pricer.discount_curve
        if d == date
            return df
        end
    end
    return 1.0
end

# Implement discount_factor for BlackDesclozelPricer
function discount_factor(pricer::BlackDesclozelPricer, date::Date)::Float64
    for (d, df) in pricer.discount_curve
        if d == date
            return df
        end
    end
    return 1.0
end

"""
Calculates present value of a swap leg's payments using the pricer's discount curve.
"""
function present_value(payments::AbstractVector{T}, pricer::Pricer)::Float64 where {T<:Union{Payment, SettledPayment}}
    pv = 0.0

    for payment in payments
        date = payment isa Payment ? payment.date : payment.original_payment.date
        amount = payment isa Payment ? payment.amount : payment.adjusted_amount
        df = discount_factor(pricer, date)
        pv += amount * df
    end

    return pv
end

"""
Calculates par rate for a swap.
The fixed leg's payments are expressed per unit of notional, so the par rate is
the ratio of discounted payment amounts to the sum of discount factors.
"""
function par_rate(swap::Swap, pricer::Pricer)::Float64
    sum_df = 0.0
    sum_amount_df = 0.0

    for payment in swap.fixed_leg.payments
        df = discount_factor(pricer, payment.date)
        sum_df += df
        sum_amount_df += payment.amount * df
    end

    return sum_amount_df / sum_df
end

"""
Calculates modified duration for a swap (in years).
"""
function modified_duration(swap::Swap, pricer::Pricer)::Float64
    sum_tdf = 0.0
    sum_df = 0.0

    for payment in swap.fixed_leg.payments
        df = discount_factor(pricer, payment.date)
        t = time_to_maturity(payment.date, swap.end_date)
        sum_tdf += (t * df)
        sum_df += df
    end

    return sum_tdf / sum_df
end

"""
Implements cash settlement for early termination.
Returns the remaining payments of both legs as SettledPayment objects, with
amounts accrued up to the settlement date on an ACT/365 basis.
"""
function settle_swap(swap::Swap, settlement_date::Date, adjusted_notional::Float64)

    settled = Vector{SettledPayment}()

    for payment in swap.floating_leg.payments
        if payment.date >= settlement_date
            accrued_days = max(0, (payment.date - settlement_date).value)
            adjusted_amount = adjusted_notional * (payment.amount + swap.spread) * accrued_days / 365.0
            push!(settled, SettledPayment(payment, adjusted_amount))
        end
    end

    for payment in swap.fixed_leg.payments
        if payment.date >= settlement_date
            accrued_days = max(0, (payment.date - settlement_date).value)
            adjusted_amount = adjusted_notional * payment.amount * accrued_days / 365.0
            push!(settled, SettledPayment(payment, adjusted_amount))
        end
    end

    return settled
end

end
