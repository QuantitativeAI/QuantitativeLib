#!/usr/bin/env julia
# demo/monte_carlo_pricing_demo.jl
#
# This script demonstrates the integration of Monte Carlo option pricing
# into the QuantitativeLib module.

using QuantitativeLib
using QuantitativeLib.Instruments: Option
using Dates

println("="^60)
println("Monte Carlo Option Pricing Demo")
println("="^60)

# Create an Option instrument
option = Option(
    100.0,  # underlying_price
    100.0,  # strike_price
    Date(2027, 1, 1),  # expiry_date
    0.2,    # volatility
    0.05,   # risk_free_rate
    0.0     # dividend_yield
)

println("\nOption Parameters:")
println("  Underlying Price: $(option.underlying_price)")
println("  Strike Price:     $(option.strike_price)")
println("  Expiry Date:      $(option.expiry_date)")
println("  Volatility:       $(option.volatility)")
println("  Risk-Free Rate:   $(option.risk_free_rate)")
println("  Dividend Yield:   $(option.dividend_yield)")

# Calculate time to maturity in trading days
days_to_maturity = (option.expiry_date - Date(2026, 9, 4)).value
trading_days = Int(floor(days_to_maturity * 252 / 365))

println("\nTime to Maturity:")
println("  Calendar Days:    $days_to_maturity")
println("  Trading Days:     $trading_days")

# Simulate stock prices
num_simulations = 10000
println("\nSimulating $num_simulations paths...")

prices = QuantitativeLib.colwise_simulate_stock_prices(
    option.underlying_price,
    option.risk_free_rate,  # using risk-free rate as drift for simplicity
    option.volatility,
    trading_days,
    num_simulations
)

println("  Simulated prices shape: $(size(prices))")
println("  Initial price: $(prices[1, 1])")
println("  Final prices (first 5): $(prices[1:5, end])")

# Price the option using broadcasting (faster)
println("\nPricing with broadcasting...")
option_price_bc = QuantitativeLib.priceCallOptionBroadcasted(
    prices,
    option.risk_free_rate,
    trading_days / 252.0,
    option.strike_price
)

println("  Monte Carlo Price: $(option_price_bc)")

# Price the option using threading
println("\nPricing with threading...")
option_price_threaded = QuantitativeLib.priceCallOption(
    prices,
    option.risk_free_rate,
    trading_days / 252.0,
    option.strike_price
)

println("  Monte Carlo Price: $(option_price_threaded)")

# Compare results
println("\n$("="^60)")
println("Results Summary:")
println("  Broadcasted Price: $(option_price_bc)")
println("  Threaded Price:    $(option_price_threaded)")
println("  Difference:        $(abs(option_price_bc - option_price_threaded))")
println("="^60)

# Test with different parameters
println("\n$("="^60)")
println("Testing with different parameters...")
println("="^60)

option2 = Option(
    150.0,  # underlying_price
    140.0,  # strike_price (in-the-money)
    Date(2027, 6, 1),  # expiry_date
    0.3,    # volatility
    0.04,   # risk_free_rate
    0.0     # dividend_yield
)

days2 = (option2.expiry_date - Date(2026, 9, 4)).value
trading_days2 = Int(floor(days2 * 252 / 365))

prices2 = QuantitativeLib.colwise_simulate_stock_prices(
    option2.underlying_price,
    option2.risk_free_rate,
    option2.volatility,
    trading_days2,
    10000
)

option_price2 = QuantitativeLib.priceCallOptionBroadcasted(
    prices2,
    option2.risk_free_rate,
    trading_days2 / 252.0,
    option2.strike_price
)

println("\nOption 2 (In-the-Money):")
println("  Monte Carlo Price: $(option_price2)")

println("\n$("="^60)")
println("Demo completed successfully!")
println("="^60)
