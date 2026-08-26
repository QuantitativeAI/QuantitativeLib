using QuantitativeLib
using Test

@testset "QuantitativeLib.jl" begin
    @test isdefined(@__MODULE__, :QuantitativeLib)
    @test isa(QuantitativeLib, Module)
    @test nameof(QuantitativeLib) == :QuantitativeLib
end
