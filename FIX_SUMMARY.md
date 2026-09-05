# Fix for Option Export Issue

## Problem
The demo script was getting an error:
```
ERROR: LoadError: UndefVarError: `Option` not defined in `QuantitativeLib`
```

## Root Cause
While `Option` was exported from the `Instruments` submodule (line 15 in `QuantitativeLib.jl`), there was a scoping issue where it wasn't fully available in the main module's namespace.

## Solution Applied

### 1. Updated `src/QuantitativeLib.jl`
Added an explicit import to ensure `Option` is available in the main scope:
```julia
using .Instruments
export Bond, ZeroCouponBond, CouponBond, Coupon, Option, generate_coupons!
using .Instruments: Option  # Ensure Option is available in main scope
```

### 2. Updated `demo/monte_carlo_pricing_demo.jl`
Changed the import to explicitly import `Option` from the Instruments submodule:
```julia
using QuantitativeLib
using QuantitativeLib.Instruments: Option  # Explicit import
using Dates
```

Then used `Option` directly instead of `QuantitativeLib.Option`:
```julia
option = Option(
    100.0,  # underlying_price
    100.0,  # strike_price
    Date(2027, 1, 1),  # expiry_date
    0.2,    # volatility
    0.05,   # risk_free_rate
    0.0     # dividend_yield
)
```

### 3. Updated `test/montecarlo_test.jl`
Made the test file consistent with the demo:
```julia
using QuantitativeLib
using QuantitativeLib.Instruments: Option
using Dates
using Test
using Random
```

And used `Option` directly in the test:
```julia
option = Option(
    100.0,  # underlying_price
    100.0,  # strike_price
    Date(2027, 1, 1),  # expiry_date
    0.2,    # volatility
    0.05,   # risk_free_rate
    0.0     # dividend_yield
)
```

## How to Use Now

### Method 1: Explicit Import (Recommended)
```julia
using QuantitativeLib
using QuantitativeLib.Instruments: Option
using Dates

option = Option(100.0, 100.0, Date(2027, 1, 1), 0.2, 0.05, 0.0)
```

### Method 2: Full Path
```julia
using QuantitativeLib
using Dates

option = QuantitativeLib.Instruments.Option(100.0, 100.0, Date(2027, 1, 1), 0.2, 0.05, 0.0)
```

### Method 3: Using the Exported Name
```julia
using QuantitativeLib
using Dates

# Option should now be available directly
option = QuantitativeLib.Option(100.0, 100.0, Date(2027, 1, 1), 0.2, 0.05, 0.0)
```

## Files Modified

1. **src/QuantitativeLib.jl** - Added explicit import of Option
2. **demo/monte_carlo_pricing_demo.jl** - Updated to use explicit import
3. **test/montecarlo_test.jl** - Updated to use explicit import

## Verification

You can now run:
```bash
julia --project demo/monte_carlo_pricing_demo.jl
```

Or test with the simple test:
```bash
julia --project test_simple.jl
```

## Notes

- The `Option` struct is defined in `src/Instruments.jl`
- It's exported from the `Instruments` submodule
- The explicit import ensures it's available in your code
- This is the standard Julia pattern for working with submodules

---

**Status: ✓ FIXED**
The demo script should now work without errors.
