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
    # Calendar spanning 2024-01-01 .. 2025-01-01 with semi-annual payments
    cal = QuantitativeLib.InstrumentCalendar([Date(2024, 1, 1)])
    for d in [Date(2024, 7, 1), Date(2025, 1, 1)]
        push!(cal.days, d)
    end

    bond = QuantitativeLib.CouponBond(Date(2024, 1, 1), Date(2025, 1, 1), 0.05, cal)
    push!(bond.coupons, QuantitativeLib.Coupon(Date(2024, 7, 1), 2.5))
    push!(bond.coupons, QuantitativeLib.Coupon(Date(2025, 1, 1), 2.5))

    p = QuantitativeLib.BondPricer(bond, 0.05)

    @test p isa QuantitativeLib.Pricer

    d1 = (Date(2024, 7, 1) - Date(2024, 1, 1)).value
    d2 = (Date(2025, 1, 1) - Date(2024, 1, 1)).value
    expected = 2.5 * exp(-0.05 * d1 / 365.0) +
               2.5 * exp(-0.05 * d2 / 365.0) +
               100.0 * exp(-0.05 * d2 / 365.0)
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
