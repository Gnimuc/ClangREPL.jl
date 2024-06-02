using ClangREPL
using Test

@testset "ClangREPL" begin
    itpr = get_current_interpreter()
    @test itpr.ptr != C_NULL
end
