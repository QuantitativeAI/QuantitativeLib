using Dates
using Test
using QuantitativeLib
using QuantitativeLib.SwapPricing: Swap, SwapLeg, Payment, StandardSwapPricer
using QuantitativeLib.Curves: bootstrap_zero_curve, BondQuote

@testset "Portfolio module" begin

    issue = Date(2026, 1, 1)

    # Build a simple 3-node curve for testing.
    curve = QuantitativeLib.ZeroCurve(issue, [
        (Date(2027, 1, 1), 0.02),
        (Date(2028, 1, 1), 0.03),
        (Date(2029, 1, 1), 0.035),
    ])

    # -----------------------------------------------------------------------
    # Zero-coupon bond
    # -----------------------------------------------------------------------
    zcb = QuantitativeLib.ZeroCouponBond(issue, Date(2028, 1, 1), 100.0)
    v_zcb = QuantitativeLib.market_value(zcb, curve)
    expected_zcb = 100.0 * QuantitativeLib.discount_factor(curve, Date(2028, 1, 1))
    @test v_zcb ≈ expected_zcb

    # -----------------------------------------------------------------------
    # Coupon bond
    # -----------------------------------------------------------------------
    cal = QuantitativeLib.InstrumentCalendar([Date(2026, 7, 1), Date(2027, 1, 1)])
    cb = QuantitativeLib.CouponBond(issue, cal, 0.04, 100.0)
    QuantitativeLib.generate_coupons!(cb)

    v_cb = QuantitativeLib.market_value(cb, curve)
    expected_cb = sum(amount * QuantitativeLib.discount_factor(curve, date)
                      for (date, amount) in QuantitativeLib.cash_flows(cb))
    @test v_cb ≈ expected_cb

    # -----------------------------------------------------------------------
    # Portfolio of bonds
    # -----------------------------------------------------------------------
    p = QuantitativeLib.Portfolio("BondPortfolio"; valuation_date=issue)
    QuantitativeLib.add_instrument!(p, zcb, 2.0)
    QuantitativeLib.add_instrument!(p, cb, 1.0)

    v_p = QuantitativeLib.market_value(p, curve)
    @test v_p ≈ 2.0 * v_zcb + 1.0 * v_cb

    # -----------------------------------------------------------------------
    # Nested portfolio
    # -----------------------------------------------------------------------
    inner = QuantitativeLib.Portfolio("Inner"; valuation_date=issue)
    QuantitativeLib.add_instrument!(inner, zcb, 1.0)
    outer = QuantitativeLib.Portfolio("Outer"; valuation_date=issue)
    QuantitativeLib.add_instrument!(outer, inner, 3.0)
    QuantitativeLib.add_instrument!(outer, cb, 1.0)

    v_outer = QuantitativeLib.market_value(outer, curve)
    @test v_outer ≈ 3.0 * v_zcb + 1.0 * v_cb

    # -----------------------------------------------------------------------
    # Short position
    # -----------------------------------------------------------------------
    p_short = QuantitativeLib.Portfolio("Short"; valuation_date=issue)
    QuantitativeLib.add_instrument!(p_short, zcb, -1.0)
    @test QuantitativeLib.market_value(p_short, curve) ≈ -v_zcb

    # -----------------------------------------------------------------------
    # add / remove
    # -----------------------------------------------------------------------
    p2 = QuantitativeLib.Portfolio("Ops"; valuation_date=issue)
    QuantitativeLib.add_instrument!(p2, zcb, 1.0, "ZCB")
    QuantitativeLib.add_instrument!(p2, cb, 1.0, "CB")
    @test length(QuantitativeLib.holdings(p2)) == 2

    QuantitativeLib.remove_instrument!(p2, zcb)
    @test length(QuantitativeLib.holdings(p2)) == 1
    @test QuantitativeLib.holdings(p2)[1].name == "CB"

    # Remove by name
    QuantitativeLib.remove_instrument!(p2, zcb; name="CB")
    @test length(QuantitativeLib.holdings(p2)) == 0

    # -----------------------------------------------------------------------
    # Duration & convexity (analytical vs numerical match for pure bonds)
    # -----------------------------------------------------------------------
    dur_num = QuantitativeLib.duration(p, curve)
    dur_ana = QuantitativeLib.macaulay_duration(p, curve)
    @test dur_num ≈ dur_ana atol=1e-6

    # Convexity > 0 for long bond positions
    @test QuantitativeLib.convexity(p, curve) > 0.0

    # -----------------------------------------------------------------------
    # Key-rate durations
    # -----------------------------------------------------------------------
    krd = QuantitativeLib.key_rate_durations(p, curve)
    @test length(krd) == 3
    # KRD is non-zero at nodes that have cash flows affecting the portfolio.
    # Node 3 has no cash flows in this portfolio, so its KRD is 0.
    @test krd[1] < 0.0  # short-rate rise devalues the portfolio
    @test krd[2] < 0.0  # mid-rate rise devalues the portfolio
    @test krd[3] == 0.0  # no cash flows beyond node 2

    # -----------------------------------------------------------------------
    # Yield (bond portfolio)
    # -----------------------------------------------------------------------
    y = QuantitativeLib.portfolio_yield(p, curve)
    # Re-price the portfolio at the recovered yield using the curve's tenors.
    flows = QuantitativeLib.cash_flows(p)
    pv_at_yield = sum(amount * exp(-y * QuantitativeLib.tenor(curve, date))
                      for (date, amount) in flows)
    @test pv_at_yield ≈ v_p atol=1e-8

    # -----------------------------------------------------------------------
    # Expected return (curve-consistent)
    # -----------------------------------------------------------------------
    horizon = Date(2027, 1, 1)
    ret = QuantitativeLib.expected_return(p, curve, horizon)
    # For deterministic cash flows on a single curve, return = 1/DF(horizon) − 1.
    expected_ret = 1.0 / QuantitativeLib.discount_factor(curve, horizon) - 1.0
    @test ret ≈ expected_ret atol=1e-10

    # -----------------------------------------------------------------------
    # Swap valuation
    # -----------------------------------------------------------------------
    using QuantitativeLib.SwapPricing
    notional = 1_000_000.0
    fixed_rate = 0.02
    float_rate = 0.02
    swap_start = issue
    swap_end = Date(2028, 1, 1)

    fixed_payments = Payment[
        Payment(Date(2027, 1, 1), notional, fixed_rate, swap_start, Date(2027, 1, 1), "ACTUAL_ACTUAL"),
        Payment(Date(2028, 1, 1), notional, fixed_rate, Date(2027, 1, 1), swap_end, "ACTUAL_ACTUAL"),
    ]
    floating_payments = Payment[]
    prev = swap_start
    for pmt in fixed_payments
        push!(floating_payments, Payment(pmt.date, notional, float_rate, prev, pmt.date, pmt.convention))
        prev = pmt.date
    end

    fixed_leg = SwapLeg(fixed_payments, "ACTUAL_ACTUAL")
    float_leg = SwapLeg(floating_payments, "ACTUAL_ACTUAL")
    swap = Swap(fixed_leg, float_leg, swap_start, swap_end, notional, 0.0)

    # Par swap (fixed = floating) should be close to zero value.
    swap_pv = QuantitativeLib.market_value(swap, curve)
    @test swap_pv ≈ 0.0 atol=1e-6

    # Swap inside a portfolio
    p_swap = QuantitativeLib.Portfolio("WithSwap"; valuation_date=issue)
    QuantitativeLib.add_instrument!(p_swap, zcb, 10.0)
    QuantitativeLib.add_instrument!(p_swap, swap, 1.0)
    @test QuantitativeLib.market_value(p_swap, curve) ≈ 10.0 * v_zcb

    # -----------------------------------------------------------------------
    # Curve shift helpers
    # -----------------------------------------------------------------------
    shifted = QuantitativeLib.shifted_curve(curve, 2, 0.001)
    @test shifted.nodes[2][2] == curve.nodes[2][2] + 0.001
    @test shifted.nodes[1][2] == curve.nodes[1][2]
    @test shifted.nodes[3][2] == curve.nodes[3][2]

    parallel = QuantitativeLib.parallel_shifted_curve(curve, -0.0005)
    @test all(n[2] == c[2] - 0.0005 for (c, n) in zip(curve.nodes, parallel.nodes))

    # -----------------------------------------------------------------------
    # Fallback error for unknown instrument type
    # -----------------------------------------------------------------------
    opt = QuantitativeLib.Option(100.0, 100.0, Date(2027, 1, 1), 0.2, 0.03, 0.0)
    @test_throws ErrorException QuantitativeLib.market_value(opt, curve)

    # -----------------------------------------------------------------------
    # Scenarios: same portfolio, different (projected) curves
    # -----------------------------------------------------------------------
    proj_curve = QuantitativeLib.parallel_shifted_curve(curve, 0.01)

    sc_no_proj = QuantitativeLib.PortfolioScenario("Flat", p, curve; horizon=horizon)
    sc_proj = QuantitativeLib.PortfolioScenario("Steepened", p, curve, proj_curve; horizon=horizon)

    # Accessors
    @test QuantitativeLib.portfolio(sc_proj) === p
    @test QuantitativeLib.valuation_curve(sc_proj) === curve
    @test QuantitativeLib.projected_curve(sc_proj) === proj_curve
    @test QuantitativeLib.projected_curve(sc_no_proj) === nothing
    @test QuantitativeLib.scenario_horizon(sc_proj) == horizon
    @test QuantitativeLib.forward_curve(sc_proj) === proj_curve
    @test QuantitativeLib.forward_curve(sc_no_proj) === curve

    # Spot metrics match the standalone functions on the valuation curve
    @test QuantitativeLib.scenario_value(sc_proj) ≈ v_p
    @test QuantitativeLib.scenario_yield(sc_proj) ≈ y
    @test QuantitativeLib.scenario_duration(sc_proj) ≈ dur_num
    @test QuantitativeLib.scenario_convexity(sc_proj) ≈ QuantitativeLib.convexity(p, curve)
    @test QuantitativeLib.scenario_key_rate_durations(sc_proj) ≈ krd

    # Projected return: with no projected curve this is the curve-consistent
    # return on the valuation curve; with a projected curve it is driven by
    # the projected curve, and a steeper (higher) curve gives a higher return.
    @test QuantitativeLib.scenario_return(sc_no_proj) ≈ ret
    expected_proj_ret = 1.0 / QuantitativeLib.discount_factor(proj_curve, horizon) - 1.0
    @test QuantitativeLib.scenario_return(sc_proj) ≈ expected_proj_ret
    @test QuantitativeLib.scenario_return(sc_proj) > QuantitativeLib.scenario_return(sc_no_proj)

    # Summary NamedTuple carries all fields
    summary = QuantitativeLib.scenario_summary(sc_proj)
    @test summary.name == "Steepened"
    @test summary.value ≈ v_p
    @test summary.projected_return ≈ expected_proj_ret
    @test length(summary.krd) == 3

    # Comparison matrix: rows = (value, yield, duration, convexity, return)
    m = QuantitativeLib.compare_scenarios([sc_no_proj, sc_proj])
    @test size(m) == (5, 2)
    @test m[1, 1] ≈ v_p
    @test m[5, 1] ≈ ret
    @test m[5, 2] ≈ expected_proj_ret

    # Printable table contains both scenario names and the metric rows
    table = QuantitativeLib.scenario_table([sc_no_proj, sc_proj])
    @test occursin("Flat", table)
    @test occursin("Steepened", table)
    @test occursin("projected_return", table)
    @test occursin("krd node 1", table)  # same node dates → KRD rows included

    # Save / load round trip
    path = tempname()
    QuantitativeLib.save_scenario(path, sc_proj)
    sc_loaded = QuantitativeLib.load_scenario(path)
    rm(path)
    @test sc_loaded.name == "Steepened"
    @test sc_loaded.horizon == horizon
    @test sc_loaded.valuation_curve.nodes == curve.nodes
    @test sc_loaded.projected_curve !== nothing
    @test sc_loaded.projected_curve.nodes == proj_curve.nodes
    @test QuantitativeLib.scenario_return(sc_loaded) ≈ QuantitativeLib.scenario_return(sc_proj)

    # Horizon before the valuation date is rejected
    @test_throws AssertionError QuantitativeLib.PortfolioScenario(
        "Bad", p, curve; horizon=Date(2025, 1, 1))
end
