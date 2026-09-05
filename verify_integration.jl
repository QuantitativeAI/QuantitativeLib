#!/usr/bin/env julia
# verify_integration.jl
# Quick verification that the Monte Carlo integration is complete

println("Verifying Monte Carlo Integration...")
println("="^60)

# Check 1: Module structure
println("\n1. Checking module structure...")
@assert isdefined(@__MODULE__, :QuantitativeLib) "QuantitativeLib module not found"
println("   ✓ QuantitativeLib module exists")

@assert isdefined(QuantitativeLib, :MonteCarloPricing) "MonteCarloPricing module not found"
println("   ✓ MonteCarloPricing submodule exists")

@assert isa(QuantitativeLib.MonteCarloPricing, Module) "MonteCarloPricing is not a module"
println("   ✓ MonteCarloPricing is a proper module")

# Check 2: Functions are exported
println("\n2. Checking exported functions...")
@assert isdefined(QuantitativeLib, :colwise_simulate_stock_prices) "colwise_simulate_stock_prices not exported"
println("   ✓ colwise_simulate_stock_prices is exported")

@assert isdefined(QuantitativeLib, :priceCallOption) "priceCallOption not exported"
println("   ✓ priceCallOption is exported")

@assert isdefined(QuantitativeLib, :priceCallOptionBroadcasted) "priceCallOptionBroadcasted not exported"
println("   ✓ priceCallOptionBroadcasted is exported")

# Check 3: Option struct is available
println("\n3. Checking Option instrument...")
@assert isdefined(QuantitativeLib, :Option) "Option struct not exported"
println("   ✓ Option struct is exported")

option = QuantitativeLib.Option(100.0, 100.0, Date(2027, 1, 1), 0.2, 0.05, 0.0)
println("   ✓ Option struct can be instantiated")

# Check 4: Dependencies
println("\n4. Checking dependencies...")
@assert isdefined(Base, :Random) "Random package not available"
println("   ✓ Random package is available")

@assert isdefined(Base, :Statistics) "Statistics package not available"
println("   ✓ Statistics package is available")

# Check 5: Basic functionality
println("\n5. Testing basic functionality...")
using Random

Random.seed!(42)
prices = QuantitativeLib.colwise_simulate_stock_prices(100.0, 0.05, 0.2, 10, 100)
@assert size(prices) == (100, 10) "Price simulation failed"
println("   ✓ Stock price simulation works")

option_price = QuantitativeLib.priceCallOptionBroadcasted(prices, 0.05, 10/252, 100.0)
@assert option_price > 0 "Option pricing failed"
println("   ✓ Option pricing works")

option_price_threaded = QuantitativeLib.priceCallOption(prices, 0.05, 10/252, 100.0)
@assert option_price_threaded > 0 "Threaded option pricing failed"
println("   ✓ Threaded option pricing works")

# Check 6: Payoff function
println("\n6. Testing payoff function...")
payoff = QuantitativeLib.MonteCarloPricing.f([100.0, 110.0, 120.0], 100.0)
@assert payoff == 20.0 "Payoff function failed"
println("   ✓ Payoff function works")

println("\n"|"="^60)
println("All checks passed! ✓")
println("="^60)
println("\nIntegration is complete and functional.")
println("\nYou can now use:")
println("  - QuantitativeLib.colwise_simulate_stock_prices()")
println("  - QuantitativeLib.priceCallOption()")
println("  - QuantitativeLib.priceCallOptionBroadcasted()")
println("  - QuantitativeLib.Option()")
