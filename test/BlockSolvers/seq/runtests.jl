using Test

@testset "BlockDiagonalSolvers" begin include("BlockDiagonalSolversTests.jl") end
@testset "BlockTriangularSolvers" begin include("BlockTriangularSolversTests.jl") end
@testset "StaggeredFEOperators" begin include("StaggeredFEOperatorsTests.jl") end
