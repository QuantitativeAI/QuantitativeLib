# Quick Start Guide - Monte Carlo Option Pricing

## ✓ Integration Complete

The Monte Carlo option pricing functionality has been successfully integrated into QuantitativeLib.

## Files Modified

### Core Integration
- **src/MonteCarloPricing.jl** - New module with MC pricing functions
- **src/QuantitativeLib.jl** - Added MonteCarloPricing module and exports
- **Project.toml** - Added Random and Statistics dependencies
- **Manifest.toml** - Updated dependency manifest

### Tests & Demo
- **test/montecarlo_test.jl** - Comprehensive test suite
- **test/runtests.jl** - Added MC tests
- **demo/monte_carlo_pricing_demo.jl** - Usage demo
- **test_simple.jl** - Simple verification script

## Usage Examples

### Basic Usage
```julia
using QuantitativeLib
using QuantitativeLib.Instruments: Option
using Dates

# Create an option
option = Option(
    100.0,  # underlying_price
    100.0,  # strike_price
    Date(2027, 1, 1),  # expiry_date
    0.2,    # volatility
    0.05,   # risk_free_rate
    0.0     # dividend_yield
)

# Calculate trading days
trading_days = Int(floor((option.expiry_date - Date(2026, 9, 4)).value * 252 / 365))

# Simulate and price
prices = QuantitativeLib.colwise_simulate_stock_prices(
    option.underlying_price,
    option.risk_free_rate,
    option.volatility,
    trading_days,
    10000  # num_simulations
)

# Price using broadcasting (faster)
price = QuantitativeLib.priceCallOptionBroadcasted(
    prices,
    option.risk_free_rate,
    trading_days / 252.0,
    option.strike_price
)

println("Option Price: $price")
```

### Using Threaded Version
```julia
price_threaded = QuantitativeLib.priceCallOption(
    prices,
    option.risk_free_rate,
    trading_days / 252.0,
    option.strike_price
)
```

## Running Tests

```bash
# Run all tests
cd /media/michael/Data/Source/Julia/QuantitativeLib
julia --project -e 'using Pkg; Pkg.test()'

# Run Monte Carlo tests only
julia --project -e 'using QuantitativeLib; include("test/montecarlo_test.jl")'

# Run simple verification
julia --project test_simple.jl
```

## Running Demo

```bash
julia --project demo/monte_carlo_pricing_demo.jl
```

## Available Functions

### Stock Price Simulation
```julia
colwise_simulate_stock_prices(
    initial_price::Float64,      # Starting stock price
    drift::Float64,              # Drift rate
    volatility::Float64,         # Volatility
    total_days::Int64,           # Number of trading days
    num_simulations::Int64       # Number of paths to simulate
) → AbstractArray{Float64, 2}   # Returns (num_simulations × total_days) array
```

### Option Pricing (Broadcasted)
```julia
priceCallOptionBroadcasted(
    stockPrices::AbstractArray{Float64, 2},  # Simulated prices
    r::Float64,                              # Risk-free rate
    TT::Float64,                             # Time to maturity (years)
    strike::Float64                          # Strike price
) → Float64                                 # Option price
```

### Option Pricing (Threaded)
```julia
priceCallOption(
    stockPrices::AbstractArray{Float64, 2},  # Simulated prices
    r::Float64,                              # Risk-free rate
    T::Float64,                              # Time to maturity (years)
    strike::Float64                          # Strike price
) → Float64                                 # Option price
```

## Key Features

✓ **Original Code Preserved** - No changes to Monte Carlo logic
✓ **Module Integration** - Properly integrated into QuantitativeLib
✓ **Dependencies** - Uses only Julia base packages (Random, Statistics)
✓ **Testing** - Comprehensive test coverage
✓ **Documentation** - Demo script and examples provided
✓ **Type Safety** - Uses Float64 for consistency

## Troubleshooting

### If you get "Option not defined" error:
Make sure to import Option explicitly:
```julia
using QuantitativeLib.Instruments: Option
```

### If you get "Random not found" error:
Make sure you've run Pkg.instantiate():
```julia
using Pkg
Pkg.instantiate()
```

### If tests fail:
Run from the project root:
```bash
julia --project -e 'using Pkg; Pkg.test()'
```

## Next Steps

1. Run the demo to see it in action
2. Run the tests to verify everything works
3. Use the functions in your own code
4. Adjust parameters (volatility, drift, simulations) as needed

---

**Status: ✓ READY TO USE**
All integration work is complete and verified.
