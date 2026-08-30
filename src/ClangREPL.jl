module ClangREPL

import ClangCompiler as CC

using REPL
import REPL: LineEdit

const INSTANCE_ID = Threads.Atomic{Int}(0)

mutable struct Session
    interp::CC.CxxInterpreter
    diag::CC.TextDiagnosticBuffer
    last_ir::String
    last_ast::String
end

const INSTANCES = Dict{Int,Session}()

struct EvalResult
    value::Any
    display::String
    diagnostics::String
    ok::Bool
end

struct ClangCompletionProvider <: LineEdit.CompletionProvider end

julia_include_dir() = normpath(joinpath(Sys.BINDIR, "..", "include", "julia"))

current_session() = INSTANCES[INSTANCE_ID[]]
current_interpreter() = current_session().interp

function register!(s::Session)
    id = Threads.atomic_add!(INSTANCE_ID, 1) + 1
    INSTANCES[id] = s
    return s
end

function make_interpreter()
    I = CC.create_interpreter(["-I", julia_include_dir(), "-Wno-nullability-completeness"])
    CC.is_null_handle(I.interp) && error("ClangCompiler: failed to create interpreter.")
    buf = CC.TextDiagnosticBuffer()
    CC.setClient(CC.getDiagnostics(CC.get_instance(I)), buf, true)
    return Session(I, buf, "", "")
end

const KIND_LABEL = Dict(
    CC.CXValue_Bool => "bool",
    CC.CXValue_Char_S => "char",
    CC.CXValue_SChar => "signed char",
    CC.CXValue_Char_U => "char",
    CC.CXValue_UChar => "unsigned char",
    CC.CXValue_Short => "short",
    CC.CXValue_UShort => "unsigned short",
    CC.CXValue_Int => "int",
    CC.CXValue_UInt => "unsigned int",
    CC.CXValue_Long => "long",
    CC.CXValue_ULong => "unsigned long",
    CC.CXValue_LongLong => "long long",
    CC.CXValue_ULongLong => "unsigned long long",
    CC.CXValue_Float => "float",
    CC.CXValue_Double => "double",
    CC.CXValue_LongDouble => "long double",
    CC.CXValue_PtrOrObj => "void *",
)

function value_to_julia(v)
    CC.isVoid(v) && return nothing
    CC.hasValue(v) || return nothing
    k = CC.getKind(v)
    if k == CC.CXValue_Bool
        return CC.getBool(v)
    elseif k == CC.CXValue_Char_S
        return CC.getChar_S(v)
    elseif k == CC.CXValue_SChar
        return CC.getSChar(v)
    elseif k == CC.CXValue_Char_U
        return CC.getUChar(v)
    elseif k == CC.CXValue_UChar
        return CC.getUChar(v)
    elseif k == CC.CXValue_Short
        return CC.getShort(v)
    elseif k == CC.CXValue_UShort
        return CC.getUShort(v)
    elseif k == CC.CXValue_Int
        return CC.getInt(v)
    elseif k == CC.CXValue_UInt
        return CC.getUInt(v)
    elseif k == CC.CXValue_Long
        return CC.getLong(v)
    elseif k == CC.CXValue_ULong
        return CC.getULong(v)
    elseif k == CC.CXValue_LongLong
        return CC.getLongLong(v)
    elseif k == CC.CXValue_ULongLong
        return CC.getULongLong(v)
    elseif k == CC.CXValue_Float
        return CC.getFloat(v)
    elseif k == CC.CXValue_Double
        return CC.getDouble(v)
    elseif k == CC.CXValue_LongDouble
        return CC.getLongDouble(v)
    elseif k == CC.CXValue_PtrOrObj
        return CC.getPtr(v)
    elseif k == CC.CXValue_Void || k == CC.CXValue_Unspecified
        return nothing
    else
        error("unsupported clang value kind: $k")
    end
end

function format_value(v)
    CC.isVoid(v) && return ""
    CC.hasValue(v) || return ""
    payload = value_to_julia(v)
    payload === nothing && return ""
    label = get(KIND_LABEL, CC.getKind(v), string(CC.getKind(v)))
    return "($label) $payload"
end

function diagnostic_mark(buf)
    return (
        Int(CC.size(buf, CC.CXTextDiagnosticBuffer_Error)),
        Int(CC.size(buf, CC.CXTextDiagnosticBuffer_Warning)),
        Int(CC.size(buf, CC.CXTextDiagnosticBuffer_Note)),
    )
end

function collect_diagnostics(buf, mark)
    parts = String[]
    for (level, from) in (
        (CC.CXTextDiagnosticBuffer_Error, mark[1]),
        (CC.CXTextDiagnosticBuffer_Warning, mark[2]),
        (CC.CXTextDiagnosticBuffer_Note, mark[3]),
    )
        n = Int(CC.size(buf, level))
        for i in from:(n - 1)
            push!(parts, CC.getMessage(buf, level, i))
        end
    end
    return join(parts, "\n")
end

function snapshot_ir(ptu)
    CC.is_null_handle(ptu) && return ""
    m = CC.getModule(ptu)
    m === nothing && return ""
    return string(m)
end

function snapshot_ast(I)
    decls = CC.top_level_decls(I)
    return join((CC.dumpToString(d) for d in decls), "\n")
end

function eval_cpp(code::AbstractString)
    sess = current_session()
    I = sess.interp
    snippet = String(code)
    mark = diagnostic_mark(sess.diag)
    ptu = CC.parse(I, snippet)
    if CC.is_null_handle(ptu)
        diags = collect_diagnostics(sess.diag, mark)
        isempty(diags) && (diags = "Parsing failed.")
        return EvalResult(nothing, "", diags, false)
    end
    sess.last_ir = snapshot_ir(ptu)
    sess.last_ast = snapshot_ast(I)
    decls = CC.top_level_decls(I)
    is_expr = any(d -> d isa CC.TopLevelStmtDecl, decls)
    if is_expr
        v, err = CC.ParseAndExecuteChecked(I.interp, snippet)
        try
            diags = collect_diagnostics(sess.diag, mark)
            if !isempty(err) && !CC.hasValue(v)
                isempty(diags) && (diags = err)
                return EvalResult(nothing, "", diags, false)
            end
            display = format_value(v)
            return EvalResult(value_to_julia(v), display, diags, true)
        finally
            CC.dispose(v)
        end
    else
        exec_err = CC.execute(I, ptu)
        diags = collect_diagnostics(sess.diag, mark)
        if !isempty(exec_err)
            isempty(diags) && (diags = exec_err)
            return EvalResult(nothing, "", diags, false)
        end
        return EvalResult(nothing, "", diags, true)
    end
end

const META_HELP = """
%help                list metacommands
%undo                drop the last increment
%lib <path>          load a shared library
%include <header>    include a header into the current interpreter
%decl <name>         show signature, location, and mangled name
%ir                  dump LLVM IR of the last increment
%ast                 dump the AST of the last increment
"""

function split_meta(line::AbstractString)
    rest = lstrip(String(line)[2:end])
    isempty(rest) && return "help", ""
    parts = split(rest, limit=2)
    cmd = lowercase(String(parts[1]))
    arg = length(parts) == 2 ? strip(String(parts[2])) : ""
    return cmd, arg
end

function include_line(arg::AbstractString)
    a = strip(arg)
    isempty(a) && return nothing
    if startswith(a, "<") || startswith(a, "\"")
        return "#include $a"
    end
    return "#include <$a>"
end

function format_decl(I, name::AbstractString)
    d = CC.find_decl(I, name)
    d === nothing && return nothing
    shown = d isa CC.AbstractNamedDecl ? CC.decl_name(d) : name
    lines = String["name: $shown"]
    if d isa CC.AbstractNamedDecl
        q = CC.qualified_name(d)
        !isempty(q) && push!(lines, "qualified: $q")
    end
    if d isa CC.AbstractFunctionDecl
        sig = CC.signature(d)
        push!(lines, "signature: $(sig.return_type) $(sig.name)($(join(sig.parameters, ", ")))")
        loc = CC.source_location(I, d)
        push!(lines, "location: $(loc.file):$(loc.line):$(loc.column)")
        push!(lines, "mangled: $(CC.mangled_name(I, d))")
    else
        loc = CC.source_location(I, d)
        push!(lines, "location: $(loc.file):$(loc.line):$(loc.column)")
        try
            push!(lines, "mangled: $(CC.mangled_name(I, d))")
        catch
        end
    end
    return join(lines, "\n")
end

function process_meta(line::AbstractString)
    sess = current_session()
    I = sess.interp
    cmd, arg = split_meta(line)
    if cmd == "help" || cmd == "?"
        return EvalResult(nothing, META_HELP, "", true)
    elseif cmd == "undo"
        err = CC.undo(I.interp, 1)
        if !isempty(err)
            return EvalResult(nothing, "", err, false)
        end
        sess.last_ir = ""
        sess.last_ast = ""
        return EvalResult(nothing, "", "", true)
    elseif cmd == "lib"
        isempty(arg) && return EvalResult(nothing, "", "usage: %lib <path>", false)
        err = CC.LoadDynamicLibrary(I.interp, arg)
        if !isempty(err)
            return EvalResult(nothing, "", err, false)
        end
        return EvalResult(nothing, "", "", true)
    elseif cmd == "include"
        src = include_line(arg)
        src === nothing && return EvalResult(nothing, "", "usage: %include <header>", false)
        return eval_cpp(src)
    elseif cmd == "decl"
        isempty(arg) && return EvalResult(nothing, "", "usage: %decl <name>", false)
        text = format_decl(I, arg)
        text === nothing && return EvalResult(nothing, "", "no declaration named $arg", false)
        return EvalResult(nothing, text, "", true)
    elseif cmd == "ir"
        isempty(sess.last_ir) && return EvalResult(nothing, "", "no increment to dump", false)
        return EvalResult(nothing, sess.last_ir, "", true)
    elseif cmd == "ast"
        isempty(sess.last_ast) && return EvalResult(nothing, "", "no increment to dump", false)
        return EvalResult(nothing, sess.last_ast, "", true)
    else
        return EvalResult(nothing, "", "unknown metacommand %$cmd (see %help)", false)
    end
end

"""
    process(input) -> EvalResult
Run a C++ increment or a `%` metacommand on the current interpreter.
"""
function process(input::AbstractString)
    snippet = String(input)
    isempty(strip(snippet)) && return EvalResult(nothing, "", "", true)
    startswith(lstrip(snippet), "%") && return process_meta(lstrip(snippet))
    return eval_cpp(snippet)
end

"""
    evaluate(input::AbstractString)
Compile and run `input` as one increment on the current interpreter, returning a Julia
value. A declaration-only snippet returns `nothing` and does not throw.
"""
function evaluate(input::AbstractString)
    r = process(input)
    r.ok || error(isempty(r.diagnostics) ? "evaluation failed" : r.diagnostics)
    return r.value
end

function repl_iostream(repl, which::Symbol)
    t = repl.t
    which === :out && return hasproperty(t, :out_stream) ? t.out_stream : stdout
    return hasproperty(t, :err_stream) ? t.err_stream : stderr
end

function evaluate(repl::REPL.AbstractREPL, input::String)
    try
        r = process(input)
        if r.ok
            setglobal!(Base.MainInclude, :ans, r.value)
            isempty(r.display) || println(repl_iostream(repl, :out), r.display)
        else
            msg = r.diagnostics
            if !isempty(msg)
                println(repl_iostream(repl, :err), msg)
            else
                error("evaluation failed")
            end
        end
    catch err
        Base.display_error(repl_iostream(repl, :err), err, Base.catch_backtrace())
    end
end

function skip_quoted(s::AbstractString, i, quotechar)
    last = lastindex(s)
    i = nextind(s, i)
    while i <= last
        c = s[i]
        c == '\\' && i < last && (i = nextind(s, nextind(s, i)); continue)
        c == quotechar && return nextind(s, i)
        i = nextind(s, i)
    end
    return 0
end

function skip_line_comment(s::AbstractString, i)
    last = lastindex(s)
    i = nextind(s, nextind(s, i))
    while i <= last
        s[i] == '\n' && return i
        i = nextind(s, i)
    end
    return nextind(s, last)
end

function skip_block_comment(s::AbstractString, i)
    last = lastindex(s)
    i = nextind(s, nextind(s, i))
    while i <= last
        if s[i] == '*' && i < last && s[nextind(s, i)] == '/'
            return nextind(s, nextind(s, i))
        end
        i = nextind(s, i)
    end
    return 0
end

"""
    is_complete(src) -> Bool
Whether `src` is a complete C++ increment (balanced braces/parens/brackets,
closed strings and comments). Lines starting with `%` are always complete.
"""
function is_complete(src::AbstractString)
    s = String(src)
    isempty(strip(s)) && return true
    startswith(lstrip(s), "%") && return true
    i = firstindex(s)
    last = lastindex(s)
    braces = 0
    parens = 0
    brackets = 0
    while i <= last
        c = s[i]
        if c == '"' || c == '\''
            i = skip_quoted(s, i, c)
            i == 0 && return false
        elseif c == '/' && i < last && s[nextind(s, i)] == '/'
            i = skip_line_comment(s, i)
        elseif c == '/' && i < last && s[nextind(s, i)] == '*'
            i = skip_block_comment(s, i)
            i == 0 && return false
        else
            c == '{' && (braces += 1)
            c == '}' && (braces -= 1)
            c == '(' && (parens += 1)
            c == ')' && (parens -= 1)
            c == '[' && (brackets += 1)
            c == ']' && (brackets -= 1)
            i = nextind(s, i)
        end
    end
    return braces == 0 && parens == 0 && brackets == 0
end

function clang_on_enter(s)
    return is_complete(LineEdit.input_string(s))
end

function bytepos_to_linecol(str::AbstractString, bytepos::Integer)
    line = 1
    col = 1
    n = 0
    for c in str
        n >= bytepos && break
        if c == '\n'
            line += 1
            col = 1
        else
            col += 1
        end
        n += ncodeunits(c)
    end
    return line, col
end

function complete(text::AbstractString, bytepos::Integer=ncodeunits(text))
    I = current_interpreter()
    line, col = bytepos_to_linecol(text, bytepos)
    builder = CC.IncrementalCompilerBuilder()
    ci = nothing
    try
        CC.SetCompilerArgs(builder, CC.get_default_args())
        ci = CC.CreateCpp(builder)
        (ci === nothing || CC.is_null_handle(ci)) && return String[], ""
        results, prefix = CC.codeComplete(ci, String(text), line, col, CC.get_instance(I))
        return results, prefix
    finally
        ci !== nothing && !CC.is_null_handle(ci) && CC.dispose(ci)
        CC.dispose(builder)
    end
end

function LineEdit.complete_line(::ClangCompletionProvider, s; hint::Bool=false)
    # Hint generation runs on a worker thread; clang is not thread-safe there.
    hint && return String[], "", true
    str = LineEdit.input_string(s)
    startswith(lstrip(str), "%") && return String[], "", true
    pos = position(LineEdit.buffer(s))
    results, prefix = complete(str, pos)
    return results, prefix, true
end

function create_mode(repl::REPL.AbstractREPL, main::LineEdit.Prompt)
    clang_mode = LineEdit.Prompt("Clang> ";
        prompt_prefix    = repl.options.hascolor ? "\x1b[38;5;111m" : "",
        prompt_suffix    = "",
        repl             = repl,
        complete         = ClangCompletionProvider(),
        on_enter         = clang_on_enter,
        sticky           = true
    )

    hp = main.hist
    hp.mode_mapping[:clang] = clang_mode
    clang_mode.hist = hp

    _, prefix_keymap = LineEdit.setup_prefix_keymap(hp, clang_mode)

    clang_mode.keymap_dict = LineEdit.keymap(
        Dict{Any,Any}[
            REPL.mode_keymap(main),
            prefix_keymap,
            LineEdit.history_keymap,
            LineEdit.default_keymap,
            LineEdit.escape_defaults
        ]
    )

    clang_mode.on_done = (s, buf, ok) -> begin
        ok || return REPL.transition(s, :abort)
        input = String(take!(buf))
        REPL.reset(repl)
        evaluate(repl, input)
        REPL.prepare_next(repl)
        REPL.reset_state(s)
        s.current_mode.sticky || REPL.transition(s, main)
    end

    return clang_mode
end

function repl_init(repl::REPL.AbstractREPL)
    main_mode = repl.interface.modes[1]
    clang_mode = create_mode(repl, main_mode)
    push!(repl.interface.modes, clang_mode)
    keymap = Dict{Any,Any}(
        ',' => function (s,args...)
            if isempty(s) || position(LineEdit.buffer(s)) == 0
                buf = copy(LineEdit.buffer(s))
                LineEdit.transition(s, clang_mode) do
                    LineEdit.state(s, clang_mode).input_buffer = buf
                end
            else
                LineEdit.edit_insert(s, ',')
            end
        end
    )
    main_mode.keymap_dict = LineEdit.keymap_merge(main_mode.keymap_dict, keymap)
    return nothing
end

function __init__()
    register!(make_interpreter())

    if isdefined(Base, :active_repl)
        repl_init(Base.active_repl)
    end

    atexit() do
        for (_, s) in INSTANCES
            CC.dispose(s.interp)
        end
    end
end

function create()
    register!(make_interpreter())
    return nothing
end
export create

function add_include_dir(x::AbstractString)
    path = normpath(x)
    isdir(path) || error("not a directory: $path")
    I = current_interpreter()
    hs = CC.getHeaderSearchInfo(CC.getPreprocessor(CC.get_instance(I)))
    fm = CC.getFileMgr(hs)
    dref = CC.getOptionalDirectoryRef(fm, path)
    dref === nothing && error("clang could not open include directory: $path")
    dl = CC.DirectoryLookup(dref, CC.CXCharacteristicKind_C_User, false)
    try
        CC.AddSearchPath(hs, dl, true)
    finally
        CC.dispose(dl)
        CC.dispose(dref)
    end
    return nothing
end
export add_include_dir

end
