# ─────────────────────────────────────────────
# Market Environment — The Top-Level Container
# ─────────────────────────────────────────────

using Dates
using Interpolations

# ─────────────────────────────────────────────
# Date & Rate Primitives
# ─────────────────────────────────────────────

struct MarketDate
    date::Date
    year_fraction::Float64   # time to maturity in years
end

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


struct MarketEnvironment
    # ── Core Metadata ──
    as_of::DateTime
    currency::String
    region::String
    source::String              # data vendor or source

    # ── Curves ──
    yield_curve::YieldCurve
    forward_curve::ForwardCurve
    discount_curve::DiscountCurve

    # ── Basis & Credit ──
    basis_curves::Dict{String, BasisCurve}       # e.g., "SOFR_OIS_Basis"
    credit_curves::Dict{String, CreditCurve}     # e.g., "AAPL_CreditCurve"

    # ── Volatility ──
    equity_vol_surface::VolSurface
    ir_vol_surface::VolSurface                  # interest rate vol (swaptions, caps)
    fx_vol_surface::Dict{String, VolSurface}    # keyed by FX pair, e.g., "EURUSD"

    # ── Index Rates ──
    index_rates::Dict{String, Float64}          # e.g., "SOFR" => 0.0525

    # ── Swap Rates ──
    swap_rates::Vector{Float64}
    swap_tenors::Vector{Int}                    # in years

    # ── Forward Rates ──
    forward_rates::Vector{Float64}
    forward_tenors::Vector{Int}

    # ── Spot Prices ──
    spot_prices::Dict{String, Float64}          # e.g., "AAPL" => 185.50
    fx_rates::Dict{String, Float64}             # e.g., "EURUSD" => 1.0850

    # ── Additional Metadata ──
    market_regime::Symbol                       # :risk_on, :risk_off, :neutral
    volatility_regime::Symbol                   # :low, :medium, :high
    calendar::String                            # trading calendar
end


# ─────────────────────────────────────────────
# Market Environment Update
# ─────────────────────────────────────────────

# Create a new MarketEnvironment with updated curves (immutable update pattern)
function update_market(env::MarketEnvironment;
                        new_yield_curve = env.yield_curve,
                        new_forward_curve = env.forward_curve,
                        new_as_of = env.as_of)

    return MarketEnvironment(
        new_as_of, env.currency, env.region, env.source,
        new_yield_curve, new_forward_curve, env.discount_curve,
        env.basis_curves, env.credit_curves,
        env.equity_vol_surface, env.ir_vol_surface, env.fx_vol_surface,
        env.index_rates, env.swap_rates, env.swap_tenors,
        env.forward_rates, env.forward_tenors,
        env.spot_prices, env.fx_rates,
        env.market_regime, env.volatility_regime, env.calendar
    )
end

end
