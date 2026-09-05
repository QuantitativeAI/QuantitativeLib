#!/usr/bin/env julia
# Simple test to verify Option is accessible

using QuantitativeLib
using Dates

println("Testing Option accessibility...")

# Test 1: Check if Option is defined
println("\n1. Checking if Option is defined...")
@assert isdefined(QuantitativeLib, :Option) "Option not defined in QuantitativeLib"
println("   ✓ Option is defined")

# Test 2: Create an Option
println("\n2. Creating an Option...")
try
    option = QuantitativeLib.Option(
        100.0,
        100.0,
        Date(2027, 1, 1),
        0.2,
        0.05,
        0.0
    )
    println("   ✓ Option created successfully")
    println("   ✓ Underlying price: $(option.underlying_price)")
    println("   ✓ Strike price: $(option.strike_price)")
catch e
    println("   ✗ Failed to create Option: $e")
    rethrow()
end

# Test 3: Test Monte Carlo functions
println("\n3. Testing Monte Carlo functions...")
using Random
Random.seed!(42)

prices = QuantitativeLib.colwise_simulate_stock_prices(100.0, 0.05, 0.2, 10, 100)
println("   ✓ Stock price simulation works")
println("   ✓ Prices shape: $(size(prices))")

option_price = QuantitativeLib.priceCallOptionBroadcasted(prices, 0.05, 10/252, 100.0)
println("   ✓ Option pricing works")
println("   ✓ Option price: $option_price")

println("\n"|"="^60)
println("All tests passed! ✓")
println("="^60)
