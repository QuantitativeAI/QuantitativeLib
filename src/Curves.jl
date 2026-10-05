# src/Curves.jl

module Curves

using Dates

using ..Instruments: Bond, ZeroCouponBond, CouponBond
using ..SystemConfig: day_count

export InterestCurve, ZeroCurve, NelsonSiegelCurve, NelsonSiegelSvenssonCurve
export tenor, zero_rate, discount_factor, forward_rate, ns_zero_rate, ns_svensson_zero_rate, fit_nelson_siegel, fit_nelson_siegel_svensson
export BondQuote, cash_flows, bootstrap_zero_curve, bootstrap_yield_curve
export AbstractInterpolation, Linear, CubicSpline, MonotoneCubic, interpolate
export make_curve, get_rate, get_discount_factor, get_forward_rate
export RateType, ZeroRate, ForwardRate, DiscountFactor, SwapRate, LiborRate, SofrRate, RateNode, yearfrac, VolSurface, interpolate_vol
export YieldCurve, ForwardCurve, DiscountCurve, BasisCurve, CreditCurve
export Compounding, ContinuousCompounding, AnnualCompounding, SemiAnnualCompounding, QuarterlyCompounding, MonthlyCompounding, SimpleCompounding
export convert_rate, zero_to_par, par_to_zero
export survival_probability, default_probability, credit_spread, hazard_to_spread, spread_to_hazard



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
# Monotone Cubic Interpolation (PCHIP)
# ─────────────────────────────────────────────

"""
    _pchip_slopes(xs, ys) -> Vector{Float64}

Compute the Fritsch-Carlson PCHIP node slopes for a data set: an initial slope
at each node from a weighted harmonic mean of adjacent divided differences,
then scaled to guarantee per-segment monotonicity (no overshoot).
"""
function _pchip_slopes(xs::Vector{Float64}, ys::Vector{Float64})::Vector{Float64}
    n = length(xs)
    ds = zeros(Float64, n)
    if n == 2
        ds[1] = (ys[2] - ys[1]) / (xs[2] - xs[1])
        ds[2] = ds[1]
        return ds
    end

    h = [xs[i + 1] - xs[i] for i in 1:(n - 1)]
    delta = [(ys[i + 1] - ys[i]) / h[i] for i in 1:(n - 1)]

    # First node: derivative of the quadratic through the first three points.
    ds[1] = ((2.0 * h[1] + h[2]) * delta[1] - h[1] * delta[2]) / (h[1] + h[2])
    # Interior nodes: weighted harmonic mean of the neighbouring divided diffs.
    for i in 2:(n - 1)
        w1 = 2.0 * h[i - 1] + h[i]
        w2 = h[i - 1] + 2.0 * h[i]
        ds[i] = (w2 * delta[i - 1] + w1 * delta[i]) / (w1 + w2)
    end
    # Last node: derivative of the quadratic through the last three points.
    ds[n] = ((2.0 * h[n - 1] + h[n - 2]) * delta[n - 1] - h[n - 1] * delta[n - 2]) / (h[n - 2] + h[n - 1])

    # Enforce per-segment monotonicity (Fritsch-Carlson 1980).
    for i in 1:(n - 1)
        d = delta[i]
        d == 0.0 && (ds[i] = 0.0; ds[i + 1] = 0.0; continue)
        alpha = ds[i] / d
        beta = ds[i + 1] / d
        if alpha < 0.0 || beta < 0.0
            # Slope opposite to the chord: flatten the node.
            ds[i] = 0.0
            ds[i + 1] = 0.0
        elseif alpha^2 + beta^2 > 9.0
            # Too steep: shrink toward the chord so the cubic stays in-band.
            scale = 3.0 / sqrt(alpha^2 + beta^2)
            ds[i] *= scale
            ds[i + 1] *= scale
        end
    end
    return ds
end

"""
Monotone cubic (PCHIP / Fritsch-Carlson) interpolation on a pre-computed grid of
(tenor, rate) pairs. Unlike [`CubicSpline`](@ref), which minimises curvature and
can overshoot between widely-spaced nodes, PCHIP chooses node slopes so the
interpolant is piecewise-monotone: it never overshoots the data and preserves
local monotonicity. This makes it well suited to bootstrapped or market curves
where monotonicity is desired.
"""
struct MonotoneCubic <: AbstractInterpolation
    xs::Vector{Float64}
    ys::Vector{Float64}
    ds::Vector{Float64}     # node slopes (dy/dx at each node)

    function MonotoneCubic(xs::Vector{Float64}, ys::Vector{Float64})
        @assert length(xs) == length(ys) "xs and ys must have the same length"
        @assert length(xs) >= 2 "Need at least 2 points for monotone cubic"
        @assert all(i -> i == 1 || xs[i - 1] < xs[i], eachindex(xs)) "xs must be strictly increasing"
        ds = _pchip_slopes(xs, ys)
        return new(xs, ys, ds)
    end
end

function (itp::MonotoneCubic)(t::Float64)::Float64
    xs = itp.xs
    ys = itp.ys
    ds = itp.ds
    n = length(xs)

    if t <= xs[1]
        return ys[1]
    end
    if t >= xs[n]
        return ys[n]
    end

    # Find the bracketing segment.
    idx = 1
    for k in 1:(n - 1)
        if t <= xs[k + 1]
            idx = k
            break
        end
    end

    h = xs[idx + 1] - xs[idx]
    s = (t - xs[idx]) / h
    # Cubic Hermite basis on the local coordinate s ∈ [0, 1]; derivatives are
    # dy/dx, so the slope terms carry the segment width h.
    h00 = 2.0 * s^3 - 3.0 * s^2 + 1.0
    h10 = s^3 - 2.0 * s^2 + s
    h01 = -2.0 * s^3 + 3.0 * s^2
    h11 = s^3 - s^2
    return h00 * ys[idx] + h10 * h * ds[idx] + h01 * ys[idx + 1] + h11 * h * ds[idx + 1]
end

function interpolate(itp_type::Type{MonotoneCubic}, xs::Vector{Float64}, ys::Vector{Float64})
    return MonotoneCubic(xs, ys)
end

# ─────────────────────────────────────────────
# Rate Primitives (shared with MarketEnv)
# ─────────────────────────────────────────────

# Rate types — parametric for extensibility
@enum RateType ZeroRate ForwardRate DiscountFactor SwapRate LiborRate SofrRate

# Compounding conventions for rate conversion.
#   ContinuousCompounding → DF = exp(-r t)
#   Annual/SemiAnnual/Quarterly/Monthly → DF = (1 + r/m)^(-m t)
#   SimpleCompounding     → DF = 1 / (1 + r t)
@enum Compounding ContinuousCompounding AnnualCompounding SemiAnnualCompounding QuarterlyCompounding MonthlyCompounding SimpleCompounding

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
# Rate Conversions (compounding & par↔zero)
# ─────────────────────────────────────────────

# Number of compounding periods per year for a convention.
#   Inf → continuous compounding,  0 → simple (single payment at period end)
function _compounding_periods(c::Compounding)::Float64
    if c === ContinuousCompounding
        return Inf
    elseif c === AnnualCompounding
        return 1.0
    elseif c === SemiAnnualCompounding
        return 2.0
    elseif c === QuarterlyCompounding
        return 4.0
    elseif c === MonthlyCompounding
        return 12.0
    else  # SimpleCompounding
        return 0.0
    end
end

"""
    _accumulation(r, t, comp) -> Float64

The accumulation (growth) factor — the reciprocal of a discount factor — for a
rate `r` applied over tenor `t` (years) under compounding convention `comp`.
"""
function _accumulation(r::Float64, t::Float64, comp::Compounding)::Float64
    t <= 0.0 && return 1.0
    m = _compounding_periods(comp)
    if m == Inf
        return exp(r * t)
    elseif m == 0.0
        return 1.0 + r * t
    else
        return (1.0 + r / m)^(m * t)
    end
end

"""
    _rate_from_accumulation(a, t, comp) -> Float64

Inverse of [`_accumulation`](@ref): the rate over tenor `t` whose accumulation
factor equals `a` under convention `comp`.
"""
function _rate_from_accumulation(a::Float64, t::Float64, comp::Compounding)::Float64
    t <= 0.0 && return 0.0
    m = _compounding_periods(comp)
    if m == Inf
        return log(a) / t
    elseif m == 0.0
        return (a - 1.0) / t
    else
        return m * (a^(1.0 / (m * t)) - 1.0)
    end
end

"""
    convert_rate(r, t; from=ContinuousCompounding, to=AnnualCompounding) -> Float64

Convert a rate `r` (applicable over tenor `t` in years) from one compounding
convention to another, preserving the implied discount factor — i.e. the return
over the period `t` is unchanged. For example, 5% continuous over one year is
`exp(0.05) - 1` ≈ 5.127% annual or `2(exp(0.025) - 1)` ≈ 5.094% semi-annual.
"""
function convert_rate(r::Float64, t::Float64;
                      from::Compounding = ContinuousCompounding,
                      to::Compounding = AnnualCompounding)::Float64
    return _rate_from_accumulation(_accumulation(r, t, from), t, to)
end

"""
    zero_to_par(tenors, zeros) -> Vector{Float64}

Convert a term structure of continuously-compounded zero rates to a par (coupon)
curve. The par rate at tenor `tₙ` is the fixed coupon rate of a bond trading at
par (price = face),

    par(tₙ) = (1 - DF(tₙ)) / Σᵢ DF(tᵢ),   with   DF(tᵢ) = exp(-zᵢ tᵢ).

# Requirements
- `tenors` strictly increasing and strictly positive; same length as `zeros`.
"""
function zero_to_par(tenors::Vector{Float64}, zeros::Vector{Float64})::Vector{Float64}
    @assert length(tenors) == length(zeros) "tenors and zeros must have the same length"
    @assert all(t -> t > 0.0, tenors) "Tenors must be strictly positive"
    @assert all(i -> i == 1 || tenors[i - 1] < tenors[i], eachindex(tenors)) "Tenors must be strictly increasing"

    n = length(tenors)
    par = Vector{Float64}(undef, n)
    cum_df = 0.0
    for i in 1:n
        df = exp(-zeros[i] * tenors[i])
        cum_df += df
        par[i] = (1.0 - df) / cum_df
    end
    return par
end

"""
    par_to_zero(tenors, pars) -> Vector{Float64}

Convert a par (coupon) curve to continuously-compounded zero rates, the inverse
of [`zero_to_par`](@ref). The inputs must be strictly increasing in tenor.

# Requirements
- `tenors` strictly increasing and strictly positive; same length as `pars`.
- `pars` each greater than -1 (i.e. 1 + pᵢ > 0).
"""
function par_to_zero(tenors::Vector{Float64}, pars::Vector{Float64})::Vector{Float64}
    @assert length(tenors) == length(pars) "tenors and pars must have the same length"
    @assert all(t -> t > 0.0, tenors) "Tenors must be strictly positive"
    @assert all(i -> i == 1 || tenors[i - 1] < tenors[i], eachindex(tenors)) "Tenors must be strictly increasing"
    @assert all(p -> p > -1.0, pars) "Par rates must exceed -100% (1 + pᵢ > 0)"

    n = length(tenors)
    zeros = Vector{Float64}(undef, n)
    s_prev = 0.0
    for i in 1:n
        s_i = (1.0 + s_prev) / (1.0 + pars[i])
        d_i = s_i - s_prev
        @assert d_i > 0.0 "Implied discount factor must be positive at tenor $(tenors[i])"
        zeros[i] = -log(d_i) / tenors[i]
        s_prev = s_i
    end
    return zeros
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
# Nelson-Siegel Curve (parametric)
# ─────────────────────────────────────────────

"""
    ns_zero_rate(t, beta, tau) -> Float64

Nelson-Siegel (1992) continuously-compounded zero rate at tenor `t` (years)
for loadings `beta = (β0, β1, β2)` and time-scale `tau`:

```
z(t) = β0 + (β1 + β2) (1 - e^{-x})/x - β2 e^{-x},   x = t/τ
```

The rate is finite at both ends: `z(0) = β0 + β1` and `z(∞) = β0`, so `β0`
is the long-term level and `β1 + β2` the short-term level.
"""
function ns_zero_rate(t::Float64, beta::Vector{Float64}, tau::Float64)::Float64
    t <= 0.0 && return beta[1] + beta[2]
    x = t / tau
    e = exp(-x)
    phi = (1.0 - e) / x
    return beta[1] + (beta[2] + beta[3]) * phi - beta[3] * e
end

"""
A parametric interest-rate term structure based on the Nelson-Siegel (1992)
model. Unlike `ZeroCurve`, which is pinned at discrete nodes, the whole term
structure is described by four parameters: three loadings `β0, β1, β2` and a
single time-scale `τ > 0`. The zero rate is given by [`ns_zero_rate`](@ref).

# Fields
- `as_of::Date`: Valuation anchor; tenors are measured from this date.
- `beta::Vector{Float64}`: The loadings `(β0, β1, β2)`.
- `tau::Float64`: The time-scale parameter `τ` (in years).
- `day_count::Float64`: Divisor used to convert dates to year fractions.

# Constructor
- `NelsonSiegelCurve(as_of, beta, tau; day_count = day_count("ACT_365"))`
"""
struct NelsonSiegelCurve <: InterestCurve
    as_of::Date
    beta::Vector{Float64}
    tau::Float64
    day_count::Float64

    function NelsonSiegelCurve(as_of::Date, beta::Vector{Float64}, tau::Float64;
                               day_count::Float64 = day_count("ACT_365"))
        @assert length(beta) == 3 "Nelson-Siegel requires exactly three β loadings"
        @assert all(isfinite, beta) "β loadings must be finite"
        @assert tau > 0.0 "Nelson-Siegel time-scale τ must be positive"
        return new(as_of, beta, tau, day_count)
    end
end

"""
Tenor in years from the curve's `as_of` date to `date`, using the curve's
day-count convention.
"""
function tenor(c::NelsonSiegelCurve, date::Date; day_count::Float64 = c.day_count)::Float64
    return (date - c.as_of).value / day_count
end

"""
Interpolated continuously-compounded zero rate for maturity `date`.
"""
function zero_rate(c::NelsonSiegelCurve, date::Date; day_count::Float64 = c.day_count)::Float64
    return ns_zero_rate(tenor(c, date; day_count=day_count), c.beta, c.tau)
end

"""
Discount factor from the curve's `as_of` date to `date`.
"""
function discount_factor(c::NelsonSiegelCurve, date::Date; day_count::Float64 = c.day_count)::Float64
    t = tenor(c, date; day_count=day_count)
    @assert t >= 0.0 "Date must be on or after the curve as-of date"
    return exp(-zero_rate(c, date; day_count=day_count) * t)
end

"""
Simple forward rate implied by the curve between `start_date` and `end_date`,
consistent with `ZeroCurve.forward_rate`:
`discount_factor(start) = (1 + f * τ) * discount_factor(end)`.
"""
function forward_rate(c::NelsonSiegelCurve, start_date::Date, end_date::Date; day_count::Float64 = c.day_count)::Float64
    @assert start_date < end_date "Start date must be before the end date"
    τ = (end_date - start_date).value / day_count
    return (discount_factor(c, start_date; day_count=day_count) / discount_factor(c, end_date; day_count=day_count) - 1.0) / τ
end

"""
    _minimize_golden(f, a, b, tol, maxiter) -> x

Minimise a unimodal scalar function `f` on `[a, b]` with golden-section search.
Used to refine the Nelson-Siegel time-scale after a coarse grid search.
"""
function _minimize_golden(f, a::Float64, b::Float64, tol::Float64 = 1e-5, maxiter::Int = 100)
    gr = (sqrt(5.0) - 1.0) / 2.0
    c = b - gr * (b - a)
    d = a + gr * (b - a)
    fc = f(c)
    fd = f(d)
    for _ in 1:maxiter
        if fc < fd
            b, d, fd = d, c, fc
            c = b - gr * (b - a)
            fc = f(c)
        else
            a, c, fc = c, d, fd
            d = a + gr * (b - a)
            fd = f(d)
        end
        abs(b - a) < tol && break
    end
    return 0.5 * (a + b)
end

"""
    fit_nelson_siegel(as_of, tenors, rates; ...) -> NelsonSiegelCurve

Fit Nelson-Siegel loadings `(β0, β1, β2)` and time-scale `τ` to a set of
`(tenor, zero-rate)` observations by least squares.

The model is linear in the β loadings for a fixed `τ`, so fitting reduces to a
one-dimensional search over `τ`: for each candidate `τ` the optimal β is the
solution of a linear least-squares solve, and the `τ` minimising the residual
sum of squares is selected and then refined with a golden-section search.

# Arguments
- `as_of::Date`: Anchor date stored on the resulting curve.
- `tenors::Vector{Float64}`: Time-to-maturity in years (strictly positive).
- `rates::Vector{Float64}`: Continuously-compounded zero rates at those tenors.

# Keyword arguments
- `tau_lo`, `tau_hi`, `n_tau`: Bounds and grid density for the initial search.
- `day_count`: Divisor stored on the curve (default ACT/365).
"""
function fit_nelson_siegel(as_of::Date, tenors::Vector{Float64}, rates::Vector{Float64};
                           tau_lo::Float64 = 0.05, tau_hi::Float64 = 20.0,
                           n_tau::Int = 200, day_count::Float64 = day_count("ACT_365"))
    @assert length(tenors) == length(rates) "tenors and rates must have the same length"
    @assert all(t -> t > 0.0, tenors) "Tenors must be strictly positive"
    @assert length(tenors) >= 3 "Need at least three (tenor, rate) points to fit"

    # Residual sum of squares for a fixed τ (β solved by linear least squares).
    function rss(tau::Float64)::Float64
        X = Matrix{Float64}(undef, length(tenors), 3)
        for (i, t) in enumerate(tenors)
            x = t / tau
            e = exp(-x)
            phi = (1.0 - e) / x
            X[i, 1] = 1.0
            X[i, 2] = phi
            X[i, 3] = phi - e
        end
        beta = X \ rates
        r = X * beta .- rates
        return sum(abs2, r)  # residual sum of squares
    end

    # 1. Coarse grid search for the basin of the optimum.
    best_tau = tau_lo
    best_rss = Inf
    for tau in range(tau_lo, tau_hi, length=n_tau)
        r = rss(tau)
        if r < best_rss
            best_rss = r
            best_tau = tau
        end
    end

    # 2. Refine τ with a golden-section search around the grid optimum.
    golden_tau = _minimize_golden(rss, max(0.01, best_tau * 0.5), best_tau * 1.5, 1e-6, 100)
    if rss(golden_tau) < best_rss
        best_tau = golden_tau
    end

    # Solve for the optimal β at the refined τ.
    X = Matrix{Float64}(undef, length(tenors), 3)
    for (i, t) in enumerate(tenors)
        x = t / best_tau
        e = exp(-x)
        phi = (1.0 - e) / x
        X[i, 1] = 1.0
        X[i, 2] = phi
        X[i, 3] = phi - e
    end
    beta = X \ rates

    return NelsonSiegelCurve(as_of, collect(beta), best_tau; day_count=day_count)
end

# ─────────────────────────────────────────────
# Nelson-Siegel-Svensson Curve (parametric)
# ─────────────────────────────────────────────

"""
    ns_svensson_zero_rate(t, beta, tau1, tau2) -> Float64

Nelson-Siegel-Svensson (1995) continuously-compounded zero rate at tenor `t`
(years) for loadings `beta = (β0, β1, β2, β3, β4)` and time-scales `tau1, tau2`:

```
y(t) = β0 + (β1 + β2)(1 - e^{-x1})/x1 - β2 e^{-x1}
           + (β3 + β4)(1 - e^{-x2})/x2 - β4 e^{-x2},   x1 = t/τ1, x2 = t/τ2
```

The rate is finite at both ends: `y(0) = β0 + β1 + β3` and `y(∞) = β0`. The
second decay block adds independent curvature to the curve, so unlike Nelson-Siegel
the short-term level also carries `β3`. It reduces to [`ns_zero_rate`](@ref) when
`β3 = β4 = 0`.
"""
function ns_svensson_zero_rate(t::Float64, beta::Vector{Float64}, tau1::Float64, tau2::Float64)::Float64
    t <= 0.0 && return beta[1] + beta[2] + beta[4]
    x1 = t / tau1
    x2 = t / tau2
    e1 = exp(-x1)
    e2 = exp(-x2)
    # -expm1(-x)/x → 1 as x → 0 without the catastrophic cancellation of
    # (1 - e^-x)/x at small tenors.
    phi1 = -expm1(-x1) / x1
    phi2 = -expm1(-x2) / x2
    return beta[1] + (beta[2] + beta[3]) * phi1 - beta[3] * e1 +
           (beta[4] + beta[5]) * phi2 - beta[5] * e2
end

"""
A parametric interest-rate term structure based on the Nelson-Siegel-Svensson
(1995) model. It extends [`NelsonSiegelCurve`](@ref) with a second decay block,
giving the short- and long-end of the curve independent curvature. The whole
structure is described by five loadings `β0..β4` and two time-scales `τ1, τ2`;
the zero rate is given by [`ns_svensson_zero_rate`](@ref).

# Fields
- `as_of::Date`: Valuation anchor; tenors are measured from this date.
- `beta::Vector{Float64}`: The loadings `(β0, β1, β2, β3, β4)`.
- `tau1, tau2::Float64`: The two time-scale parameters (in years).
- `day_count::Float64`: Divisor used to convert dates to year fractions.

# Constructor
- `NelsonSiegelSvenssonCurve(as_of, beta, tau1, tau2; day_count = day_count("ACT_365"))`
"""
struct NelsonSiegelSvenssonCurve <: InterestCurve
    as_of::Date
    beta::Vector{Float64}
    tau1::Float64
    tau2::Float64
    day_count::Float64

    function NelsonSiegelSvenssonCurve(as_of::Date, beta::Vector{Float64}, tau1::Float64, tau2::Float64;
                                       day_count::Float64 = day_count("ACT_365"))
        @assert length(beta) == 5 "Nelson-Siegel-Svensson requires exactly five β loadings"
        @assert all(isfinite, beta) "β loadings must be finite"
        @assert tau1 > 0.0 "Nelson-Siegel-Svensson time-scale τ1 must be positive"
        @assert tau2 > 0.0 "Nelson-Siegel-Svensson time-scale τ2 must be positive"
        @assert tau1 != tau2 "τ1 and τ2 must differ"
        return new(as_of, beta, tau1, tau2, day_count)
    end
end

function tenor(c::NelsonSiegelSvenssonCurve, date::Date; day_count::Float64 = c.day_count)::Float64
    return (date - c.as_of).value / day_count
end

function zero_rate(c::NelsonSiegelSvenssonCurve, date::Date; day_count::Float64 = c.day_count)::Float64
    return ns_svensson_zero_rate(tenor(c, date; day_count=day_count), c.beta, c.tau1, c.tau2)
end

function discount_factor(c::NelsonSiegelSvenssonCurve, date::Date; day_count::Float64 = c.day_count)::Float64
    t = tenor(c, date; day_count=day_count)
    @assert t >= 0.0 "Date must be on or after the curve as-of date"
    return exp(-zero_rate(c, date; day_count=day_count) * t)
end

function forward_rate(c::NelsonSiegelSvenssonCurve, start_date::Date, end_date::Date; day_count::Float64 = c.day_count)::Float64
    @assert start_date < end_date "Start date must be before the end date"
    τ = (end_date - start_date).value / day_count
    return (discount_factor(c, start_date; day_count=day_count) / discount_factor(c, end_date; day_count=day_count) - 1.0) / τ
end

"""
    fit_nelson_siegel_svensson(as_of, tenors, rates; ...) -> NelsonSiegelSvenssonCurve

Fit Nelson-Siegel-Svensson loadings `(β0..β4)` and time-scales `(τ1, τ2)` to a
set of `(tenor, zero-rate)` observations by least squares.

The model is linear in the β loadings for fixed `(τ1, τ2)`, so fitting reduces
to a two-dimensional search over the time-scales: for each candidate pair the
optimal β is the solution of a linear least-squares solve, and the pair
minimising the residual sum of squares is selected and then refined by
coordinate-wise golden-section search.

# Arguments
- `as_of::Date`: Anchor date stored on the resulting curve.
- `tenors::Vector{Float64}`: Time-to-maturity in years (strictly positive).
- `rates::Vector{Float64}`: Continuously-compounded zero rates at those tenors.

# Keyword arguments
- `tau1_lo`, `tau1_hi`, `tau2_lo`, `tau2_hi`, `n_tau`: Bounds and grid density
  for the initial search.
- `day_count`: Divisor stored on the curve (default ACT/365).
"""
function fit_nelson_siegel_svensson(as_of::Date, tenors::Vector{Float64}, rates::Vector{Float64};
                                    tau1_lo::Float64 = 0.05, tau1_hi::Float64 = 20.0,
                                    tau2_lo::Float64 = 0.05, tau2_hi::Float64 = 20.0,
                                    n_tau::Int = 150, day_count::Float64 = day_count("ACT_365"))
    @assert length(tenors) == length(rates) "tenors and rates must have the same length"
    @assert all(t -> t > 0.0, tenors) "Tenors must be strictly positive"
    @assert length(tenors) >= 5 "Need at least five (tenor, rate) points to fit"

    # Design-matrix columns for a fixed (τ1, τ2); the β solve is linear.
    function design(tau1::Float64, tau2::Float64)::Matrix{Float64}
        X = Matrix{Float64}(undef, length(tenors), 5)
        for (i, t) in enumerate(tenors)
            x1 = t / tau1
            x2 = t / tau2
            e1 = exp(-x1)
            e2 = exp(-x2)
            phi1 = -expm1(-x1) / x1
            phi2 = -expm1(-x2) / x2
            X[i, 1] = 1.0
            X[i, 2] = phi1
            X[i, 3] = phi1 - e1
            X[i, 4] = phi2
            X[i, 5] = phi2 - e2
        end
        return X
    end

    # Residual sum of squares for fixed (τ1, τ2) (β solved by linear least squares).
    function rss(tau1::Float64, tau2::Float64)::Float64
        X = design(tau1, tau2)
        beta = X \ rates
        r = X * beta .- rates
        return sum(abs2, r)
    end

    # 2D grid search for the basin of the optimum.
    best = (rss=Inf, tau1=tau1_lo, tau2=tau2_lo)
    for tau1 in range(tau1_lo, tau1_hi, length=n_tau)
        for tau2 in range(tau2_lo, tau2_hi, length=n_tau)
            r = rss(tau1, tau2)
            if r < best.rss
                best = (rss=r, tau1=tau1, tau2=tau2)
            end
        end
    end

    # Local 2D refinement around the grid optimum. A coordinate-wise search can
    # stall at a fixed point because τ1 and τ2 are correlated, so instead scan a
    # fine 2D grid in a small window (±3 grid spacings) that is guaranteed to
    # contain the grid optimum and, hence, the true minimum.
    spacing = max(1e-3, (tau1_hi - tau1_lo) / max(1, n_tau - 1))
    m = 200
    for a in range(best.tau1 - 3 * spacing, best.tau1 + 3 * spacing, length=m)
        for b in range(best.tau2 - 3 * spacing, best.tau2 + 3 * spacing, length=m)
            r = rss(a, b)
            if r < best.rss
                best = (rss=r, tau1=a, tau2=b)
            end
        end
    end

    # Solve for the optimal β at the refined (τ1, τ2).
    X = design(best.tau1, best.tau2)
    beta = X \ rates

    return NelsonSiegelSvenssonCurve(as_of, collect(beta), best.tau1, best.tau2; day_count=day_count)
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

    function CreditCurve(base::Curve{I}, recovery_rate::Float64, default_model::Symbol) where I
        @assert 0.0 <= recovery_rate < 1.0 "Recovery rate must be in [0, 1)"
        @assert default_model in (:merton, :reduced_form, :hazard) "Unknown default model: $default_model"
        return new{I}(base, recovery_rate, default_model)
    end
end

# ─────────────────────────────────────────────
# Credit Curves (default-intensity / reduced form)
# ─────────────────────────────────────────────

"""
    _integrate_hazard(h, xs, t) -> Float64

Integrate a callable hazard/intensity curve `h(s)` from 0 to tenor `t` using the
trapezoidal rule over the curve's own nodes (with a flat lead-in before the first
node and a flat tail after the last, matching the interpolation's extrapolation).
For a piecewise-linear hazard this is exact.
"""
function _integrate_hazard(h, xs::Vector{Float64}, t::Float64)::Float64
    t <= 0.0 && return 0.0
    nodes = Float64[0.0]
    for x in xs
        x <= t && push!(nodes, x)
    end
    push!(nodes, t)
    sort!(nodes)
    total = 0.0
    for i in 1:(length(nodes) - 1)
        a, b = nodes[i], nodes[i + 1]
        total += 0.5 * (h(a) + h(b)) * (b - a)
    end
    return total
end

"""
    survival_probability(cc::CreditCurve, t) -> Float64

Cumulative probability of surviving (no default) up to tenor `t` years, under the
hazard (default-intensity) model encoded by the curve's `base`. With `h(s)` the
hazard rate,

    Q(t) = exp(-∫₀ᵢ h(s) ds).

The `base` curve of a `CreditCurve` is the hazard/intensity curve; risk-free
discounting is applied separately by the caller.
"""
function survival_probability(cc::CreditCurve, t::Float64)::Float64
    h = cc.base.interpolation
    return exp(-_integrate_hazard(h, h.xs, t))
end

"""
    default_probability(cc::CreditCurve, t) -> Float64

Cumulative probability of default before or at tenor `t`, i.e. `1 - Q(t)` from
[`survival_probability`](@ref).
"""
function default_probability(cc::CreditCurve, t::Float64)::Float64
    return 1.0 - survival_probability(cc, t)
end

"""
    credit_spread(cc::CreditCurve, t) -> Float64

The constant continuous spread over the risk-free rate implied by the credit
curve at tenor `t`. With recovery rate `R` and survival probability `Q(t)`, the
risky discount factor is `DF_rf(t)·[R + (1-R)Q(t)]`, so the spread that discounts
the risk-free factor to the risky one is

    s(t) = -log(R + (1-R)Q(t)) / t.
"""
function credit_spread(cc::CreditCurve, t::Float64)::Float64
    @assert t > 0.0 "Tenor must be strictly positive"
    Q = survival_probability(cc, t)
    inner = cc.recovery_rate + (1.0 - cc.recovery_rate) * Q
    @assert inner > 0.0 "Recovery and survival must yield a positive risky discount factor"
    return -log(inner) / t
end

"""
    hazard_to_spread(hazard, t, recovery) -> Float64

Convert a flat default intensity (hazard rate) `hazard` over horizon `t` (years)
to the equivalent continuous credit spread with recovery rate `recovery`, using
`Q(t) = exp(-h t)` and `s = -log(R + (1-R)Q))/t`.
"""
function hazard_to_spread(hazard::Float64, t::Float64, recovery::Float64)::Float64
    @assert t > 0.0 "Horizon must be strictly positive"
    @assert 0.0 <= recovery < 1.0 "Recovery rate must be in [0, 1)"
    Q = exp(-hazard * t)
    inner = recovery + (1.0 - recovery) * Q
    @assert inner > 0.0 "Parameters must yield a positive risky discount factor"
    return -log(inner) / t
end

"""
    spread_to_hazard(spread, t, recovery) -> Float64

Inverse of [`hazard_to_spread`](@ref): recover the flat default intensity that
produces a given continuous credit spread `spread` over horizon `t` with recovery
`recovery`.
"""
function spread_to_hazard(spread::Float64, t::Float64, recovery::Float64)::Float64
    @assert t > 0.0 "Horizon must be strictly positive"
    @assert 0.0 <= recovery < 1.0 "Recovery rate must be in [0, 1)"
    ratio = (exp(-spread * t) - recovery) / (1.0 - recovery)
    @assert ratio > 0.0 "Spread and recovery must be consistent (exp(-s t) > R)"
    return -log(ratio) / t
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

"""
Build the fixed-leg payment schedule of an interest-rate swap.

Payments fall every `12 / frequency` months, starting one period after `start`
and ending exactly on `end_date`. `frequency` is the number of fixed payments
per year (e.g. 2 for semi-annual, 1 for annual) and must divide 12.
"""
function _swap_schedule(start::Date, end_date::Date, frequency::Int)::Vector{Date}
    @assert frequency > 0 "Frequency must be positive"
    @assert 12 % frequency == 0 "Payment frequency ($frequency) must divide 12"
    step = div(12, frequency)
    dates = Date[]
    d = start + Month(step)
    while d <= end_date
        push!(dates, d)
        d += Month(step)
    end
    @assert !isempty(dates) "Swap has zero payment dates"
    @assert last(dates) == end_date "Schedule must end exactly at maturity"
    return dates
end

"""
Assemble a [`ZeroCurve`](@ref) from a dict of `(date, continuous-zero-rate)`
nodes, sorted by date. Swaps override deposits at any shared date.
"""
function _curve_from_nodes(as_of::Date, nodes::Dict{Date,Float64})::ZeroCurve
    dates = sort(collect(keys(nodes)))
    return ZeroCurve(as_of, [(d, nodes[d]) for d in dates])
end

"""
Solve the par-swap equation for the zero rate at maturity `T`.

A par swap at rate `K` satisfies `K = (1 - DF(T)) / A`, where `A = sum(delta_i
DF(s_i))` is the annuity over the fixed leg. Every payment before `T` is
discounted with the curve `Z` pinned so far, so `DF(T)` is the only unknown and
the equation is linear in it:

    DF(T) = (1 - K*A_prev) / (1 + K*delta_n),   z_T = -log(DF(T)) / tau_T

where `A_prev` is the annuity of the pre-maturity payments, `delta_n` the final
accrual fraction, and `tau_T` the tenor of `T`.
"""
function bootstrap_swap_node(Z::ZeroCurve, as_of::Date, maturity::Date,
                             par::Float64, frequency::Int, day_count::Float64)::Float64
    tau_T = (maturity - as_of).value / day_count
    @assert tau_T > 0 "Swap maturity must be after as_of"
    dates = _swap_schedule(as_of, maturity, frequency)
    n = length(dates)
    annuity_prev = 0.0
    prev = as_of
    delta_last = 0.0
    for i in 1:n
        delta = (dates[i] - prev).value / day_count
        if i == n
            delta_last = delta
        else
            annuity_prev += delta * discount_factor(Z, dates[i]; day_count=day_count)
        end
        prev = dates[i]
    end
    DF_T = (1.0 - par * annuity_prev) / (1.0 + par * delta_last)
    @assert DF_T > 0.0 "Bootstrapped discount factor non-positive (inconsistent par rate?)"
    return -log(DF_T) / tau_T
end

"""
Bootstrap a zero-rate yield curve from deposit and par-swap market quotes.

The short end is built from deposits; each par swap pins one additional zero
rate at its maturity by solving the par-swap equation in closed form (see
[`bootstrap_swap_node`](@ref)). Deposits are treated as simple rates over
calendar years and converted to continuously-compounded zeros; swaps are quoted
on an annualised par basis with `fixed_frequency` fixed payments per year.

# Arguments
- `deposit_rates`, `deposit_tenors`: simple deposit rates and their tenors in
  calendar years (matching pairs).
- `swap_rates`, `swap_tenors`: par swap rates and their tenors in calendar
  years (matching pairs).

# Keyword arguments
- `currency`: currency code stored on the curve (default `"USD"`).
- `interp_method`: interpolation type for the resulting curve (default `Linear`).
- `day_count`: day-count divisor used for all year-fraction math (default
  `day_count("ACT_360")`).
- `fixed_frequency`: fixed payments per year for the swaps (default `2`,
  semi-annual).
- `name`: label stored on the curve (default `"Bootstrapping"`).

# Returns
- A `YieldCurve` (method `:bootstrapping`) pinned at every deposit and swap
  maturity, with one continuously-compounded zero rate per node.
"""
function bootstrap_yield_curve(
    as_of::Date, deposit_rates::Vector{Float64}, deposit_tenors::Vector{Int},
    swap_rates::Vector{Float64}, swap_tenors::Vector{Int};
    currency::String = "USD", interp_method::Type{Linear} = Linear,
    day_count::Float64 = day_count("ACT_360"), fixed_frequency::Int = 2,
    name::String = "Bootstrapping")

    @assert !isempty(deposit_rates) "At least one deposit rate is required"
    @assert !isempty(swap_rates) "At least one swap rate is required"
    @assert length(deposit_rates) == length(deposit_tenors) "deposit_rates and deposit_tenors must have the same length"
    @assert length(swap_rates) == length(swap_tenors) "swap_rates and swap_tenors must have the same length"
    @assert all(t -> t > 0, deposit_tenors) "Deposit tenors must be positive"
    @assert all(t -> t > 0, swap_tenors) "Swap tenors must be positive"

    # Step 1: short end from deposits. A simple deposit rate r over tau years
    # implies DF = 1/(1 + r*tau); the equivalent continuous zero is log(1 + r*tau)/tau.
    node_rates = Dict{Date,Float64}()
    for (r, tenor) in zip(deposit_rates, deposit_tenors)
        d = as_of + Year(tenor)
        tau = (d - as_of).value / day_count
        node_rates[d] = log(1.0 + r * tau) / tau
    end

    # Step 2: bootstrap swaps, pinning one zero-rate node per swap. Each swap
    # depends only on the nodes already pinned, so the curve is rebuilt after
    # every step and the next swap discounts against it.
    Z = _curve_from_nodes(as_of, node_rates)
    for idx in sortperm(swap_tenors)
        maturity = as_of + Year(swap_tenors[idx])
        node_rates[maturity] = bootstrap_swap_node(Z, as_of, maturity, swap_rates[idx], fixed_frequency, day_count)
        Z = _curve_from_nodes(as_of, node_rates)
    end

    # Step 3: assemble the parametric curve.
    dates = sort(collect(keys(node_rates)))
    rates = [node_rates[d] for d in dates]
    dc_str = day_count ≈ 365.0 ? "ACT/365" : "ACT/360"
    curve = make_curve(as_of, dates, rates, ZeroRate;
                       currency=currency, day_count=dc_str, interp_method=interp_method, name=name)
    return YieldCurve(curve, :bootstrapping)
end

end # module Curves
