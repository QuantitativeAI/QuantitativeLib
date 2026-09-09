# src/Curves.jl

module Curves

using Dates

using ..Instruments: Bond, ZeroCouponBond, CouponBond
using ..SystemConfig: day_count

export InterestCurve, ZeroCurve
export tenor, zero_rate, discount_factor, forward_rate
export BondQuote, cash_flows, bootstrap_zero_curve, bootstrap_yield_curve
export AbstractInterpolation, Linear, CubicSpline
export make_curve, get_rate, get_discount_factor, get_forward_rate
export RateType, RateNode, yearfrac, VolSurface, interpolate_vol
export YieldCurve, ForwardCurve, DiscountCurve, BasisCurve, CreditCurve



# ─────────────────────────────────────────────
# Abstract Curve Hierarchy
# ─────────────────────────────────────────────

"""
Abstract base type for interest rate term structure curves.
"""
abstract type InterestCurve end

"""
Abstract base type for interpolation method objects.

Concrete subtypes implement a callable interface `itp(t) → Float64` that
returns the interpolated rate at tenor `t` (in years).
"""
abstract type AbstractInterpolation end

# ─────────────────────────────────────────────
# Interpolation Methods
# ─────────────────────────────────────────────

"""
Linear interpolation on a pre-computed grid of (tenor, rate) pairs.
"""
struct Linear <: AbstractInterpolation
    xs::Vector{Float64}
    ys::Vector{Float64}

    function Linear(xs::Vector{Float64}, ys::Vector{Float64})
        @assert length(xs) == length(ys) "xs and ys must have the same length"
        @assert length(xs) >= 2 "Need at least 2 points for interpolation"
        return new(xs, ys)
    end
end

function (itp::Linear)(t::Float64)::Float64
    xs = itp.xs
    ys = itp.ys
    n = length(xs)

    # Flat extrapolation before first node
    if t <= xs[1]
        return ys[1]
    end
    # Flat extrapolation after last node
    if t >= xs[n]
        return ys[n]
    end
    # Linear interpolation between nodes
    for k in 1:(n - 1)
        if t <= xs[k + 1]
            w = (t - xs[k]) / (xs[k + 1] - xs[k])
            return (1.0 - w) * ys[k] + w * ys[k + 1]
        end
    end
    error("unreachable: linear interpolation failed for t = $t")
end

"""
Cubic spline interpolation on a pre-computed grid of (tenor, rate) pairs.
Uses natural boundary conditions (second derivative = 0 at endpoints).
"""
struct CubicSpline <: AbstractInterpolation
    xs::Vector{Float64}
    ys::Vector{Float64}
    cs::Vector{Float64}  # cubic coefficients
    n::Int

    function CubicSpline(xs::Vector{Float64}, ys::Vector{Float64})
        @assert length(xs) == length(ys) "xs and ys must have the same length"
        @assert length(xs) >= 2 "Need at least 2 points for cubic spline"
        cs = _cubic_spline_coeffs(xs, ys)
        return new(xs, ys, cs, length(xs))
    end
end

function _cubic_spline_coeffs(xs::Vector{Float64}, ys::Vector{Float64})::Vector{Float64}
    n = length(xs)
    if n == 2
        return [0.0, 0.0, (ys[2] - ys[1]) / (xs[2] - xs[1]), ys[1]]
    end

    h = [xs[i + 1] - xs[i] for i in 1:(n - 1)]
    α = zeros(Float64, n)
    for i in 2:(n - 1)
        α[i] = (3.0 / h[i]) * (ys[i + 1] - ys[i]) - (3.0 / h[i - 1]) * (ys[i] - ys[i - 1])
    end

    # Tridiagonal solver for natural spline
    l = zeros(Float64, n)
    μ = zeros(Float64, n)
    c = zeros(Float64, n)
    b = zeros(Float64, n)
    d = zeros(Float64, n)

    l[1] = 1.0
    c[1] = 0.0
    for i in 2:(n - 1)
        μ[i] = h[i] / (2.0 * (h[i - 1] + h[i]) - l[i - 1] * h[i - 1])
        l[i] = 1.0 - μ[i] * h[i - 1]
    end
    l[n] = 1.0

    for i in 2:(n - 1)
        c[i] = α[i] - l[i - 1] * c[i - 1]
    end
    b[n] = 0.0
    for i in (n - 1):-1:1
        b[i] = c[i] * μ[i] + b[i + 1]
    end
    d = zeros(Float64, n)

    # Compute a, b, c, d coefficients for each segment
    a = [ys[i] for i in 1:(n - 1)]
    b_co = [b[i] for i in 1:(n - 1)]
    c_co = [c[i] for i in 1:n]
    d_co = [(c_co[i + 1] - c_co[i]) / (3.0 * h[i]) for i in 1:(n - 1)]

    # Return flattened: [a1, b1, c1, d1, a2, b2, c2, d2, ...]
    # Actually store as segment-based for easy access
    return vcat([a; b_co; c_co; d_co])
end

function _spline_segment_coeffs(itp::CubicSpline, idx::Int)
    a = itp.cs[idx]
    b = itp.cs[itp.n + idx]
    c = itp.cs[2 * itp.n - 1 + idx]
    d = itp.cs[3 * itp.n - 2 + idx]
    return a, b, c, d
end

function (itp::CubicSpline)(t::Float64)::Float64
    xs = itp.xs
    n = itp.n

    if t <= xs[1]
        return itp.ys[1]
    end
    if t >= xs[n]
        return itp.ys[n]
    end

    # Find the segment
    idx = 1
    for k in 1:(n - 1)
        if t <= xs[k + 1]
            idx = k
            break
        end
    end

    a, b, c, d = _spline_segment_coeffs(itp, idx)
    dt = t - xs[idx]
    return a + b * dt + c * dt^2 + d * dt^3
end

# Convenience constructors matching Interpolations.jl style
Linear() = Linear(Float64[], Float64[])  # empty, filled by make_curve

"""
Build a linear or cubic spline interpolation from (t, rate) pairs.
"""
function interpolate(itp_type::Type{Linear}, xs::Vector{Float64}, ys::Vector{Float64})
    return Linear(xs, ys)
end

function interpolate(itp_type::Type{CubicSpline}, xs::Vector{Float64}, ys::Vector{Float64})
    return CubicSpline(xs, ys)
end

# ─────────────────────────────────────────────
# Rate Primitives (shared with MarketEnv)
# ─────────────────────────────────────────────

# Rate types — parametric for extensibility
@enum RateType ZeroRate ForwardRate DiscountFactor SwapRate LiborRate SofrRate

struct RateNode
    as_of::Date
    date::Date
    year_fraction::Float64
    rate::Float64
    rate_type::RateType
    convention::String       # e.g., "ACT/360", "30/360"
    source::String           # e.g., "Bloomberg", "Norgate", "internal"
end

# ─────────────────────────────────────────────
# Date Utilities
# ─────────────────────────────────────────────

function yearfrac(as_of::Date, target::Date; convention::String = "ACT/360")
    days = Dates.value(target - as_of)
    if convention == "ACT/360"
        return days / day_count("ACT_360")
    elseif convention == "ACT/365"
        return days / day_count("ACT_365")
    elseif convention == "30/360"
        y1, m1, d1 = Dates.year(as_of), Dates.month(as_of), Dates.day(as_of)
        y2, m2, d2 = Dates.year(target), Dates.month(target), Dates.day(target)
        return ((y2 - y1) * 360 + (m2 - m1) * 30 + (d2 - d1)) / day_count("DE300_D")
    else
        return days / day_count("ACT_365")
    end
end

# ─────────────────────────────────────────────
# ZeroCurve (original implementation)
# ─────────────────────────────────────────────

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
Tenor in years from the curve's issue date to `date`, using the given
day-count convention, default ACT/365.
"""
function tenor(c::ZeroCurve, date::Date; day_count::Float64 = day_count("ACT_365"))::Float64
    return (date - c.issue_date).value / day_count
end

"""
Interpolated continuously compounded zero rate for maturity `date`.

The zero rate is defined as `-log(discount_factor)/tenor`; at zero tenor it is
the first node's rate.
"""
function zero_rate(c::ZeroCurve, date::Date; day_count::Float64 = day_count("ACT_365"))::Float64
    t = tenor(c, date; day_count=day_count)
    if t <= 0.0
        return c.nodes[1][2]
    end
    return -log(discount_factor(c, date; day_count=day_count)) / t
end

"""
Discount factor from the curve's issue date to `date`.
"""
function discount_factor(c::ZeroCurve, date::Date; day_count::Float64 = day_count("ACT_365"))::Float64
    t = tenor(c, date; day_count=day_count)
    @assert t >= 0.0 "Date must be on or after the curve issue date"

    nodes = c.nodes
    n = length(nodes)
    ts = [tenor(c, d; day_count=day_count) for (d, _) in nodes]
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
year fraction of the period under the given day-count convention (default ACT/365).
"""
function forward_rate(c::ZeroCurve, start_date::Date, end_date::Date; day_count::Float64 = day_count("ACT_365"))::Float64
    @assert start_date < end_date "Start date must be before the end date"
    τ = (end_date - start_date).value / day_count
    return (discount_factor(c, start_date; day_count=day_count) / discount_factor(c, end_date; day_count=day_count) - 1.0) / τ
end

# ─────────────────────────────────────────────
# Parametric Curve Types
# ─────────────────────────────────────────────

abstract type AbstractCurve end

# Parametric curve: the interpolation method is a type parameter
struct Curve{I <: AbstractInterpolation} <: AbstractCurve
    as_of::Date
    nodes::Vector{RateNode}
    interpolation::I          # e.g., Linear(), CubicSpline(), etc.
    currency::String
    day_count::String
    name::String
end

# Convenience constructor
function make_curve(
    as_of::Date,
    dates::Vector{Date},
    rates::Vector{Float64},
    rate_type::RateType;
    currency::String = "USD",
    day_count::String = "ACT/360",
    interp_method::Type{<:AbstractInterpolation} = Linear,
    name::String = "GenericCurve"
)
    nodes = [RateNode(as_of, d, yearfrac(as_of, d; convention = day_count), r, rate_type, day_count, "internal")
             for (d, r) in zip(dates, rates)]

    # Build interpolation from year fractions and rates
    t = [n.year_fraction for n in nodes]
    itp = interpolate(interp_method, t, rates)

    return Curve(as_of, nodes, itp, currency, day_count, name)
end

# ─────────────────────────────────────────────
# Concrete Curve Types
# ─────────────────────────────────────────────

struct YieldCurve{I <: AbstractInterpolation} <: AbstractCurve
    base::Curve{I}
    bootstrap_method::Symbol   # :bootstrapping, :fitting, :interpolation
end

struct ForwardCurve{I <: AbstractInterpolation} <: AbstractCurve
    base::Curve{I}
    index_tenor::String        # e.g., "3M", "6M"
    index_name::String         # e.g., "SOFR", "EURIBOR"
end

struct DiscountCurve{I <: AbstractInterpolation} <: AbstractCurve
    base::Curve{I}
    ois_basis::Bool            # true if OIS-discounted
end

struct BasisCurve{I <: AbstractInterpolation} <: AbstractCurve
    base::Curve{I}
    reference_curve::String    # e.g., "SOFR"
    spread::Float64
end

struct CreditCurve{I <: AbstractInterpolation} <: AbstractCurve
    base::Curve{I}
    recovery_rate::Float64
    default_model::Symbol      # :merton, :reduced_form, :hazard
end

# ─────────────────────────────────────────────
# Volatility Surfaces
# ─────────────────────────────────────────────

struct VolSurface{I1 <: AbstractInterpolation, I2 <: AbstractInterpolation}
    as_of::Date
    expiries::Vector{Float64}     # time to expiry in years
    moneyness::Vector{Float64}    # K/S or strike as % of spot
    vols::Matrix{Float64}         # [expiry × moneyness]
    interp_expiry::I1
    interp_moneyness::I2
    surface_type::Symbol          # :implied_vol, :local_vol, :stochastic_vol
    instrument::Symbol            # :option, :caplet, :swaption
    currency::String
end

# Interpolation over the 2D surface (bilinear as fallback)
function interpolate_vol(surf::VolSurface{Linear, Linear})
    expiry_t = surf.expiries
    moneyness_t = surf.moneyness
    vols = surf.vols
    rows, cols = size(vols)

    # Bilinear: build separate 1D interpolators per expiry row,
    # then interpolate across expiries.
    # For simplicity, return a callable that does bilinear lookup.
    return _bilinear_vol_interp(expiry_t, moneyness_t, vols)
end

function _bilinear_vol_interp(expiries::Vector{Float64}, moneyness::Vector{Float64}, vols::Matrix{Float64})
    function interp(t::Float64, k::Float64)::Float64
        # Clamp to grid bounds
        t_clamp = max(expiries[1], min(expiries[end], t))
        k_clamp = max(moneyness[1], min(moneyness[end], k))

        # Find bracketing indices for expiry
        ti = 1
        for j in 1:(length(expiries) - 1)
            if t_clamp <= expiries[j + 1]
                ti = j
                break
            end
        end
        if ti >= length(expiries)
            ti = length(expiries) - 1
        end

        # Find bracketing indices for moneyness
        ki = 1
        for j in 1:(length(moneyness) - 1)
            if k_clamp <= moneyness[j + 1]
                ki = j
                break
            end
        end
        if ki >= length(moneyness)
            ki = length(moneyness) - 1
        end

        # Bilinear interpolation
        w_t = (t_clamp - expiries[ti]) / (expiries[ti + 1] - expiries[ti])
        w_k = (k_clamp - moneyness[ki]) / (moneyness[ki + 1] - moneyness[ki])

        v00 = vols[ti, ki]
        v01 = vols[ti, ki + 1]
        v10 = vols[ti + 1, ki]
        v11 = vols[ti + 1, ki + 1]

        return (1.0 - w_t) * ((1.0 - w_k) * v00 + w_k * v01) +
               w_t * ((1.0 - w_k) * v10 + w_k * v11)
    end
    return interp
end

# ─────────────────────────────────────────────
# Curve Operations via Multiple Dispatch
# ─────────────────────────────────────────────

# Get zero rate at any time t
function get_rate(curve::YieldCurve, t::Float64)
    return curve.base.interpolation(t)
end

# Get discount factor from a discount curve
function get_discount_factor(curve::DiscountCurve, t::Float64)
    z = curve.base.interpolation(t)
    return exp(-z * t)  # continuous compounding
end

# Get forward rate from a forward curve
function get_forward_rate(curve::ForwardCurve, t1::Float64, t2::Float64)
    r1 = curve.base.interpolation(t1)
    r2 = curve.base.interpolation(t2)
    return (r2 * t2 - r1 * t1) / (t2 - t1)
end

# ─────────────────────────────────────────────
# BondQuote & Bootstrapping (original)
# ─────────────────────────────────────────────

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
function bootstrap_zero_curve(issue_date::Date, quotes::Vector{BondQuote}; day_count::Float64 = day_count("ACT_365"))::ZeroCurve
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
                    prior_pv += amount * discount_factor(partial, date; day_count=day_count)
                end
            end
        end

        terminal = cfs[end][2]
        df = (bq.price - prior_pv) / terminal
        @assert df > 0.0 "Price ($(bq.price)) is not above the present value of the prior cash flows; the implied discount factor must be positive"

        t = (bond.maturity - issue_date).value / day_count
        push!(nodes, (bond.maturity, -log(df) / t))
        prev_maturity = bond.maturity
    end

    return ZeroCurve(issue_date, nodes)
end

# ─────────────────────────────────────────────
# Bootstrap Yield Curve (parametric)
# ─────────────────────────────────────────────

function bootstrap_yield_curve(
    as_of::Date,
    deposit_rates::Vector{Float64},
    deposit_tenors::Vector{Int},
    swap_rates::Vector{Float64},
    swap_tenors::Vector{Int};
    currency::String = "USD",
    interp_method::Type{Linear} = Linear,
    day_count::Float64 = day_count("ACT_360")
)
    # Step 1: Build short-end from deposits
    deposit_dates = [as_of + Year(tenor) for tenor in deposit_tenors]
    deposit_dfs = [1.0 / (1.0 + r * t) for (r, t) in zip(deposit_rates, deposit_tenors ./ day_count)]

    # Step 2: Bootstrap swaps (simplified)
    all_dates = vcat(deposit_dates, [as_of + Year(t) for t in swap_tenors])
    all_rates = vcat(deposit_rates, swap_rates)

    # Sort by date
    perm = sortperm(all_dates)
    all_dates = all_dates[perm]
    all_rates = all_rates[perm]

    return YieldCurve(
        Curve(as_of,
              [RateNode(as_of, d, yearfrac(as_of, d), r, ZeroRate, "ACT/360", "bootstrap")
               for (d, r) in zip(all_dates, all_rates)],
              interpolate(interp_method,
                          [yearfrac(as_of, d) for d in all_dates],
                          all_rates),
              currency, "ACT/360", "Bootstrapped"),
        :bootstrapping
    )
end

end # module Curves
