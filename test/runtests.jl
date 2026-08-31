using QuantitativeLib
using Dates
using Test

@testset "QuantitativeLib.jl" begin
    @test isdefined(@__MODULE__, :QuantitativeLib)
    @test isa(QuantitativeLib, Module)
    @test nameof(QuantitativeLib) == :QuantitativeLib
end

@testset "BondPricer (zero-coupon)" begin
    # Calendar spanning 2024-01-01 .. 2026-01-01 (the full term)
    cal = QuantitativeLib.InstrumentCalendar([Date(2024, 1, 1)])
    for d in [Date(2024, 7, 1), Date(2025, 1, 1), Date(2025, 7, 1), Date(2026, 1, 1)]
        push!(cal.days, d)
    end

    p = QuantitativeLib.BondPricer(cal, 0.05, 100.0)

    @test p isa QuantitativeLib.Pricer
    @test QuantitativeLib.Pricers.start_date(p) == Date(2024, 1, 1)
    @test QuantitativeLib.Pricers.maturity_date(p) == Date(2026, 1, 1)

    days = (Date(2026, 1, 1) - Date(2024, 1, 1)).value
    expected = 100.0 * exp(-0.05 * days / 365.0)
    @test QuantitativeLib.price(p) ≈ expected

    # default face value is 100
    @test QuantitativeLib.BondPricer(cal, 0.05).face_value == 100.0

    # a calendar with fewer than two dates is rejected
    short = QuantitativeLib.InstrumentCalendar([Date(2024, 1, 1)])
    @test_throws AssertionError QuantitativeLib.BondPricer(short, 0.05)
end
