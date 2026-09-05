# src/MonteCarloPricing.jl

module MonteCarloPricing

using Dates
using Random
using Statistics

using ..Instruments: Option

export colwise_simulate_stock_prices, priceCallOption, priceCallOptionBroadcasted

"""
Constants
"""
const TRADING_DAYS_PER_YEAR = 252

"""
Simulate stock prices using Geometric Brownian Motion (GBM).

# Arguments:
- `initial_price::Float64`: The initial stock price.
- `drift::Float64`: The drift rate of the stock.
- `volatility::Float64`: The volatility of the stock.
- `total_days::Int64`: The total number of trading days.
- `num_simulations::Int64`: The number of simulations to run.

# Returns:
- `AbstractArray{Float64, 2}`: A 2D array of simulated stock prices.
"""
function colwise_simulate_stock_prices(
    initial_price::Float64,
    drift::Float64,
    volatility::Float64,
    total_days::Int64,
    num_simulations::Int64
)::AbstractArray{Float64, 2}

    Random.seed!()
    dt = 1 / TRADING_DAYS_PER_YEAR
    prices = zeros(Float64, num_simulations, total_days)
    prices[:, 1] .= initial_price

    drift_term_multiplier = (drift - 0.5 * volatility^2) * dt
    volatility_term_multiplier = volatility * sqrt(dt)

    for col in 1:num_simulations
        for row in 2:total_days
            epsilon = randn()
            prices[col, row] = prices[col, row-1] * exp(drift_term_multiplier + volatility_term_multiplier * epsilon)
        end
    end
    return prices
end

"""
Compute call option payoff using European-style pricing.

# Arguments:
- `col::AbstractArray{Float64}`: A column of simulated stock prices.
- `strike::Float64`: The strike price of the option.

# Returns:
- `Float64`: The payoff of the call option.
"""
function f(col::AbstractArray{Float64}, strike::Float64)::Float64
    return col[end] > strike ? col[end] - strike : 0.0
end

"""
Price call option with broadcasting.

# Arguments:
- `stockPrices::AbstractArray{Float64, 2}`: A 2D array of simulated stock prices.
- `r::Float64`: The risk-free interest rate.
- `TT::Float64`: The time to maturity in years.
- `strike::Float64`: The strike price of the option.

# Returns:
- `Float64`: The price of the call option.
"""
function priceCallOptionBroadcasted(stockPrices::AbstractArray{Float64, 2}, r::Float64, TT::Float64, strike::Float64)::Float64
    fac = exp(-r * TT)
    payoff = f.(eachcol(stockPrices), Ref(strike))
    return fac * mean(payoff)
end

"""
Price call option with manual threading (for comparison).

# Arguments:
- `stockPrices::AbstractArray{Float64, 2}`: A 2D array of simulated stock prices.
- `r::Float64`: The risk-free interest rate.
- `T::Float64`: The time to maturity in years.
- `strike::Float64`: The strike price of the option.

# Returns:
- `Float64`: The price of the call option.
"""
function priceCallOption(stockPrices::AbstractArray{Float64, 2}, r::Float64, T::Float64, strike::Float64)::Float64
    fac = exp(-r * T)
    payoff = zeros(size(stockPrices, 2))
    Threads.@threads for col in eachcol(stockPrices)
        payoff[Threads.threadid()] = f(col, strike)
    end
    return fac * mean(payoff)
end

end # module MonteCarloPricing
