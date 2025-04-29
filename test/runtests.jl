using ClangREPL
using Test

@testset "ClangREPL" begin
    @test !isempty(ClangREPL.INSTANCES)
end
