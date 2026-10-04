using QuantitativeLib
using Dates
using Test

@testset "QuantitativeLib.jl" begin
    @test isdefined(@__MODULE__, :QuantitativeLib)
    @test isa(QuantitativeLib, Module)
    @test nameof(QuantitativeLib) == :QuantitativeLib
end

@testset "BondPricer (zero-coupon)" begin
    bond = QuantitativeLib.ZeroCouponBond(Date(2024, 1, 1), Date(2026, 1, 1), 100.0)

    p = QuantitativeLib.BondPricer(bond, 0.05)

    @test p isa QuantitativeLib.Pricer
    @test QuantitativeLib.Pricers.start_date(p) == Date(2024, 1, 1)
    @test QuantitativeLib.Pricers.maturity_date(p) == Date(2026, 1, 1)

    days = (Date(2026, 1, 1) - Date(2024, 1, 1)).value
    expected = 100.0 * exp(-0.05 * days / 365.0)
    @test QuantitativeLib.price(p) ≈ expected

    # default face value is 100
    @test QuantitativeLib.ZeroCouponBond(Date(2024, 1, 1), Date(2026, 1, 1)).face_value == 100.0

    # a maturity before the issue date is rejected
    @test_throws AssertionError QuantitativeLib.ZeroCouponBond(Date(2026, 1, 1), Date(2024, 1, 1))
end

@testset "BondPricer (coupon bond)" begin
    # Calendar starting at the issue date (anchor) with semi-annual payments
    cal = QuantitativeLib.InstrumentCalendar([Date(2024, 1, 1)])
    for d in [Date(2024, 7, 1), Date(2025, 1, 1)]
        push!(cal.days, d)
    end

    bond = QuantitativeLib.CouponBond(Date(2024, 1, 1), cal, 0.05)
    QuantitativeLib.generate_coupons!(bond)

    # the issue-date anchor is not a payment; maturity is the last payment date
    @test bond.maturity == Date(2025, 1, 1)
    @test length(bond.coupons) == 2

    p = QuantitativeLib.BondPricer(bond, 0.05)

    @test p isa QuantitativeLib.Pricer

    d1 = (Date(2024, 7, 1) - Date(2024, 1, 1)).value
    d2 = (Date(2025, 1, 1) - Date(2024, 1, 1)).value
    expected = bond.coupons[1].amount * exp(-0.05 * d1 / 365.0) +
               bond.coupons[2].amount * exp(-0.05 * d2 / 365.0) +
               100.0 * exp(-0.05 * d2 / 365.0)
    @test QuantitativeLib.price(p) ≈ expected
end

@testset "BondPricer (coupon bond, schedule without anchor)" begin
    # Calendar listing payment dates only: the first entry is the first payment
    cal = QuantitativeLib.InstrumentCalendar([Date(2024, 7, 1)])
    for d in [Date(2025, 1, 1), Date(2025, 7, 1)]
        push!(cal.days, d)
    end

    bond = QuantitativeLib.CouponBond(Date(2024, 1, 1), cal, 0.05)
    QuantitativeLib.generate_coupons!(bond)

    @test bond.maturity == Date(2025, 7, 1)
    @test length(bond.coupons) == 3

    p = QuantitativeLib.BondPricer(bond, 0.05)

    expected = sum([c.amount * exp(-0.05 * (c.date - Date(2024, 1, 1)).value / 365.0) for c in bond.coupons]) +
               100.0 * exp(-0.05 * (Date(2025, 7, 1) - Date(2024, 1, 1)).value / 365.0)
    @test QuantitativeLib.price(p) ≈ expected
end

@testset "BondPricer (simple interest)" begin
    bond = QuantitativeLib.ZeroCouponBond(Date(2024, 1, 1), Date(2026, 1, 1), 100.0)
    p = QuantitativeLib.BondPricer(bond, 0.05, QuantitativeLib.SimpleInterest())

    days = (Date(2026, 1, 1) - Date(2024, 1, 1)).value
    expected = 100.0 / (1.0 + 0.05 * days / 365.0)
    @test QuantitativeLib.price(p) ≈ expected
end

@testset "add_periods" begin
    cal = QuantitativeLib.InstrumentCalendar([Date(2024, 1, 1)])
    
    # Add 3 periods starting from 2024-01-01 with 30-day spacing
    QuantitativeLib.add_periods(cal, Date(2024, 2, 1), 30, 3)
    
    @test length(cal.days) == 4
    @test cal.days[2] == Date(2024, 2, 1)
    @test cal.days[3] == Date(2024, 3, 2)
    @test cal.days[4] == Date(2024, 4, 1)
end

@testset "ZeroCurve (flat, single node)" begin
    issue = Date(2026, 1, 1)
    curve = QuantitativeLib.ZeroCurve(issue, [(issue, 0.05)])

    @test curve isa QuantitativeLib.InterestCurve
    @test QuantitativeLib.tenor(curve, Date(2027, 1, 1)) == 1.0
    @test QuantitativeLib.discount_factor(curve, issue) == 1.0
    @test QuantitativeLib.discount_factor(curve, Date(2027, 1, 1)) ≈ exp(-0.05)
    @test QuantitativeLib.zero_rate(curve, issue) == 0.05
    @test QuantitativeLib.zero_rate(curve, Date(2027, 1, 1)) ≈ 0.05

    # A flat continuous curve implies a simple forward slightly above the zero rate
    @test QuantitativeLib.forward_rate(curve, Date(2027, 1, 1), Date(2028, 1, 1)) ≈
          (exp(0.05) - 1.0) / 1.0

    # Law of one price: (1 + f*τ) * DF(end) = DF(start)
    f = QuantitativeLib.forward_rate(curve, Date(2026, 7, 1), Date(2027, 1, 1))
    τ = (Date(2027, 1, 1) - Date(2026, 7, 1)).value / 365.0
    @test (1.0 + f * τ) * QuantitativeLib.discount_factor(curve, Date(2027, 1, 1)) ≈
          QuantitativeLib.discount_factor(curve, Date(2026, 7, 1))
end

@testset "ZeroCurve (log-linear interpolation)" begin
    issue = Date(2026, 1, 1)
    curve = QuantitativeLib.ZeroCurve(issue,
        [(Date(2027, 1, 1), 0.02), (Date(2028, 1, 1), 0.03)])

    # Node dates are reproduced exactly
    @test QuantitativeLib.discount_factor(curve, Date(2027, 1, 1)) ≈ exp(-0.02 * 1.0)
    @test QuantitativeLib.discount_factor(curve, Date(2028, 1, 1)) ≈ exp(-0.03 * 2.0)
    @test QuantitativeLib.zero_rate(curve, Date(2027, 1, 1)) ≈ 0.02
    @test QuantitativeLib.zero_rate(curve, Date(2028, 1, 1)) ≈ 0.03

    # Mid-segment: the log of the discount factor is linear in tenor
    t_mid = QuantitativeLib.tenor(curve, Date(2027, 7, 1))
    w = (t_mid - 1.0) / (2.0 - 1.0)
    expected_lndf = (1.0 - w) * (-0.02) + w * (-0.06)
    @test QuantitativeLib.discount_factor(curve, Date(2027, 7, 1)) ≈ exp(expected_lndf)
    @test QuantitativeLib.zero_rate(curve, Date(2027, 7, 1)) ≈ -expected_lndf / t_mid

    # Within a segment the continuous forward is constant (0.04), so the simple
    # forward over any sub-period equals (exp(0.04*Δ) - 1)/Δ for that period's Δ
    d1 = (Date(2027, 10, 1) - Date(2027, 4, 1)).value / 365.0
    @test QuantitativeLib.forward_rate(curve, Date(2027, 4, 1), Date(2027, 10, 1)) ≈
          (exp(0.04 * d1) - 1.0) / d1
    d2 = (Date(2028, 1, 1) - Date(2027, 7, 1)).value / 365.0
    @test QuantitativeLib.forward_rate(curve, Date(2027, 7, 1), Date(2028, 1, 1)) ≈
          (exp(0.04 * d2) - 1.0) / d2

    # Flat extrapolation beyond the last node, at the last segment's forward
    # (note 2028 is a leap year, so 2029-01-01 is not exactly at tenor 3.0)
    t3 = (Date(2029, 1, 1) - issue).value / 365.0
    @test QuantitativeLib.discount_factor(curve, Date(2029, 1, 1)) ≈
          exp(-0.06 - 0.04 * (t3 - 2.0))

    # Flat extrapolation before the first node, at the first node's zero rate
    @test QuantitativeLib.discount_factor(curve, issue) == 1.0
    @test QuantitativeLib.discount_factor(curve, Date(2026, 7, 1)) ≈
          exp(-0.02 * (Date(2026, 7, 1) - issue).value / 365.0)
end

@testset "ZeroCurve (constructor)" begin
    issue = Date(2026, 1, 1)
    @test_throws AssertionError QuantitativeLib.ZeroCurve(issue, Tuple{Date,Float64}[])
    @test_throws AssertionError QuantitativeLib.ZeroCurve(issue,
        [(Date(2028, 1, 1), 0.03), (Date(2027, 1, 1), 0.02)])
    @test_throws AssertionError QuantitativeLib.ZeroCurve(Date(2027, 1, 1), [(issue, 0.02)])
end

@testset "ZeroCurve (consistent with BondPricer)" begin
    # A one-node flat curve must reproduce BondPricer's pricing exactly
    cal = QuantitativeLib.InstrumentCalendar([])
    QuantitativeLib.add_periods(cal, Date(2026, 9, 26), 360/2, 8)
    bond = QuantitativeLib.CouponBond(Date(2026, 8, 27), cal, 0.05, 100.0)
    QuantitativeLib.generate_coupons!(bond)

    r = 0.046
    p = QuantitativeLib.BondPricer(bond, r)
    curve = QuantitativeLib.ZeroCurve(bond.issue_date, [(bond.issue_date, r)])

    expected = sum([c.amount * QuantitativeLib.discount_factor(curve, c.date) for c in bond.coupons]) +
               bond.face_value * QuantitativeLib.discount_factor(curve, bond.maturity)
    @test QuantitativeLib.price(p) == expected
end

@testset "bootstrap_zero_curve (zero-coupon round trip)" begin
    issue = Date(2026, 1, 1)
    truth = QuantitativeLib.ZeroCurve(issue,
        [(issue, 0.02), (Date(2027, 1, 1), 0.03), (Date(2028, 1, 1), 0.035)])

    m1 = Date(2027, 1, 1)
    m2 = Date(2028, 1, 1)
    quotes = [
        QuantitativeLib.BondQuote(QuantitativeLib.ZeroCouponBond(issue, m1),
            100.0 * QuantitativeLib.discount_factor(truth, m1)),
        QuantitativeLib.BondQuote(QuantitativeLib.ZeroCouponBond(issue, m2),
            100.0 * QuantitativeLib.discount_factor(truth, m2)),
    ]

    curve = QuantitativeLib.bootstrap_zero_curve(issue, quotes)

    # Zero-coupon quotes pin their nodes exactly (up to ulp noise in exp/ln)
    @test length(curve.nodes) == 2
    @test curve.nodes[1][1] == m1
    @test curve.nodes[1][2] ≈ 0.03
    @test curve.nodes[2][1] == m2
    @test curve.nodes[2][2] ≈ 0.035

    # The bootstrapped curve reproduces every quote price
    for bq in quotes
        pv = sum([amount * QuantitativeLib.discount_factor(curve, date)
                  for (date, amount) in QuantitativeLib.cash_flows(bq.bond)])
        @test pv ≈ bq.price
    end
end

@testset "bootstrap_zero_curve (coupon bond)" begin
    issue = Date(2026, 1, 1)
    m1 = Date(2026, 7, 1)
    m2 = Date(2027, 1, 1)
    t1 = (m1 - issue).value / 365.0
    t2 = (m2 - issue).value / 365.0

    q1 = QuantitativeLib.BondQuote(QuantitativeLib.ZeroCouponBond(issue, m1),
        100.0 * exp(-0.04 * t1))

    cal = QuantitativeLib.InstrumentCalendar([m1, m2])
    cb = QuantitativeLib.CouponBond(issue, cal, 0.05, 100.0)
    QuantitativeLib.generate_coupons!(cb)

    # Price the quote bootstrap-consistently: the prior coupon at the first
    # node's flat rate (4%), the terminal payment at the zero rate we want
    # the bootstrap to recover (4.5%).
    prior = cb.coupons[1].amount * exp(-0.04 * t1)
    terminal = cb.coupons[2].amount + 100.0
    q2 = QuantitativeLib.BondQuote(cb, prior + terminal * exp(-0.045 * t2))

    curve = QuantitativeLib.bootstrap_zero_curve(issue, [q1, q2])

    @test length(curve.nodes) == 2
    @test curve.nodes[1][1] == m1
    @test curve.nodes[1][2] ≈ 0.04
    @test curve.nodes[2][1] == m2
    @test curve.nodes[2][2] ≈ 0.045

    for bq in [q1, q2]
        pv = sum([amount * QuantitativeLib.discount_factor(curve, date)
                  for (date, amount) in QuantitativeLib.cash_flows(bq.bond)])
        @test pv ≈ bq.price
    end
end

@testset "bootstrap_zero_curve (validation)" begin
    issue = Date(2026, 1, 1)
    m1 = Date(2027, 1, 1)
    q1 = QuantitativeLib.BondQuote(QuantitativeLib.ZeroCouponBond(issue, m1), 95.0)

    # No quotes
    @test_throws AssertionError QuantitativeLib.bootstrap_zero_curve(issue,
        QuantitativeLib.BondQuote[])

    # Duplicate maturity
    @test_throws AssertionError QuantitativeLib.bootstrap_zero_curve(issue, [q1, q1])

    # A cash flow before the valuation date
    old = QuantitativeLib.CouponBond(Date(2025, 6, 1),
        QuantitativeLib.InstrumentCalendar([Date(2025, 12, 1), Date(2027, 6, 1)]), 0.05)
    QuantitativeLib.generate_coupons!(old)
    @test_throws AssertionError QuantitativeLib.bootstrap_zero_curve(issue,
        [q1, QuantitativeLib.BondQuote(old, 90.0)])

    # Maturity on the valuation date
    @test_throws AssertionError QuantitativeLib.bootstrap_zero_curve(issue,
        [QuantitativeLib.BondQuote(QuantitativeLib.ZeroCouponBond(issue, issue), 100.0)])

    # First bond has a pre-maturity cash flow
    early = QuantitativeLib.CouponBond(issue,
        QuantitativeLib.InstrumentCalendar([Date(2026, 7, 1), m1]), 0.05)
    QuantitativeLib.generate_coupons!(early)
    @test_throws AssertionError QuantitativeLib.bootstrap_zero_curve(issue,
        [QuantitativeLib.BondQuote(early, 100.0)])

    # Price inconsistent with the prior cash flows (implied DF <= 0)
    short = QuantitativeLib.CouponBond(issue,
        QuantitativeLib.InstrumentCalendar([Date(2027, 3, 1), Date(2027, 6, 1)]), 0.05)
    QuantitativeLib.generate_coupons!(short)
    @test_throws AssertionError QuantitativeLib.bootstrap_zero_curve(issue,
        [q1, QuantitativeLib.BondQuote(short, 1.0)])
end

@testset "Nelson-Siegel curve" begin
    issue = Date(2026, 1, 1)
    beta = [0.03, 0.01, -0.02]
    tau = 2.0
    curve = QuantitativeLib.NelsonSiegelCurve(issue, beta, tau)

    @test curve isa QuantitativeLib.InterestCurve

    # Zero-rate formula reproduces hand-computed values
    @test QuantitativeLib.ns_zero_rate(1.0, beta, tau) ≈ 0.0342612 atol=1e-6
    @test QuantitativeLib.ns_zero_rate(5.0, beta, tau) ≈ 0.0279700 atol=1e-6

    # Limits: z(0) = β0 + β1, z(∞) → β0
    @test QuantitativeLib.ns_zero_rate(1e-8, beta, tau) ≈ 0.04
    @test QuantitativeLib.ns_zero_rate(100.0, beta, tau) ≈ 0.03 atol=1e-3

    # tenor / zero_rate / discount_factor via dates
    t1 = QuantitativeLib.tenor(curve, Date(2027, 1, 1))
    @test t1 ≈ 1.0
    @test QuantitativeLib.zero_rate(curve, Date(2027, 1, 1)) ≈ QuantitativeLib.ns_zero_rate(t1, beta, tau)
    @test QuantitativeLib.discount_factor(curve, issue) ≈ 1.0
    @test QuantitativeLib.discount_factor(curve, Date(2027, 1, 1)) ≈
          exp(-QuantitativeLib.zero_rate(curve, Date(2027, 1, 1)) * t1)

    # Forward rate satisfies the no-arbitrage identity
    ds, de = Date(2027, 3, 1), Date(2027, 9, 1)
    τ = (de - ds).value / 365.0
    f = QuantitativeLib.forward_rate(curve, ds, de)
    @test (1.0 + f * τ) * QuantitativeLib.discount_factor(curve, de) ≈
          QuantitativeLib.discount_factor(curve, ds)

    # Constructor validation
    @test_throws AssertionError QuantitativeLib.NelsonSiegelCurve(issue, [0.03, 0.01], tau)
    @test_throws AssertionError QuantitativeLib.NelsonSiegelCurve(issue, [0.03, 0.01, 0.0], 0.0)
end

@testset "fit_nelson_siegel (exact recovery)" begin
    issue = Date(2026, 1, 1)
    true_beta = [0.03, 0.015, -0.025]
    true_tau = 3.0
    truth = QuantitativeLib.NelsonSiegelCurve(issue, true_beta, true_tau)

    tenors = collect(range(0.5, 20.0, length=12))
    rates = [QuantitativeLib.ns_zero_rate(t, true_beta, true_tau) for t in tenors]

    fit = QuantitativeLib.fit_nelson_siegel(issue, tenors, rates)

    @test fit isa QuantitativeLib.NelsonSiegelCurve
    @test fit.beta ≈ true_beta atol=1e-4
    @test fit.tau ≈ true_tau atol=1e-3

    # Fitted curve reproduces the input rates at each input tenor
    for (t, r) in zip(tenors, rates)
        @test QuantitativeLib.ns_zero_rate(t, fit.beta, fit.tau) ≈ r atol=1e-3
    end
end

@testset "fit_nelson_siegel (flat curve)" begin
    issue = Date(2026, 1, 1)
    tenors = collect(range(1.0, 10.0, length=8))
    rates = fill(0.045, length(tenors))
    fit = QuantitativeLib.fit_nelson_siegel(issue, tenors, rates)

    # A flat term structure: β0 is the level, β1 ≈ β2 ≈ 0
    @test fit.beta[1] ≈ 0.045 atol=1e-4
    @test abs(fit.beta[2]) < 1e-4
    @test abs(fit.beta[3]) < 1e-4
    @test QuantitativeLib.zero_rate(fit, issue + Year(5)) ≈ 0.045 atol=1e-4
end

@testset "fit_nelson_siegel (validation)" begin
    issue = Date(2026, 1, 1)
    # Mismatched lengths
    @test_throws AssertionError QuantitativeLib.fit_nelson_siegel(issue, [1.0, 2.0], [0.03])
    # Non-positive tenor
    @test_throws AssertionError QuantitativeLib.fit_nelson_siegel(issue, [0.0, 1.0], [0.03, 0.04])
    # Too few points
    @test_throws AssertionError QuantitativeLib.fit_nelson_siegel(issue, [1.0], [0.03])
end

@testset "Nelson-Siegel-Svensson curve" begin
    issue = Date(2026, 1, 1)
    beta = [0.03, 0.01, -0.02, 0.005, -0.01]
    tau1, tau2 = 1.5, 6.0
    curve = QuantitativeLib.NelsonSiegelSvenssonCurve(issue, collect(beta), tau1, tau2)

    @test curve isa QuantitativeLib.InterestCurve

    # Zero-rate formula reproduces hand-computed values
    @test QuantitativeLib.ns_svensson_zero_rate(1.0, collect(beta), tau1, tau2) ≈ 0.0368289 atol=1e-6
    @test QuantitativeLib.ns_svensson_zero_rate(5.0, collect(beta), tau1, tau2) ≈ 0.0287741 atol=1e-6

    # Limits: z(0) = β0 + β1 + β3 (the second block adds to the short level),
    # z(∞) → β0
    @test QuantitativeLib.ns_svensson_zero_rate(1e-8, collect(beta), tau1, tau2) ≈ 0.045 atol=1e-6
    @test QuantitativeLib.ns_svensson_zero_rate(100.0, collect(beta), tau1, tau2) ≈ 0.03 atol=1e-3

    # Reduces to Nelson-Siegel when β3 = β4 = 0
    beta_ns = [0.03, 0.01, -0.02, 0.0, 0.0]
    for t in [0.5, 1.0, 3.0, 8.0]
        @test QuantitativeLib.ns_svensson_zero_rate(t, collect(beta_ns), tau1, tau2) ≈
              QuantitativeLib.ns_zero_rate(t, [0.03, 0.01, -0.02], tau1) atol=1e-12
    end

    # tenor / zero_rate / discount_factor via dates
    t1 = QuantitativeLib.tenor(curve, Date(2027, 1, 1))
    @test t1 ≈ 1.0
    @test QuantitativeLib.zero_rate(curve, Date(2027, 1, 1)) ≈ QuantitativeLib.ns_svensson_zero_rate(t1, collect(beta), tau1, tau2)
    @test QuantitativeLib.discount_factor(curve, issue) ≈ 1.0
    ds, de = Date(2027, 3, 1), Date(2027, 9, 1)
    τ = (de - ds).value / 365.0
    f = QuantitativeLib.forward_rate(curve, ds, de)
    @test (1.0 + f * τ) * QuantitativeLib.discount_factor(curve, de) ≈ QuantitativeLib.discount_factor(curve, ds)

    # Constructor validation
    @test_throws AssertionError QuantitativeLib.NelsonSiegelSvenssonCurve(issue, [0.03, 0.01, 0.0, 0.0], tau1, tau2)
    @test_throws AssertionError QuantitativeLib.NelsonSiegelSvenssonCurve(issue, collect(beta), tau1, tau1)
    @test_throws AssertionError QuantitativeLib.NelsonSiegelSvenssonCurve(issue, collect(beta), 0.0, 5.0)
end

@testset "fit_nelson_siegel_svensson (exact recovery)" begin
    issue = Date(2026, 1, 1)
    true_beta = [0.03, 0.015, -0.025, 0.008, -0.012]
    true_tau1, true_tau2 = 1.0, 5.0
    truth = QuantitativeLib.NelsonSiegelSvenssonCurve(issue, collect(true_beta), true_tau1, true_tau2)

    tenors = collect(range(0.5, 20.0, length=15))
    rates = [QuantitativeLib.ns_svensson_zero_rate(t, collect(true_beta), true_tau1, true_tau2) for t in tenors]

    fit = QuantitativeLib.fit_nelson_siegel_svensson(issue, tenors, rates)

    @test fit isa QuantitativeLib.NelsonSiegelSvenssonCurve
    # The fitted curve reproduces the input rates at each input tenor.
    for (t, r) in zip(tenors, rates)
        @test QuantitativeLib.ns_svensson_zero_rate(t, fit.beta, fit.tau1, fit.tau2) ≈ r atol=1e-3
    end
    # And matches the true curve at held-tenor points. The τ1↔τ2 block swap is
    # unidentifiable, so compare curves (order-independent) rather than parameters.
    for t in [0.3, 2.5, 12.0, 18.0]
        @test QuantitativeLib.ns_svensson_zero_rate(t, fit.beta, fit.tau1, fit.tau2) ≈
              QuantitativeLib.ns_svensson_zero_rate(t, collect(true_beta), true_tau1, true_tau2) atol=1e-3
    end
    # Time-scales recovered up to the swap symmetry (the RSS is flat in τ).
    @test sort([fit.tau1, fit.tau2]) ≈ sort([true_tau1, true_tau2]) atol=5e-2
end

@testset "fit_nelson_siegel_svensson (validation)" begin
    issue = Date(2026, 1, 1)
    # Too few points to pin five loadings + two time-scales
    @test_throws AssertionError QuantitativeLib.fit_nelson_siegel_svensson(issue, [1.0, 2.0, 3.0], [0.03, 0.04, 0.05])
    # Mismatched lengths
    @test_throws AssertionError QuantitativeLib.fit_nelson_siegel_svensson(issue, [1.0, 2.0], [0.03, 0.04, 0.05, 0.06, 0.07])
    # Non-positive tenor
    @test_throws AssertionError QuantitativeLib.fit_nelson_siegel_svensson(issue, [0.0, 1.0, 2.0, 3.0, 4.0],
        [0.03, 0.04, 0.05, 0.06, 0.07])
end

@testset "rate conversions (compounding)" begin
    # 5% continuous over one year → annual / semi-annual / simple
    r = QuantitativeLib.convert_rate(0.05, 1.0; from=QuantitativeLib.ContinuousCompounding, to=QuantitativeLib.AnnualCompounding)
    @test r ≈ exp(0.05) - 1.0 atol=1e-12

    r2 = QuantitativeLib.convert_rate(0.05, 1.0; from=QuantitativeLib.ContinuousCompounding, to=QuantitativeLib.SemiAnnualCompounding)
    @test r2 ≈ 2.0 * (exp(0.025) - 1.0) atol=1e-12

    rs = QuantitativeLib.convert_rate(0.05, 2.0; from=QuantitativeLib.ContinuousCompounding, to=QuantitativeLib.SimpleCompounding)
    @test rs ≈ (exp(0.10) - 1.0) / 2.0 atol=1e-12

    # Round-trips through every convention recover the original rate
    for comp in (QuantitativeLib.AnnualCompounding, QuantitativeLib.SemiAnnualCompounding,
                 QuantitativeLib.QuarterlyCompounding, QuantitativeLib.MonthlyCompounding,
                 QuantitativeLib.SimpleCompounding)
        r0, t = 0.042, 3.0
        rt = QuantitativeLib.convert_rate(r0, t; from=QuantitativeLib.ContinuousCompounding, to=comp)
        rb = QuantitativeLib.convert_rate(rt, t; from=comp, to=QuantitativeLib.ContinuousCompounding)
        @test rb ≈ r0 atol=1e-10
    end
end

@testset "par<->zero conversion" begin
    tenors = [1.0, 2.0, 3.0, 5.0, 7.0, 10.0]
    zeros = [0.02, 0.022, 0.025, 0.028, 0.030, 0.032]

    par = QuantitativeLib.zero_to_par(tenors, collect(zeros))
    # Upward curve → par curve is increasing. (Par rates are annual-coupon rates,
    # a different convention from the continuous zeros, so they are not directly
    # comparable in magnitude — only monotonicity is asserted here.)
    @test issorted(par)
    @test par[1] > zeros[1]  # annual coupon > continuous zero even on a flat curve

    # Round-trip recovers the original zero curve
    back = QuantitativeLib.par_to_zero(tenors, par)
    @test back ≈ collect(zeros) atol=1e-10

    # Validation: mismatched lengths and non-increasing tenors
    @test_throws AssertionError QuantitativeLib.zero_to_par([1.0, 2.0], [0.02])
    @test_throws AssertionError QuantitativeLib.par_to_zero([1.0, 2.0], [0.02, 0.03, 0.04])
end

@testset "credit curve (survival, default, spread)" begin
    issue = Date(2026, 1, 1)
    # Flat hazard curve: base is a hazard/intensity curve at 1.5%
    hazard_tenors = [1.0, 2.0, 3.0, 5.0, 7.0, 10.0]
    base = QuantitativeLib.make_curve(issue,
        [issue + Year(Int(t)) for t in hazard_tenors],
        fill(0.015, 6), QuantitativeLib.ZeroRate)
    cc = QuantitativeLib.CreditCurve(base, 0.40, :hazard)

    # Flat hazard h → Q(t) = exp(-h t)
    for t in [1.0, 5.0, 10.0]
        @test QuantitativeLib.survival_probability(cc, t) ≈ exp(-0.015 * t) atol=1e-9
        @test QuantitativeLib.default_probability(cc, t) ≈ 1.0 - exp(-0.015 * t) atol=1e-9
    end

    # Credit spread for a flat hazard: s = -log(R + (1-R)exp(-h t))/t
    R, t = 0.40, 5.0
    s = -log(R + (1.0 - R) * exp(-0.015 * t)) / t
    @test QuantitativeLib.credit_spread(cc, t) ≈ s atol=1e-9

    # hazard<->spread round-trip
    @test QuantitativeLib.hazard_to_spread(0.015, t, R) ≈ s atol=1e-9
    @test QuantitativeLib.spread_to_hazard(s, t, R) ≈ 0.015 atol=1e-9

    # Constructor validation on recovery rate
    @test_throws AssertionError QuantitativeLib.CreditCurve(base, 1.5, :hazard)
end

@testset "MonotoneCubic interpolation (PCHIP)" begin
    xs = [0.0, 1.0, 2.0, 4.0, 6.0]
    ys = [0.10, 0.12, 0.15, 0.19, 0.24]   # strictly increasing
    itp = QuantitativeLib.MonotoneCubic(xs, ys)

    # Registered through the interpolate() dispatch
    itp2 = QuantitativeLib.interpolate(QuantitativeLib.MonotoneCubic, xs, ys)
    @test itp2 isa QuantitativeLib.MonotoneCubic

    # Node values reproduced exactly
    for (x, y) in zip(xs, ys)
        @test itp(x) ≈ y atol=1e-14
        @test itp2(x) ≈ y atol=1e-14
    end

    # No overshoot: stays within the data range on a fine grid
    grid = range(xs[1], xs[end], length=1001)
    vals = [itp(t) for t in grid]
    @test minimum(vals) >= minimum(ys) - 1e-12
    @test maximum(vals) <= maximum(ys) + 1e-12

    # Piecewise-monotone on strictly increasing data
    @test issorted(vals)

    # Flat segment forces a zero slope there (no spurious wiggle)
    flatxs = [0.0, 1.0, 2.0, 3.0]
    flatys = [0.10, 0.20, 0.20, 0.20]
    itp_f = QuantitativeLib.MonotoneCubic(flatxs, flatys)
    @test itp_f(1.5) ≈ 0.20 atol=1e-12
    @test itp_f(2.5) ≈ 0.20 atol=1e-12

    # Constructor validation
    @test_throws AssertionError QuantitativeLib.MonotoneCubic([1.0, 2.0], [0.1, 0.2, 0.3])
    @test_throws AssertionError QuantitativeLib.MonotoneCubic([2.0, 1.0], [0.1, 0.2])
end

include("portfolio_test.jl")
include("montecarlo_test.jl")
