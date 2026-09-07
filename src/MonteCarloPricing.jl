# src/MonteCarloPricing.jl

module MonteCarloPricing

using Dates
using Random
using Statistics

using ..Instruments: Option
using ..SystemConfig: trading_days_year

export colwise_simulate_stock_prices, priceCallOption, priceCallOptionBroadcasted

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

    #Random.seed!()
    random_rng = Xoshiro()
    dt = 1.0 / trading_days_year()
    prices = zeros(Float64, num_simulations, total_days)
    prices[:, 1] .= initial_price

    drift_term_multiplier = (drift - 0.5 * volatility^2) * dt
    volatility_term_multiplier = volatility * sqrt(dt)

    for col in 1:num_simulations
        for row in 2:total_days
            epsilon = rand(random_rng) # randn()
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
    n = size(stockPrices, 2)
    nt = Threads.nthreads()
    # Give each thread a contiguous block of columns to avoid any shared writes.
    chunk = div(n, nt)
    remainder = mod(n, nt)
    thread_payoffs = Vector{Float64}(undef, nt)
    Threads.@threads for tid in 1:nt
        start_col = (tid - 1) * chunk + min(tid, remainder) + 1
        end_col = tid * chunk + min(tid, remainder)
        acc = 0.0
        for col in start_col:end_col
            acc += f(@view(stockPrices[:, col]), strike)
        end
        thread_payoffs[tid] = acc
    end
    return fac * sum(thread_payoffs) / n
end

end # module MonteCarloPricing
