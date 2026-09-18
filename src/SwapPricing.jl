# src/SwapPricing.jl
module SwapPricing

using Dates
using ..Instruments: Instrument
using ..Pricers: Pricer
using ..SystemConfig: day_count

export Payment, SwapLeg, Swap, SettledPayment, TotalReturnSwap
export DiscountCurveSwapPricer, TotalReturnSwapPricer, HullWhiteSwapPricer, BlackDesclozelPricer
export discount_factor, present_value, par_rate, npv, financing_payments
export modified_duration, time_to_maturity, settle_swap

# Represents a single payment in a swap leg.
struct Payment
    date::Date
    amount::Float64
    convention::String

    function Payment(date::Date, notional::Float64, rate::Float64,
                     start_date::Date, end_date::Date, convention::String;
                     day_count::Float64 = day_count("ACT_365"))

        if convention == "ACTUAL_ACTUAL"
            days = count_days(start_date, end_date)
        elseif convention == "30E/360"
            days = count_30e_360(start_date, end_date)
        else
            @warn("Unknown convention: $convention using ACTUAL_ACTUAL")
            convention = "ACTUAL_ACTUAL"
            days = count_days(start_date, end_date)
        end

        amount = (notional * rate * days) / day_count

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
struct Swap <: Instrument
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
function time_to_maturity(date::Date, maturity_date::Date; day_count::Float64 = day_count("ACT_365"))::Float64
    @assert maturity_date >= date "maturity_date must be on or after date"
    return (maturity_date - date).value / day_count
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

"""
Pricer for interest rate swaps that discounts the legs' cash flows along a
discount curve (log-linear interpolation between nodes, flat forward
extrapolation beyond the last node).

# Fields
- `discount_curve::Vector{Tuple{Date, Float64}}`: (date, discount factor) nodes,
  with the first node being the valuation date.

# Constructor
- `DiscountCurveSwapPricer(discount_curve)`
"""
struct DiscountCurveSwapPricer <: Pricer
    discount_curve::Vector{Tuple{Date, Float64}}

    function DiscountCurveSwapPricer(discount_curve::Vector{Tuple{Date, Float64}})
        @assert all(d -> d[2] > 0, discount_curve) "Discount factors must be positive"
        return new(discount_curve)
    end
end

"""
Represents a total return swap (TRS) on an underlying asset (an equity,
index, bond or basket). One leg (the total return leg) pays the total return
on the underlying: the income (dividends/coupons) received over the life of
the swap plus the capital gain/loss between the start and end dates. The
other leg (the financing leg) pays a financing rate (e.g., SOFR + spread) on
the notional.

# Fields
- `start_date::Date`: The start (valuation) date of the swap.
- `end_date::Date`: The end date of the swap.
- `notional::Float64`: The initial value of the underlying asset.
- `income_payments::Vector{Payment}`: The income (dividends/coupons) received
  from the underlying over the life of the swap, paid on the total return leg.
- `financing_rate::Float64`: The annual financing rate applied to the notional
  on the financing leg.
- `spread::Float64`: The additional spread added to the financing rate.
- `end_value::Float64`: The expected (or observed) value of the underlying
  asset at the end date; the capital gain/loss is `end_value - notional`.

# Constructor
- `TotalReturnSwap(start_date, end_date, notional, income_payments,
                   financing_rate, end_value; spread = 0.0)`
"""
struct TotalReturnSwap <: Instrument
    start_date::Date
    end_date::Date
    notional::Float64
    income_payments::Vector{Payment}
    financing_rate::Float64
    spread::Float64
    end_value::Float64

    function TotalReturnSwap(start_date::Date, end_date::Date,
                             notional::Float64,
                             income_payments::Vector{Payment},
                             financing_rate::Float64,
                             end_value::Float64;
                             spread::Float64 = 0.0)
        @assert end_date >= start_date "End date must be on or after the start date"
        @assert notional > 0.0 "Notional must be positive"
        @assert end_value > 0.0 "End value must be positive"
        @assert financing_rate >= 0.0 "Financing rate must be non-negative"
        return new(start_date, end_date, notional, income_payments,
                   financing_rate, spread, end_value)
    end
end

"""
Pricer for total return swaps: discounts the total return leg (income plus
terminal capital gain/loss) and the financing leg along the discount curve.

# Fields
- `discount_curve::Vector{Tuple{Date, Float64}}`: (date, discount factor) nodes,
  with the first node being the valuation date.

# Constructor
- `TotalReturnSwapPricer(discount_curve)`
"""
struct TotalReturnSwapPricer <: Pricer
    discount_curve::Vector{Tuple{Date, Float64}}

    function TotalReturnSwapPricer(discount_curve::Vector{Tuple{Date, Float64}})
        @assert all(d -> d[2] > 0, discount_curve) "Discount factors must be positive"
        return new(discount_curve)
    end
end

# Look up a discount factor from a pricer's discount curve using
# log-linear interpolation between nodes.  Extrapolates flat before the
# first node and flat at the last segment's forward rate after the last.
function _lookup_discount_factor(discount_curve::Vector{Tuple{Date, Float64}},
                                date::Date, valuation_date::Date;
                                day_count::Float64 = day_count("ACT_365"))::Float64
    # Build tenor / log-DF arrays once per call; acceptable for demo-scale curves.
    ts = [(d - valuation_date).value / day_count for (d, _) in discount_curve]
    lndf = [log(df) for (_, df) in discount_curve]
    t = (date - valuation_date).value / day_count

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

for PricerType in (DiscountCurveSwapPricer, TotalReturnSwapPricer, HullWhiteSwapPricer, BlackDesclozelPricer)
    @eval function discount_factor(pricer::$PricerType, date::Date; day_count::Float64 = day_count("ACT_365"))::Float64
        return _lookup_discount_factor(pricer.discount_curve, date, pricer.discount_curve[1][1]; day_count=day_count)
    end
end

"""
Calculates present value of a swap leg's payments using the pricer's discount curve.
"""
function present_value(payments::AbstractVector{T}, pricer::Pricer; day_count::Float64 = day_count("ACT_365"))::Float64 where {T<:Union{Payment, SettledPayment}}
    pv = 0.0

    for payment in payments
        date = payment isa Payment ? payment.date : payment.original_payment.date
        amount = payment isa Payment ? payment.amount : payment.adjusted_amount
        df = discount_factor(pricer, date; day_count=day_count)
        pv += amount * df
    end

    return pv
end

"""
Recovers the fixed rate embedded in a swap's fixed leg (per unit of
notional): the uniform rate `K` such that the fixed leg's payments equal
`notional * K * (daysᵢ / day_count)`.

Each `payment.amount` already embeds the notional
(`notional * rate * days / day_count`), so we divide by notional to obtain
the rate itself, then weight by the annuity factor `Σ (daysᵢ / day_count) ·
DFᵢ`. Each period's day count is inferred from consecutive payment dates,
with the first period accruing from `swap.start_date`.

For a swap whose fixed leg was built at a single rate this returns that
rate exactly; for a par swap (fixed rate = floating rate) it is also the
NPV-zero par rate.

# Throws
- `ErrorException` if the annuity factor is zero (e.g. an empty fixed leg),
  in which case no par rate exists.
"""
function par_rate(swap::Swap, pricer::Pricer; day_count::Float64 = day_count("ACT_365"))::Float64
    annuity = 0.0
    sum_amount_df = 0.0

    prev_date = swap.start_date
    for payment in swap.fixed_leg.payments
        df = discount_factor(pricer, payment.date; day_count=day_count)
        annuity += (payment.date - prev_date).value / day_count * df
        sum_amount_df += (payment.amount / swap.notional) * df
        prev_date = payment.date
    end
    @assert annuity > 0 "Annuity factor must be positive to compute a par rate"

    return sum_amount_df / annuity
end

"""
Calculates Macaulay duration for a swap (in years), weighted by
discounted fixed-leg cash flows measured from the swap's start date.

True modified duration would divide this by (1 + yield), but for a
par swap the yield ≈ par_rate, so callers can adjust as needed.
"""
function modified_duration(swap::Swap, pricer::Pricer; day_count::Float64 = day_count("ACT_365"))::Float64
    sum_tdf = 0.0
    sum_df = 0.0

    for payment in swap.fixed_leg.payments
        df = discount_factor(pricer, payment.date; day_count=day_count)
        t = time_to_maturity(swap.start_date, payment.date; day_count=day_count)
        sum_tdf += (t * df)
        sum_df += df
    end

    return sum_tdf / sum_df
end

"""
Net present value of a total return swap from the perspective of the party
**receiving the total return** (paying the financing leg):
`NPV = PV(income) + PV(capital gain/loss) - PV(financing leg)`.

The capital gain/loss is `end_value - notional`, received at the end date.
"""
function npv(trs::TotalReturnSwap, pricer::TotalReturnSwapPricer; day_count::Float64 = day_count("ACT_365"))::Float64
    return present_value(trs.income_payments, pricer; day_count=day_count) +
           (trs.end_value - trs.notional) * discount_factor(pricer, trs.end_date; day_count=day_count) -
           present_value(financing_payments(trs), pricer; day_count=day_count)
end

"""
The financing leg's payments: `(financing_rate + spread) x notional` accrued
over each period of the income schedule (the first accrues from the start
date), using the convention of the first income payment (ACTUAL_ACTUAL if
there is none).
"""
function financing_payments(trs::TotalReturnSwap)::Vector{Payment}
    convention = isempty(trs.income_payments) ? "ACTUAL_ACTUAL" : trs.income_payments[1].convention
    rate = trs.financing_rate + trs.spread

    payments = Payment[]
    prev_date = trs.start_date
    for pmt in trs.income_payments
        push!(payments, Payment(pmt.date, trs.notional, rate, prev_date, pmt.date, convention))
        prev_date = pmt.date
    end
    # Accrue the final stub from the last income payment date to the end date.
    if prev_date < trs.end_date
        push!(payments, Payment(trs.end_date, trs.notional, rate, prev_date, trs.end_date, convention))
    end
    return payments
end

"""
The par financing rate of a total return swap (excluding the spread): the
base financing rate such that a swap with that rate **and the same spread**
has NPV zero at valuation.

# Throws
- `ErrorException` if the annuity factor is zero (e.g. no income payments and
  a zero-length swap), in which case no par rate exists.
"""
function par_rate(trs::TotalReturnSwap, pricer::TotalReturnSwapPricer; day_count::Float64 = day_count("ACT_365"))::Float64
    annuity = 0.0
    prev_date = trs.start_date
    for pmt in trs.income_payments
        df = discount_factor(pricer, pmt.date; day_count=day_count)
        annuity += (pmt.date - prev_date).value / day_count * df
        prev_date = pmt.date
    end
    if prev_date < trs.end_date
        df = discount_factor(pricer, trs.end_date; day_count=day_count)
        annuity += (trs.end_date - prev_date).value / day_count * df
    end
    @assert annuity > 0 "Annuity factor must be positive to compute a par rate"

    pv_tr_leg = present_value(trs.income_payments, pricer; day_count=day_count) +
                (trs.end_value - trs.notional) * discount_factor(pricer, trs.end_date; day_count=day_count)
    return pv_tr_leg / (trs.notional * annuity) - trs.spread
end

"""
Implements cash settlement for early termination.
Returns the remaining payments of both legs as SettledPayment objects, with
amounts accrued up to the settlement date on an ACT/365 basis by default
(configurable via `day_count`).
"""
function settle_swap(swap::Swap, settlement_date::Date, adjusted_notional::Float64; day_count::Float64 = day_count("ACT_365"))

    settled = Vector{SettledPayment}()

    # Floating leg: accrue from the last payment date before (or on) settlement
    # up to the settlement date, prorated against the full period.
    # payment.amount = notional * rate * period_days / day_count, so the rate per day is
    # payment.amount / period_days / notional. We multiply by adjusted_notional.
    prev_date = swap.start_date
    for payment in swap.floating_leg.payments
        if payment.date > settlement_date
            accrued_days = (settlement_date - prev_date).value
            period_days = (payment.date - prev_date).value
            rate_per_day = payment.amount / period_days / swap.notional
            adjusted_amount = adjusted_notional * rate_per_day * accrued_days +
                              adjusted_notional * swap.spread * accrued_days / day_count
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
