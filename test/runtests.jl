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
