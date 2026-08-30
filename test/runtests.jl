using ClangREPL
using REPL
import REPL: LineEdit
using Test

mutable struct FakeTerminal <: REPL.Terminals.UnixTerminal
    in_stream::Base.IO
    out_stream::Base.IO
    err_stream::Base.IO
    hascolor::Bool
    raw::Bool
    FakeTerminal(stdin, stdout, stderr, hascolor=false) =
        new(stdin, stdout, stderr, hascolor, false)
end
REPL.Terminals.hascolor(t::FakeTerminal) = t.hascolor
REPL.Terminals.raw!(t::FakeTerminal, raw::Bool) = (t.raw = raw)
REPL.Terminals.size(::FakeTerminal) = (24, 80)

function make_repl()
    term = FakeTerminal(IOBuffer(), IOBuffer(), IOBuffer())
    repl = REPL.LineEditREPL(term, false)
    repl.interface = REPL.setup_interface(repl)
    return repl, term
end

@testset "incremental evaluation" begin
    @test ClangREPL.evaluate("int x = 1 + 1;") === nothing
    @test ClangREPL.evaluate("x") == 1 + 1
end

@testset "REPL evaluate path stores ans" begin
    repl, _ = make_repl()
    ClangREPL.evaluate(repl, "1 + 1")
    @test Base.MainInclude.ans == 1 + 1
end

@testset "declaration-only does not throw" begin
    val = ClangREPL.evaluate("int clangrepl_decl_only = 0;")
    @test val === nothing
end

@testset "julia.h on the default interpreter" begin
    @test ClangREPL.evaluate("#include <julia.h>") === nothing
    @test ClangREPL.evaluate("jl_is_initialized()") == ccall(:jl_is_initialized, Cint, ())
end

@testset "add_include_dir mutates the current interpreter" begin
    mktempdir() do dir
        write(joinpath(dir, "clangrepl_probe.h"), "int clangrepl_probe = 1 + 1;\n")
        ClangREPL.add_include_dir(dir)
        @test ClangREPL.evaluate("#include <clangrepl_probe.h>") === nothing
        @test ClangREPL.evaluate("clangrepl_probe") == 1 + 1
    end
end

@testset "print type and payload" begin
    r = ClangREPL.process("1 + 1")
    @test r.ok
    @test r.value == 1 + 1
    @test occursin("int", r.display)
    @test occursin(string(1 + 1), r.display)
    d = ClangREPL.process("int clangrepl_quiet_decl = 0;")
    @test d.ok
    @test isempty(d.display)
    @test d.value === nothing
end

@testset "failed increment names the bad token" begin
    tok = "clangrepl_no_such_zzzwx"
    r = ClangREPL.process(tok)
    @test !r.ok
    @test occursin(tok, r.diagnostics)
end

@testset "metacommands" begin
    h = ClangREPL.process("%help")
    @test h.ok
    for cmd in ("%undo", "%lib", "%include", "%decl", "%ir", "%ast")
        @test occursin(cmd, h.display)
    end

    @test ClangREPL.process("int clangrepl_undo_nm = 1 + 1;").ok
    @test ClangREPL.process("%undo").ok
    u = ClangREPL.process("clangrepl_undo_nm")
    @test !u.ok
    @test occursin("clangrepl_undo_nm", u.diagnostics)

    @test ClangREPL.process("%include <cmath>").ok
    s = ClangREPL.process("std::sqrt(4.0)")
    @test s.ok
    @test s.value == sqrt(4.0)

    @test ClangREPL.process("int clangrepl_decl_fn() { return 1 + 1; }").ok
    decl = ClangREPL.process("%decl clangrepl_decl_fn")
    @test decl.ok
    @test occursin("clangrepl_decl_fn", decl.display)
    @test occursin("location:", decl.display)
    m = match(r"location:.*:(\d+):", decl.display)
    @test m !== nothing
    @test parse(Int, m.captures[1]) > 0

    @test ClangREPL.process("int clangrepl_dump_fn() { return 1 + 1; }").ok
    ir = ClangREPL.process("%ir")
    @test ir.ok
    @test !isempty(ir.display)
    ast = ClangREPL.process("%ast")
    @test ast.ok
    @test !isempty(ast.display)
end

@testset "%lib loads an extern C symbol" begin
    cc = Sys.which("cc")
    @test cc !== nothing
    mktempdir() do dir
        src = joinpath(dir, "add.c")
        write(src, "int clangrepl_lib_add(int a, int b) { return a + b; }\n")
        dlext = Sys.iswindows() ? "dll" : (Sys.isapple() ? "dylib" : "so")
        lib = joinpath(dir, "libclangrepl_add." * dlext)
        run(`$cc -shared -fPIC -o $lib $src`)
        @test ClangREPL.process("%lib $lib").ok
        @test ClangREPL.process("extern \"C\" int clangrepl_lib_add(int, int);").ok
        r = ClangREPL.process("clangrepl_lib_add(1 + 1, 1 + 1)")
        @test r.ok
        @test r.value == (1 + 1) + (1 + 1)
    end
end

@testset "completeness predicate" begin
    @test !ClangREPL.is_complete("int f() {")
    @test ClangREPL.is_complete("int f() { return 1 + 1; }")
    @test ClangREPL.is_complete("%undo")
    @test ClangREPL.is_complete("")
end

@testset "C++ completion of a unique identifier" begin
    @test ClangREPL.process("int clangrepl_complete_id = 0;").ok
    prefix = "clangrepl_comp"
    results, pref = ClangREPL.complete(prefix)
    @test pref == prefix || occursin(prefix, pref)
    @test any(c -> occursin("clangrepl_complete_id", c), results)
end

@testset "Clang> prompt, comma keymap, completion provider, on_enter" begin
    repl, term = make_repl()
    main_mode = repl.interface.modes[1]
    clang_mode = ClangREPL.create_mode(repl, main_mode)
    @test clang_mode.prompt == "Clang> "
    @test clang_mode.sticky == true
    @test !(clang_mode.complete isa REPL.REPLCompletionProvider)
    @test clang_mode.complete isa ClangREPL.ClangCompletionProvider
    @test clang_mode.on_enter !== LineEdit.default_enter_cb

    st = LineEdit.init_state(term, clang_mode)
    write(st.input_buffer, "int f() {")
    @test clang_mode.on_enter(st) == false
    st.input_buffer.size = 0
    st.input_buffer.ptr = 1
    write(st.input_buffer, "int f() { return 1 + 1; }")
    @test clang_mode.on_enter(st) == true

    ClangREPL.repl_init(repl)
    attached = repl.interface.modes[end]
    @test attached.prompt == "Clang> "
    @test !(attached.complete isa REPL.REPLCompletionProvider)

    s = LineEdit.init_state(term, repl.interface)
    @test s.current_mode === main_mode
    handler = main_mode.keymap_dict[',']
    handler(s, nothing)
    @test s.current_mode === attached

    s2 = LineEdit.init_state(term, repl.interface)
    LineEdit.edit_insert(s2, 'a')
    @test s2.current_mode === main_mode
    handler(s2, nothing)
    @test s2.current_mode === main_mode
    @test LineEdit.input_string(s2) == "a,"
end
