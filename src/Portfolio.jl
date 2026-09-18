# src/Portfolio.jl
#
# Portfolio management: a generic, nestable portfolio of financial instruments
# valued against a zero-rate curve, with risk metrics (duration, convexity,
# key-rate durations) and baseline-return analytics.
#
# Design:
# - `AbstractPortfolio <: Instrument` so portfolios can hold portfolios.
# - `market_value(inst, curve)` is the generic entry point; dispatch on the
#   instrument type. Users extend it for new instruments (e.g. an FRA) by
#   writing one method.
# - Curve shift utilities (`parallel_shifted_curve`, `shifted_curve`) let us
#   reprice under perturbations for numerical risk.
# - Cash-flow aggregation is generic via `cash_flows`; it is used to compute
#   analytical Macaulay duration for bond-like holdings and the portfolio's
#   yield. Swap holdings are valued via the existing `DiscountCurveSwapPricer`.

module PortfolioMgr

using Dates: Date, today
using ..QuantitativeCore: InstrumentCalendar, PeriodDays
using ..Instruments: Instrument, Bond, ZeroCouponBond, CouponBond
using ..SwapPricing: Swap, SwapLeg, Payment, DiscountCurveSwapPricer, present_value
using ..SwapPricing: TotalReturnSwap, TotalReturnSwapPricer, financing_payments, npv
using ..Curves: ZeroCurve, discount_factor as curve_discount_factor, tenor
import ..Curves: cash_flows  # extend the existing function with portfolio/swap methods
using ..SystemConfig: day_count
using Serialization  # `Serialization.serialize` / `Serialization.deserialize` are called
                     # qualified below; a plain `using Serialization: ...` can leave the
                     # binding unassigned when this file is `include`d in a context where
                     # `Serialization` is loaded for the first time.

export AbstractPortfolio, Portfolio, Holding
export add_instrument!, remove_instrument!, holdings
export market_value
export duration, convexity, key_rate_durations, macaulay_duration
export shifted_curve, parallel_shifted_curve
export portfolio_yield, expected_return
export PortfolioScenario, portfolio, valuation_curve, projected_curve, scenario_horizon, forward_curve
export scenario_value, scenario_yield, scenario_duration, scenario_convexity,
       scenario_key_rate_durations, scenario_return, scenario_summary
export save_scenario, load_scenario, compare_scenarios, scenario_table

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

"""
Abstract base type for portfolios: a generic holder of instruments.

Subtypes of `Instrument` so portfolios can be nested inside other portfolios
without any plumbing.
"""
abstract type AbstractPortfolio <: Instrument end

"""
A single line in a portfolio: an instrument and a quantity.

`quantity` is a multiplier on the instrument's cash flows / valuation. Positive
= long; negative = short.
"""
struct Holding
    instrument::Instrument
    quantity::Float64
    name::String

    function Holding(instrument::Instrument, quantity::Float64 = 1.0, name::String = "")
        @assert quantity != 0.0 "Quantity must be non-zero"
        return new(instrument, quantity, isempty(name) ? string(typeof(instrument)) : name)
    end
end

"""
A named, mutable portfolio of instrument holdings.
"""
mutable struct Portfolio <: AbstractPortfolio
    name::String
    holdings::Vector{Holding}
    valuation_date::Date

    function Portfolio(name::String = "Portfolio";
                       holdings::Vector{Holding} = Holding[],
                       valuation_date::Date = Date(today()))
        return new(name, holdings, valuation_date)
    end
end

"""
Add an instrument to the portfolio.

`quantity` defaults to 1.0. Pass a negative value for a short position.
"""
function add_instrument!(p::Portfolio, instrument::Instrument, quantity::Float64 = 1.0, name::String = "")::Nothing
    push!(p.holdings, Holding(instrument, quantity, name))
    return nothing
end

"""
Remove all holdings matching the given instrument (by identity) or by `name`.

If `name` is the empty string, instruments are matched by pointer. Otherwise
holdings whose `name` equals `name` are removed.
"""
function remove_instrument!(p::Portfolio, instrument::Instrument; name::String = "")::Nothing
    if name == ""
        filter!(h -> h.instrument !== instrument, p.holdings)
    else
        filter!(h -> h.name != name, p.holdings)
    end
    return nothing
end

"""
Return a vector of the portfolio's holdings.
"""
holdings(p::Portfolio)::Vector{Holding} = p.holdings

# ---------------------------------------------------------------------------
# Generic valuation
# ---------------------------------------------------------------------------

"""
Generic valuation of an instrument against a zero-rate curve.

Dispatch on the instrument type. Submodules can extend this for their own
types by defining `market_value(my_type, curve::ZeroCurve; day_count)`.
"""
function market_value(inst::Instrument, curve::ZeroCurve; day_count::Float64 = day_count("ACT_365"))::Float64
    error("market_value is not defined for instruments of type $(typeof(inst))")
end

"""
Value a zero-coupon bond: face value discounted at the curve's rate to maturity.
"""
function market_value(z::ZeroCouponBond, curve::ZeroCurve; day_count::Float64 = day_count("ACT_365"))::Float64
    return z.face_value * curve_discount_factor(curve, z.maturity; day_count=day_count)
end

"""
Value a coupon bond: sum of each cash flow discounted on the curve.

Uses `cash_flows` from `Curves` (which combines the final coupon and face
value into a single terminal payment, matching `Pricers.price`).
"""
function market_value(b::CouponBond, curve::ZeroCurve; day_count::Float64 = day_count("ACT_365"))::Float64
    pv = 0.0
    for (date, amount) in cash_flows(b)
        pv += amount * curve_discount_factor(curve, date; day_count=day_count)
    end
    return pv
end

"""
Value a nested portfolio: sum of quantity-weighted sub-portfolio values.

Because `AbstractPortfolio <: Instrument`, nested portfolios value
recursively.
"""
function market_value(p::AbstractPortfolio, curve::ZeroCurve; day_count::Float64 = day_count("ACT_365"))::Float64
    pv = 0.0
    for h in p.holdings
        pv += h.quantity * market_value(h.instrument, curve; day_count=day_count)
    end
    return pv
end

"""
Value a legs-based swap (from `SwapPricing`) against a zero-rate curve.

The convention is **long floating / short fixed**: `market_value = PV(floating)
− PV(fixed)`. A par swap (floating rate = par rate) has value ≈ 0 at
issuance. Users who are short floating / long fixed should negate the result.

Builds a `DiscountCurveSwapPricer` from the curve's discount factors.
"""
function market_value(s::Swap, curve::ZeroCurve; day_count::Float64 = day_count("ACT_365"))::Float64
    dfs = [(d, curve_discount_factor(curve, d; day_count=day_count))
           for (d, _) in curve.nodes]
    pricer = DiscountCurveSwapPricer(dfs)
    return present_value(s.floating_leg.payments, pricer; day_count=day_count) -
           present_value(s.fixed_leg.payments,  pricer; day_count=day_count)
end

"""
Value a total return swap (from `SwapPricing`) against a zero-rate curve.

The convention is **long total return / short financing**:
`market_value = PV(total return leg) − PV(financing leg)`. A swap with the
financing rate set to its par rate has value ≈ 0 at issuance. Users who are
short total return / long financing should negate the result.
"""
function market_value(trs::TotalReturnSwap, curve::ZeroCurve; day_count::Float64 = day_count("ACT_365"))::Float64
    dfs = [(d, curve_discount_factor(curve, d; day_count=day_count))
           for (d, _) in curve.nodes]
    pricer = TotalReturnSwapPricer(dfs)
    return npv(trs, pricer; day_count=day_count)
end

# ---------------------------------------------------------------------------
# Cash-flow aggregation
# ---------------------------------------------------------------------------

"""
Cash flows of a swap as (date, amount) pairs, sorted by date.

The convention matches `market_value(swap)`: positive for floating (long
floating), negative for fixed (short fixed).
"""
function cash_flows(s::Swap)::Vector{Tuple{Date, Float64}}
    flows = Tuple{Date, Float64}[]
    for p in s.fixed_leg.payments
        push!(flows, (p.date, -p.amount))
    end
    for p in s.floating_leg.payments
        push!(flows, (p.date, p.amount))
    end
    return sort(flows, by = x -> x[1])
end

"""
Cash flows of a total return swap as (date, amount) pairs, sorted by date.

The convention matches `market_value(trs)`: positive for the total return
leg (income plus the terminal capital gain/loss), negative for the financing
leg.
"""
function cash_flows(trs::TotalReturnSwap)::Vector{Tuple{Date, Float64}}
    flows = Tuple{Date, Float64}[]
    for p in trs.income_payments
        push!(flows, (p.date, p.amount))
    end
    capital_change = trs.end_value - trs.notional
    if capital_change != 0.0
        push!(flows, (trs.end_date, capital_change))
    end
    for p in financing_payments(trs)
        push!(flows, (p.date, -p.amount))
    end
    return sort(flows, by = x -> x[1])
end

"""
Cash flows of a portfolio: quantity-weighted aggregate of all sub-instrument
cash flows, sorted by date.
"""
function cash_flows(p::AbstractPortfolio)::Vector{Tuple{Date, Float64}}
    flows = Tuple{Date, Float64}[]
    for h in p.holdings
        for (date, amount) in cash_flows(h.instrument)
            push!(flows, (date, amount * h.quantity))
        end
    end
    return sort(flows, by = x -> x[1])
end

# ---------------------------------------------------------------------------
# Curve shift utilities
# ---------------------------------------------------------------------------

"""
Return a copy of `c` with the i-th node's zero rate shifted by `delta`.
"""
function shifted_curve(c::ZeroCurve, node_index::Int, delta::Float64)::ZeroCurve
    nodes = copy(c.nodes)
    nodes[node_index] = (nodes[node_index][1], nodes[node_index][2] + delta)
    return ZeroCurve(c.issue_date, nodes)
end

"""
Return a copy of `c` with every node's zero rate shifted by `delta`.
"""
function parallel_shifted_curve(c::ZeroCurve, delta::Float64)::ZeroCurve
    return ZeroCurve(c.issue_date, [(d, z + delta) for (d, z) in c.nodes])
end

"""
Return a copy of `c` with each node's zero rate shifted by the corresponding
entry in `deltas`.
"""
function shifted_curve(c::ZeroCurve, deltas::AbstractVector{<:Real})::ZeroCurve
    @assert length(deltas) == length(c.nodes) "deltas must have the same length as the curve's nodes"
    return ZeroCurve(c.issue_date, [(d, z + Δ) for ((d, z), Δ) in zip(c.nodes, deltas)])
end

# ---------------------------------------------------------------------------
# Risk metrics
# ---------------------------------------------------------------------------

"""
Macaulay duration (in years) of an instrument, computed from its cash flows.

On a continuously-compounded curve, Macaulay duration equals the sensitivity
of the log-price to the rate (i.e. modified duration). For a portfolio, the
cash flows are aggregated and the duration is the value-weighted average.
"""
function macaulay_duration(inst::Instrument, curve::ZeroCurve; day_count::Float64 = day_count("ACT_365"))::Float64
    v0 = market_value(inst, curve; day_count=day_count)
    pv_t = 0.0
    for (date, amount) in cash_flows(inst)
        t = tenor(curve, date; day_count=day_count)
        pv_t += t * amount * curve_discount_factor(curve, date; day_count=day_count)
    end
    return pv_t / v0
end

"""
Portfolio duration via symmetric parallel-shift finite differences (in years).

On a cc curve this equals the aggregate Macaulay duration. Uses a central
difference with step `shift` (default 1bp = 1e-4 in rate units).
"""
function duration(p::AbstractPortfolio, curve::ZeroCurve;
                  shift::Float64 = 1e-4, day_count::Float64 = day_count("ACT_365"))::Float64
    v0 = market_value(p, curve; day_count=day_count)
    v_up = market_value(p, parallel_shifted_curve(curve, shift); day_count=day_count)
    v_dn = market_value(p, parallel_shifted_curve(curve, -shift); day_count=day_count)
    return (v_dn - v_up) / (2.0 * shift * v0)
end

"""
Portfolio convexity (dimensionless) via symmetric finite differences.

`convexity = (V_up + V_dn − 2 V0) / (shift² V0)`. On a cc curve this is
the second derivative of log(V) w.r.t. the rate.
"""
function convexity(p::AbstractPortfolio, curve::ZeroCurve;
                   shift::Float64 = 1e-4, day_count::Float64 = day_count("ACT_365"))::Float64
    v0 = market_value(p, curve; day_count=day_count)
    v_up = market_value(p, parallel_shifted_curve(curve, shift); day_count=day_count)
    v_dn = market_value(p, parallel_shifted_curve(curve, -shift); day_count=day_count)
    return (v_up + v_dn - 2.0 * v0) / (shift^2 * v0)
end

"""
Key-rate durations: sensitivity of the portfolio value to a 1bp parallel
shift in each node of the curve, measured in currency per bp.

`krd[i] = (V(curve with node i shifted +1bp) − V0) / 1.0`, so the returned
numbers are already in dollars per bp of the shifted node. Positive KRD
means value rises when that node's zero rate rises (e.g. a long position at
longer tenors on a steep curve).
"""
function key_rate_durations(p::AbstractPortfolio, curve::ZeroCurve;
                            day_count::Float64 = day_count("ACT_365"))::Vector{Float64}
    v0 = market_value(p, curve; day_count=day_count)
    krd = Float64[]
    for i in 1:length(curve.nodes)
        vp = market_value(p, shifted_curve(curve, i, 1e-4); day_count=day_count)
        push!(krd, (vp - v0) / 1e-4)
    end
    return krd
end

# ---------------------------------------------------------------------------
# Yield and baseline return
# ---------------------------------------------------------------------------

"""
The (continuously compounded) yield of the portfolio: the rate `y` that
discounts the portfolio's cash flows to its market value.

Solved via bisection on `y ∈ [−0.5, 5.0]`. Only well-defined for portfolios
with a unique, economically meaningful yield (e.g. bond-like cash flows);
for generic instruments with signed cash flows the function may throw or
return an uninterpretable value.
"""
function portfolio_yield(p::AbstractPortfolio, curve::ZeroCurve;
               day_count::Float64 = day_count("ACT_365"))::Float64
    v0 = market_value(p, curve; day_count=day_count)
    flows = cash_flows(p)

    function pv(y)
        s = 0.0
        for (date, amount) in flows
            t = tenor(curve, date; day_count=day_count)
            s += amount * exp(-y * t)
        end
        return s
    end

    lo, hi = -0.5, 5.0
    f_lo, f_hi = pv(lo) - v0, pv(hi) - v0
    @assert f_lo > 0.0 && f_hi < 0.0 "No unique yield found on [-0.5, 5.0] (f_lo=$(f_lo), f_hi=$(f_hi), v0=$(v0))"

    for _ in 1:100
        mid = (lo + hi) / 2.0
        f = pv(mid) - v0
        if f > 0.0
            lo = mid
        else
            hi = mid
        end
    end
    return (lo + hi) / 2.0
end

"""
The baseline (curve-consistent) return over the horizon `[valuation_date,
horizon]`, assuming the curve stays fixed and all cash flows received before
the horizon are reinvested at the curve's implied forward rates.

For a portfolio whose cash flows are deterministic and valued on a single
curve, this reduces to `1 / DF(horizon) − 1` (the risk-free return over the
horizon). The explicit cash-flow summation is kept so the function remains
valid for instruments whose cash flows are stochastic or curve-dependent at
a future date.
"""
function expected_return(p::AbstractPortfolio, curve::ZeroCurve, horizon::Date;
                         day_count::Float64 = day_count("ACT_365"))::Float64
    v0 = market_value(p, curve; day_count=day_count)
    df_h = curve_discount_factor(curve, horizon; day_count=day_count)
    v_h = 0.0
    for (date, amount) in cash_flows(p)
        df_d = curve_discount_factor(curve, date; day_count=day_count)
        v_h += amount * df_d / df_h
    end
    return v_h / v0 - 1.0
end

# ---------------------------------------------------------------------------
# Scenarios: a portfolio pinned to a valuation curve and (optionally) a
# projected curve, so that different curve assumptions for the same holdings
# can be stored, saved, and compared.
# ---------------------------------------------------------------------------

"""
A named valuation scenario: one portfolio, one valuation curve, and an
optional *projected* curve.

The valuation curve is the curve the portfolio is worth against **today**
(it anchors all spot metrics: value, yield, duration, convexity, KRDs). The
projected curve is the curve expected to hold at the horizon; it drives the
forward-looking `scenario_return`. When no projected curve is given, the
valuation curve is used for the return as well (the curve-consistent
risk-free return over the horizon).

The scenario holds a reference to the `Portfolio`, so holdings added to the
portfolio after construction are reflected in later valuations.
"""
struct PortfolioScenario
    name::String
    portfolio::Portfolio
    valuation_curve::ZeroCurve
    projected_curve::Union{ZeroCurve, Nothing}
    horizon::Date

    function PortfolioScenario(name::String,
                               portfolio::Portfolio,
                               valuation_curve::ZeroCurve,
                               projected_curve::Union{ZeroCurve, Nothing} = nothing;
                               horizon::Date = Date(today()))
        @assert horizon >= portfolio.valuation_date "Horizon must be on or after the portfolio's valuation date"
        return new(name, portfolio, valuation_curve, projected_curve, horizon)
    end
end

"""The portfolio held by the scenario."""
portfolio(s::PortfolioScenario)::Portfolio = s.portfolio

"""The curve the portfolio is valued against today."""
valuation_curve(s::PortfolioScenario)::ZeroCurve = s.valuation_curve

"""The projected curve at the horizon, or `nothing` if not set."""
projected_curve(s::PortfolioScenario)::Union{ZeroCurve, Nothing} = s.projected_curve

"""The horizon date of the scenario."""
scenario_horizon(s::PortfolioScenario)::Date = s.horizon

"""
The curve used for the scenario's forward-looking return: the projected
curve when set, otherwise the valuation curve.
"""
function forward_curve(s::PortfolioScenario)::ZeroCurve
    return s.projected_curve !== nothing ? s.projected_curve : s.valuation_curve
end

"""
Market value of the scenario's portfolio on its valuation curve.
"""
function scenario_value(s::PortfolioScenario; day_count::Float64 = day_count("ACT_365"))::Float64
    return market_value(s.portfolio, s.valuation_curve; day_count=day_count)
end

"""
Portfolio yield on the scenario's valuation curve.
"""
function scenario_yield(s::PortfolioScenario; day_count::Float64 = day_count("ACT_365"))::Float64
    return portfolio_yield(s.portfolio, s.valuation_curve; day_count=day_count)
end

"""
Portfolio duration on the scenario's valuation curve (see `duration`).
"""
function scenario_duration(s::PortfolioScenario; shift::Float64 = 1e-4, day_count::Float64 = day_count("ACT_365"))::Float64
    return duration(s.portfolio, s.valuation_curve; shift=shift, day_count=day_count)
end

"""
Portfolio convexity on the scenario's valuation curve (see `convexity`).
"""
function scenario_convexity(s::PortfolioScenario; shift::Float64 = 1e-4, day_count::Float64 = day_count("ACT_365"))::Float64
    return convexity(s.portfolio, s.valuation_curve; shift=shift, day_count=day_count)
end

"""
Key-rate durations on the scenario's valuation curve (see `key_rate_durations`).
"""
function scenario_key_rate_durations(s::PortfolioScenario; day_count::Float64 = day_count("ACT_365"))::Vector{Float64}
    return key_rate_durations(s.portfolio, s.valuation_curve; day_count=day_count)
end

"""
Baseline return over the scenario's horizon, valued on the scenario's
`forward_curve` (projected curve if set, else valuation curve).

This is the number that differs between scenarios that share the same
portfolio but use different projected curves.
"""
function scenario_return(s::PortfolioScenario; day_count::Float64 = day_count("ACT_365"))::Float64
    return expected_return(s.portfolio, forward_curve(s), s.horizon; day_count=day_count)
end

"""
All spot metrics plus the forward return of a scenario, as a `NamedTuple`.

The `krd` field is a vector with one entry per node of the valuation curve,
so the number of KRDs differs across scenarios with different curve shapes.
"""
function scenario_summary(s::PortfolioScenario;
                          day_count::Float64 = day_count("ACT_365"))::NamedTuple
    return (
        name = s.name,
        value = scenario_value(s; day_count=day_count),
        yield = scenario_yield(s; day_count=day_count),
        duration = scenario_duration(s; day_count=day_count),
        convexity = scenario_convexity(s; day_count=day_count),
        krd = scenario_key_rate_durations(s; day_count=day_count),
        projected_return = scenario_return(s; day_count=day_count),
    )
end

# ---------------------------------------------------------------------------
# Scenario persistence (stdlib Serialization — no new dependencies)
# ---------------------------------------------------------------------------

"""
Save a scenario to `path` using Julia's stdlib `Serialization` format.

The file is a binary Julia image; load it back with `load_scenario`.
Only load files you trust, as deserializing evaluates the stored module
references. Note `Serialization.serialize`/`deserialize` (used here) write a
format that is not guaranteed to be readable by future major Julia versions.
"""
function save_scenario(path::AbstractString, s::PortfolioScenario)::Nothing
    Serialization.serialize(path, s)
    return nothing
end

"""
Load a scenario previously saved with `save_scenario`.
"""
function load_scenario(path::AbstractString)::PortfolioScenario
    s = Serialization.deserialize(path)
    @assert s isa PortfolioScenario "$path does not contain a PortfolioScenario (got $(typeof(s)))"
    return s
end

# ---------------------------------------------------------------------------
# Scenario comparison
# ---------------------------------------------------------------------------

const _SCENARIO_METRIC_KEYS = (:value, :yield, :duration, :convexity, :projected_return)

"""
Metric matrix for a set of scenarios: rows are
`(:value, :yield, :duration, :convexity, :projected_return)`, columns are
the scenarios in the given order. KRDs are excluded because their length
depends on the curve's node count.

Useful for comparing the same portfolio under different curve assumptions:
scenarios with identical holdings but different valuation/projected curves.
"""
function compare_scenarios(ss::AbstractVector{PortfolioScenario};
                           day_count::Float64 = day_count("ACT_365"))::Matrix{Float64}
    @assert !isempty(ss) "No scenarios to compare"
    m = Matrix{Float64}(undef, length(_SCENARIO_METRIC_KEYS), length(ss))
    for (j, s) in enumerate(ss)
        summary = scenario_summary(s; day_count=day_count)
        for (i, key) in enumerate(_SCENARIO_METRIC_KEYS)
            m[i, j] = getproperty(summary, key)
        end
    end
    return m
end

"""
A printable comparison table for a set of scenarios.

Rows: value, yield, duration, convexity, projected return (and one row per
KRD node, aligned when all scenarios share the same node dates). Columns:
the scenario names.
"""
function scenario_table(ss::AbstractVector{PortfolioScenario};
                        day_count::Float64 = day_count("ACT_365"))::String
    @assert !isempty(ss) "No scenarios to compare"

    summaries = [scenario_summary(s; day_count=day_count) for s in ss]
    names = [summ.name for summ in summaries]

    # Align KRD rows only when every scenario's valuation curve has the
    # same node dates.
    same_nodes = all(j -> ss[j].valuation_curve.nodes == ss[1].valuation_curve.nodes, 2:length(ss))

    header = lpad("Metric", 18)
    for n in names
        header *= "  " * rpad(n, 14)
    end
    sep = "-" ^ length(header)

    rows = String[]
    push!(rows, header, sep)

    for (i, key) in enumerate(_SCENARIO_METRIC_KEYS)
        line = lpad(string(key), 18)
        for summ in summaries
            line *= "  " * rpad("$(round(getproperty(summ, key), digits=6))", 14)
        end
        push!(rows, line)
    end

    if same_nodes
        push!(rows, "-" ^ length(header))
        for k in 1:length(ss[1].valuation_curve.nodes)
            line = lpad("krd node $k", 18)
            for summ in summaries
                line *= "  " * rpad("$(round(summ.krd[k], digits=4))", 14)
            end
            push!(rows, line)
        end
    end

    return join(rows, "\n")
end

end # module PortfolioMgr
