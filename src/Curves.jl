# src/Curves.jl

module Curves

using Dates

using ..Instruments: Bond, ZeroCouponBond, CouponBond

export InterestCurve, ZeroCurve
export tenor, zero_rate, discount_factor, forward_rate
export BondQuote, cash_flows, bootstrap_zero_curve

"""
Day-count convention used throughout the curve: actual/365, matching
`Pricers.bond_tenor` and `Pricers.discount_factor`.
"""
const DAY_COUNT::Float64 = 365.0

"""
Abstract base type for interest rate term structure curves.
"""
abstract type InterestCurve end

"""
A zero rate curve with piecewise-constant forward interpolation.

# Fields
- `issue_date::Date`: The valuation anchor date. All tenors (and all
  discounting) are measured from this date.
- `nodes::Vector{Tuple{Date,Float64}}`: Pairs of (date, continuously compounded
  zero rate) at which the curve is pinned, strictly increasing in date. The
  first node is usually on `issue_date` (the short-rate anchor), mirroring the
  anchor-entry convention of `InstrumentCalendar` schedules.

# Interpolation
Between two nodes the discount factor is log-linear, which is equivalent to a
piecewise-constant forward rate. Before the first node the curve extrapolates
flat at the first node's zero rate; after the last node it extrapolates flat at
the forward rate of the last segment.

# Constructor
- `ZeroCurve(issue_date::Date, nodes::Vector{Tuple{Date,Float64}})`
"""
struct ZeroCurve <: InterestCurve
    issue_date::Date
    nodes::Vector{Tuple{Date,Float64}}

    function ZeroCurve(issue_date::Date, nodes::Vector{Tuple{Date,Float64}})
        @assert !isempty(nodes) "Curve must contain at least one node"
        @assert all(nd -> nd[1] >= issue_date, nodes) "Node dates must be on or after the issue date"
        @assert all(i -> i == 1 || nodes[i - 1][1] < nodes[i][1], eachindex(nodes)) "Node dates must be strictly increasing"
        return new(issue_date, nodes)
    end
end

"""
Tenor in years from the curve's issue date to `date`, using an actual/365
day-count convention.
"""
function tenor(c::ZeroCurve, date::Date)::Float64
    return (date - c.issue_date).value / DAY_COUNT
end

"""
Interpolated continuously compounded zero rate for maturity `date`.

The zero rate is defined as `-log(discount_factor)/tenor`; at zero tenor it is
the first node's rate.
"""
function zero_rate(c::ZeroCurve, date::Date)::Float64
    t = tenor(c, date)
    if t <= 0.0
        return c.nodes[1][2]
    end
    return -log(discount_factor(c, date)) / t
end

"""
Discount factor from the curve's issue date to `date`.
"""
function discount_factor(c::ZeroCurve, date::Date)::Float64
    t = tenor(c, date)
    @assert t >= 0.0 "Date must be on or after the curve issue date"

    nodes = c.nodes
    n = length(nodes)
    ts = [tenor(c, d) for (d, _) in nodes]
    lndf = [ -z * ti for ((_, z), ti) in zip(nodes, ts) ]

    if t <= ts[1]
        # Flat extrapolation at the first node's zero rate.
        return exp(-nodes[1][2] * t)
    end
    if t >= ts[n]
        # Flat extrapolation at the last segment's forward rate.
        f = n > 1 ? (lndf[n - 1] - lndf[n]) / (ts[n] - ts[n - 1]) : nodes[1][2]
        return exp(lndf[n] - f * (t - ts[n]))
    end
    # Log-linear in the discount factor between nodes.
    for k in 1:(n - 1)
        if t <= ts[k + 1]
            w = (t - ts[k]) / (ts[k + 1] - ts[k])
            return exp((1.0 - w) * lndf[k] + w * lndf[k + 1])
        end
    end
    error("unreachable: node interpolation failed for tenor $t")
end

"""
Simple forward rate implied by the curve between `start_date` and `end_date`,
i.e. the rate `f` such that
`discount_factor(start) = (1 + f * τ) * discount_factor(end)`, with `τ` the
actual/365 year fraction of the period.
"""
function forward_rate(c::ZeroCurve, start_date::Date, end_date::Date)::Float64
    @assert start_date < end_date "Start date must be before the end date"
    τ = (end_date - start_date).value / DAY_COUNT
    return (discount_factor(c, start_date) / discount_factor(c, end_date) - 1.0) / τ
end

"""
A market price for a bond, used as an input to curve bootstrapping.

# Fields
- `bond::Bond`: The traded bond (zero-coupon or coupon).
- `price::Float64`: The price of the bond, in the same units as its face
  value.

# Constructor
- `BondQuote(bond::Bond, price::Float64)`
"""
struct BondQuote
    bond::Bond
    price::Float64

    function BondQuote(bond::Bond, price::Float64)
        @assert price > 0.0 "Price must be positive"
        return new(bond, price)
    end
end

"""
Cash flows of a bond as `(date, amount)` pairs in date order.

For a `CouponBond` the final coupon (the one paid on the maturity date) is
combined with the face value into a single terminal payment, mirroring how
`Pricers.price` values the two; a coupon bond with no coupons (e.g. a 0%
rate) pays only the face value at maturity.
"""
function cash_flows(b::ZeroCouponBond)::Vector{Tuple{Date, Float64}}
    return [(b.maturity, b.face_value)]
end

function cash_flows(b::CouponBond)::Vector{Tuple{Date, Float64}}
    flows = Tuple{Date, Float64}[]
    terminal_set = false
    for coupon in b.coupons
        if coupon.date == b.maturity
            push!(flows, (coupon.date, coupon.amount + b.face_value))
            terminal_set = true
        else
            push!(flows, (coupon.date, coupon.amount))
        end
    end
    if !terminal_set
        push!(flows, (b.maturity, b.face_value))
    end
    return flows
end

"""
Bootstrap a zero rate curve from bond prices by sequential substitution.

Each bond pins the zero rate at its maturity: the pre-maturity cash flows
are discounted with the curve pinned so far, and the remaining value is
attributed to the terminal payment,

    DF(maturity) = (price - PV(prior cash flows)) / terminal amount,

so the node's zero rate is `-log(DF(maturity)) / tenor`. Each bond depends
only on the nodes already pinned, so no linear solver is required.

# Requirements
- `quotes` must be ordered by strictly increasing maturity, and the first
  bond must have a single cash flow at maturity (a zero-coupon bond), since
  the first node has no curve to discount anything with.
- Every cash flow must fall on or after `issue_date`.
- Each price must exceed the present value of its prior cash flows, so the
  implied discount factor is positive.

# Returns
- `ZeroCurve(issue_date, nodes)` with one node at each bond's maturity.
"""
function bootstrap_zero_curve(issue_date::Date, quotes::Vector{BondQuote})::ZeroCurve
    @assert !isempty(quotes) "At least one bond quote is required"

    nodes = Tuple{Date, Float64}[]
    prev_maturity = nothing
    for (i, bq) in enumerate(quotes)
        bond = bq.bond
        cfs = cash_flows(bond)

        @assert cfs[1][1] >= issue_date "First cash flow ($(cfs[1][1])) is before the valuation date ($(issue_date))"
        if i > 1
            @assert bond.maturity > prev_maturity "Bonds must be ordered by strictly increasing maturity"
        end
        @assert bond.maturity > issue_date "Maturity ($(bond.maturity)) must be strictly after the valuation date ($(issue_date))"
        if i == 1
            @assert all(cf -> cf[1] == bond.maturity, cfs) "The first bond must have a single cash flow at maturity (a zero-coupon bond)"
        end

        # Present value of the pre-maturity cash flows under the curve
        # pinned so far; the terminal cash flow carries the rest.
        prior_pv = 0.0
        if i > 1
            partial = ZeroCurve(issue_date, nodes)
            for (date, amount) in cfs
                if date < bond.maturity
                    prior_pv += amount * discount_factor(partial, date)
                end
            end
        end

        terminal = cfs[end][2]
        df = (bq.price - prior_pv) / terminal
        @assert df > 0.0 "Price ($(bq.price)) is not above the present value of the prior cash flows; the implied discount factor must be positive"

        t = (bond.maturity - issue_date).value / DAY_COUNT
        push!(nodes, (bond.maturity, -log(df) / t))
        prev_maturity = bond.maturity
    end

    return ZeroCurve(issue_date, nodes)
end

end # module Curves
