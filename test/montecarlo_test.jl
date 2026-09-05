# test/montecarlo_test.jl

using QuantitativeLib
using QuantitativeLib.Instruments: Option
using Dates
using Test
using Random

@testset "MonteCarloPricing" begin
    @test isdefined(QuantitativeLib, :MonteCarloPricing)
    @test isa(QuantitativeLib.MonteCarloPricing, Module)
    
    # Test colwise_simulate_stock_prices
    @testset "colwise_simulate_stock_prices" begin
        Random.seed!(QuantitativeLib, 42)
        initial_price = 100.0
        drift = 0.05
        volatility = 0.2
        total_days = 10
        num_simulations = 100
        
        prices = QuantitativeLib.colwise_simulate_stock_prices(
            initial_price, drift, volatility, total_days, num_simulations
        )
        
        @test size(prices) == (num_simulations, total_days)
        @test prices[1, 1] == initial_price
        @test prices[2, 1] == initial_price
        @test all(prices[:, 1] .== initial_price)
        
        # Prices should be positive
        @test all(prices .> 0)
    end
    
    # Test f (payoff function)
    @testset "f (payoff function)" begin
        # In-the-money option
        col1 = [100.0, 110.0, 120.0]
        @test QuantitativeLib.MonteCarloPricing.f(col1, 100.0) == 20.0
        @test QuantitativeLib.MonteCarloPricing.f(col1, 110.0) == 10.0
        @test QuantitativeLib.MonteCarloPricing.f(col1, 130.0) == 0.0
        
        # Out-of-the-money option
        col2 = [100.0, 90.0, 80.0]
        @test QuantitativeLib.MonteCarloPricing.f(col2, 100.0) == 0.0
        @test QuantitativeLib.MonteCarloPricing.f(col2, 50.0) == 30.0
    end
    
    # Test priceCallOptionBroadcasted
    @testset "priceCallOptionBroadcasted" begin
        Random.seed!(QuantitativeLib, 42)
        
        # Create some sample prices
        prices = QuantitativeLib.colwise_simulate_stock_prices(
            100.0, 0.05, 0.2, 30, 1000
        )
        
        strike = 100.0
        r = 0.05
        TT = 30 / 252  # 30 trading days
        
        option_price = QuantitativeLib.priceCallOptionBroadcasted(
            prices, r, TT, strike
        )
        
        @test option_price > 0
        @test isfinite(option_price)
        
        # Test with different parameters
        prices2 = QuantitativeLib.colwise_simulate_stock_prices(
            150.0, 0.1, 0.3, 60, 500
        )
        
        option_price2 = QuantitativeLib.priceCallOptionBroadcasted(
            prices2, 0.04, 60 / 252, 140.0
        )
        
        @test option_price2 > 0
        @test isfinite(option_price2)
    end
    
    # Test priceCallOption (threaded version)
    @testset "priceCallOption (threaded)" begin
        Random.seed!(QuantitativeLib, 42)
        
        prices = QuantitativeLib.colwise_simulate_stock_prices(
            100.0, 0.05, 0.2, 30, 1000
        )
        
        strike = 100.0
        r = 0.05
        T = 30 / 252
        
        option_price = QuantitativeLib.priceCallOption(
            prices, r, T, strike
        )
        
        @test option_price > 0
        @test isfinite(option_price)
    end
    
    # Test consistency between broadcasted and threaded versions
    @testset "consistency between pricing methods" begin
        Random.seed!(QuantitativeLib, 42)
        
        prices = QuantitativeLib.colwise_simulate_stock_prices(
            100.0, 0.05, 0.2, 30, 1000
        )
        
        strike = 100.0
        r = 0.05
        TT = 30 / 252
        
        price_broadcasted = QuantitativeLib.priceCallOptionBroadcasted(
            prices, r, TT, strike
        )
        
        price_threaded = QuantitativeLib.priceCallOption(
            prices, r, TT, strike
        )
        
        # Both should give similar results (Monte Carlo has variance)
        @test price_broadcasted ≈ price_threaded atol=1e-10
    end
    
    # Test with Option instrument
    @testset "pricing with Option instrument" begin
        Random.seed!(QuantitativeLib, 42)
        
        # Create an Option instrument
        option = QuantitativeLib.Option(
            100.0,  # underlying_price
            100.0,  # strike_price
            Date(2027, 1, 1),  # expiry_date
            0.2,    # volatility
            0.05,   # risk_free_rate
            0.0     # dividend_yield
        )
        
        # Calculate time to maturity in trading days
        days_to_maturity = (option.expiry_date - Date(2026, 9, 4)).value
        # Rough approximation: convert calendar days to trading days
        trading_days = Int(floor(days_to_maturity * 252 / 365))
        
        # Simulate and price
        prices = QuantitativeLib.colwise_simulate_stock_prices(
            option.underlying_price,
            option.risk_free_rate,  # using risk-free rate as drift for simplicity
            option.volatility,
            trading_days,
            1000
        )
        
        option_price = QuantitativeLib.priceCallOptionBroadcasted(
            prices,
            option.risk_free_rate,
            trading_days / 252.0,
            option.strike_price
        )
        
        @test option_price > 0
        @test isfinite(option_price)
    end
end
