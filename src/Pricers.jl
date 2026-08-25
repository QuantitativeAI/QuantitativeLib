# src/QuantitativeLib/Pricers.jl
module Pricers

export Pricer, BlackScholesPricer, HullWhitePricer

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

end
