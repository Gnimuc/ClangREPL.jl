module ClangREPL

using CppInterOp

using REPL
import REPL: LineEdit

function evaluate(repl::REPL.AbstractREPL, input::String)
    try
        CppInterOp.Process(input)
    catch err
        Base.display_error(repl.t.err_stream, err, Base.catch_backtrace())
    end
end

function create_mode(repl::REPL.AbstractREPL, main::LineEdit.Prompt)
    # config prompt style
    clang_mode = LineEdit.Prompt("Clang> ";
        prompt_prefix    = repl.options.hascolor ? "\x1b[38;5;111m" : "",
        prompt_suffix    = "",
        repl             = repl,
        complete         = REPL.REPLCompletionProvider(),
        sticky           = true
    )

    # config keymap
    hp = main.hist
    hp.mode_mapping[:clang] = clang_mode
    clang_mode.hist = hp

    _, skeymap = LineEdit.setup_search_keymap(hp)
    _, prefix_keymap = LineEdit.setup_prefix_keymap(hp, clang_mode)

    clang_mode.keymap_dict = LineEdit.keymap(
        Dict{Any,Any}[
            skeymap,
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
    if create_interpreter().ptr == C_NULL
        error("CppInterOp: failed to create interpreter.")
    end

    CppInterOp.EnableDebugOutput()

    # for embedding Julia
    setup_julia_env()

    if isdefined(Base, :active_repl)
        repl_init(Base.active_repl)
    end
end

get_current_interpreter() = CppInterOp.GetInterpreter()
export get_current_interpreter

function setup_julia_env()
    julia_include_dir = normpath(joinpath(Sys.BINDIR, "..", "include", "julia"))
    CppInterOp.AddIncludePath(julia_include_dir)
end

function reset()
    create_interpreter()
    setup_julia_env()
end
export reset

end
