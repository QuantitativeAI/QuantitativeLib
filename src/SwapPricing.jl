# src/SwapPricing.jl
module SwapPricing

using Dates
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

# Helper function to calculate time to maturity (in years)
function time_to_maturity(date::Date, maturity_date::Date)::Float64
    @assert maturity_date >= date "maturity_date must be on or after date"
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

# Look up a discount factor from a pricer's discount curve using
# log-linear interpolation between nodes.  Extrapolates flat before the
# first node and flat at the last segment's forward rate after the last.
function _lookup_discount_factor(discount_curve::Vector{Tuple{Date, Float64}},
                                date::Date, valuation_date::Date)::Float64
    # Build tenor / log-DF arrays once per call; acceptable for demo-scale curves.
    ts = [(d - valuation_date).value / 365.0 for (d, _) in discount_curve]
    lndf = [log(df) for (_, df) in discount_curve]
    t = (date - valuation_date).value / 365.0

    if t <= ts[1]
        return exp(lndf[1])   # flat extrapolation at the short end
    end
    if t >= ts[end]
        # Flat at the last segment's forward rate.
        n = length(ts)
        f = n > 1 ? (lndf[n - 1] - lndf[n]) / (ts[n] - ts[n - 1]) : lndf[1] / ts[1]
        return exp(lndf[end] - f * (t - ts[end]))
    end
    # Log-linear interpolation between the two bracketing nodes.
    for k in 1:(length(ts) - 1)
        if t <= ts[k + 1]
            w = (t - ts[k]) / (ts[k + 1] - ts[k])
            return exp((1.0 - w) * lndf[k] + w * lndf[k + 1])
        end
    end
    error("unreachable: interpolation failed for tenor $t")
end

for PricerType in (StandardSwapPricer, HullWhiteSwapPricer, BlackDesclozelPricer)
    @eval function discount_factor(pricer::$PricerType, date::Date)::Float64
        return _lookup_discount_factor(pricer.discount_curve, date, pricer.discount_curve[1][1])
    end
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
Calculates the par fixed rate for a swap (per unit of notional).

The fixed leg's `payment.amount` already embeds the notional
(`notional * rate * days / 365`), so we divide by notional to obtain
the rate itself.
"""
function par_rate(swap::Swap, pricer::Pricer)::Float64
    sum_df = 0.0
    sum_amount_df = 0.0

    for payment in swap.fixed_leg.payments
        df = discount_factor(pricer, payment.date)
        sum_df += df
        sum_amount_df += (payment.amount / swap.notional) * df
    end

    return sum_amount_df / sum_df
end

"""
Calculates Macaulay duration for a swap (in years), weighted by
discounted fixed-leg cash flows measured from the swap's start date.

True modified duration would divide this by (1 + yield), but for a
par swap the yield ≈ par_rate, so callers can adjust as needed.
"""
function modified_duration(swap::Swap, pricer::Pricer)::Float64
    sum_tdf = 0.0
    sum_df = 0.0

    for payment in swap.fixed_leg.payments
        df = discount_factor(pricer, payment.date)
        t = time_to_maturity(swap.start_date, payment.date)
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

    # Floating leg: accrue from the last payment date before (or on) settlement
    # up to the settlement date, prorated against the full period.
    # payment.amount = notional * rate * period_days / 365, so the rate per day is
    # payment.amount / period_days / notional. We multiply by adjusted_notional.
    prev_date = swap.start_date
    for payment in swap.floating_leg.payments
        if payment.date > settlement_date
            accrued_days = (settlement_date - prev_date).value
            period_days = (payment.date - prev_date).value
            rate_per_day = payment.amount / period_days / swap.notional
            adjusted_amount = adjusted_notional * rate_per_day * accrued_days +
                              adjusted_notional * swap.spread * accrued_days / 365.0
            if adjusted_amount > 0
                push!(settled, SettledPayment(payment, adjusted_amount))
            end
            break
        end
        prev_date = payment.date
    end

    # Fixed leg: same logic (no spread component)
    prev_date = swap.start_date
    for payment in swap.fixed_leg.payments
        if payment.date > settlement_date
            accrued_days = (settlement_date - prev_date).value
            period_days = (payment.date - prev_date).value
            rate_per_day = payment.amount / period_days / swap.notional
            adjusted_amount = adjusted_notional * rate_per_day * accrued_days
            if adjusted_amount > 0
                push!(settled, SettledPayment(payment, adjusted_amount))
            end
            break
        end
        prev_date = payment.date
    end

    return settled
end

end
