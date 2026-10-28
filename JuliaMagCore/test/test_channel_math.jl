# Channel Math: the expression parser, the evaluator and the "database.channel_math" tool.

const CM_L1 = LineId(LINE, 1001, 0)
const CM_L2 = LineId(LINE, 1002, 0)

"""
A session with one database of two lines, L1001 and L1002, of 3 rows each.
Channels MAG and IGRF (Float64), MAGP (Float64, protected) and CNT (Int32,
with a missing value on L1001). Returns `(s, id)`.
"""
function two_line_db()
    s = fresh_session()
    p = s.project
    id = new_item_id(p, ITEM_DATABASE)
    db = create_database(joinpath(p.folder, "databases", id), id)
    for (name, T, prot) in (("MAG", Float64, false), ("IGRF", Float64, false), ("MAGP", Float64, true),
                            ("CNT", Int32, false))
        add_channel!(db, ChannelInfo(name, name, T, "", ROLE_NONE, :normal, 10, -1, prot, 1))
    end
    data = Dict("MAG" => [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]], "IGRF" => [[0.5, 0.5, 0.5], [1.0, 1.0, 1.0]],
                "MAGP" => [[10.0, 20.0, 30.0], [40.0, 50.0, 60.0]],
                "CNT" => [Int32[1, typemin(Int32), 3], Int32[4, 5, 6]])
    apps = open_appenders(db, collect(keys(data)))
    for (k, lid) in enumerate((CM_L1, CM_L2))
        add_line!(db, LineInfo(lid, 1, "2024-05-01", 0.0, 1.0, 3, 0, true))
        for (name, v) in data
            foreach(x -> append_value!(apps[name], x), v[k])
        end
    end
    close_appenders!(apps)
    save_meta(db)
    add_item!(p, ProjectItem(id, ITEM_DATABASE, id, "databases/$id", "", ""))
    save_project(p)
    return s, id
end

cm_folder(s, id) = JuliaMagCore.item_path(s.project, item(s.project, id))
cm_file(s, id, name) = joinpath(cm_folder(s, id), "channels", name * ".f64")
cm_meta(s, id) = read(joinpath(cm_folder(s, id), "database.json"), String)
cm_sides(s, id) = filter(startswith(".undo-"), readdir(cm_folder(s, id)))

function cm_run(s, id; kwargs...)
    return wait_job(run_tool(s, "database.channel_math"; inputs = Dict("database" => id), kwargs...))
end

@testset "channel math: the brief" begin
    (; s, id, L) = make_db_with(MAG = [1.0, 2.0, NaN], IGRF = [0.5, 0.5, 0.5])
    job = wait_job(run_tool(s, "database.channel_math"; inputs = Dict("database" => id),
                            expr = "MAG_IGRF = MAG - IGRF", lines = "all"))
    @test status(job) == JOB_DONE
    db = database(s.project, id)
    @test isequal(collect(read_channel(db, L, "MAG_IGRF")), [0.5, 1.5, NaN])
    @test_throws ToolError parse_channel_expr("A = run(`rm -rf /`)", ["B"])
    @test_throws ToolError parse_channel_expr("A = NOPE + 1", ["B"])
end

@testset "channel math: parser" begin
    chans = ["MAG", "IGRF", "MAG-IGRF", "e"]
    msg(text) = try
        parse_channel_expr(text, chans)
        ""
    catch err
        err isa ToolError ? err.msg : rethrow()
    end
    # accepted forms; the tree has channel names as symbols and numbers as Float64
    @test parse_channel_expr("MAG_IGRF = MAG - IGRF", chans) == :(MAG_IGRF = MAG - IGRF)
    @test parse_channel_expr("OUT = `MAG-IGRF` * 2", chans) == Expr(:(=), :OUT, Expr(:call, :*, Symbol("MAG-IGRF"), 2.0))
    @test parse_channel_expr("`A B` = MAG", chans) == Expr(:(=), Symbol("A B"), :MAG)
    @test parse_channel_expr("A = MAG .- sqrt.(IGRF)", chans) == :(A = MAG - sqrt(IGRF))
    @test parse_channel_expr("A = pi * MAG", chans) == Expr(:(=), :A, Expr(:call, :*, Float64(pi), :MAG))
    @test parse_channel_expr("A = e", chans) == :(A = e)      # a channel named e wins over the constant
    @test parse_channel_expr("A = e", ["MAG"]) == Expr(:(=), :A, Float64(ℯ))
    @test parse_channel_expr("A = 0 < MAG < 3", chans) == :(A = (0.0 < MAG) & (MAG < 3.0))
    @test parse_channel_expr("A = ifelse(isnan(MAG), IGRF, max(MAG, 1, 2))", chans) isa Expr
    @test parse_channel_expr("A = (MAG > 0) & (IGRF <= 1) | (MAG == 2) & (MAG != 3)", chans) isa Expr
    @test parse_channel_expr("A = -MAG + abs(exp(log(log10(MAG)))) ^ 2 / atan(MAG, IGRF) + sin(cos(tan(atan(MAG))))",
                             chans) isa Expr
    @test parse_channel_expr("A = MAG >= 1", chans) isa Expr
    @test parse_channel_expr("A = 2MAG  # a comment", chans) == :(A = 2.0 * MAG)
    # refused forms, each with a plain message
    @test msg("A = run(`rm -rf /`)") == "run is not an allowed function. Allowed functions: " *
        "+ - * / ^ abs sqrt exp log log10 sin cos tan atan min max ifelse isnan < > <= >= == != & |."
    @test msg("A = NOPE + 1") == "There is no channel NOPE."
    @test msg("A = mag + 1") == "There is no channel mag. Did you mean MAG?"
    @test msg("A = `NOPE` + 1") == "There is no channel NOPE."
    @test msg("") == "The expression is empty."
    @test msg("A = (") == "The expression is not valid Julia: Expected `)` or `,`."
    @test msg("MAG - IGRF") == "Write the expression as OUT = <expression>, such as MAG_IGRF = MAG - IGRF."
    @test msg("A = 1\nB = 2") == "Write one expression only, such as MAG_IGRF = MAG - IGRF."
    @test msg("A = B = MAG") == "Use only one = in the expression."
    @test msg("A += 1") == "Write the expression as OUT = <expression>, such as MAG_IGRF = MAG - IGRF."
    @test msg("f(x) = x") == "The left side of = must be one channel name, such as MAG_IGRF."
    @test msg("A.b = MAG") == "The left side of = must be one channel name, such as MAG_IGRF."
    @test msg("A = MAG.x") == "Field access with . is not allowed."
    @test msg("A = Base.run(MAG)") == "Field access with . is not allowed."
    @test msg("A = @time MAG") == "Macros (names that start with @) are not allowed."
    @test msg("A = [x for x in MAG]") == "\"[\" is not allowed in a channel expression."
    @test msg("A = sum(x for x in MAG)") == "\"for\" is not allowed in a channel expression. " *
        "A channel of that name goes in backticks, such as `for`."
    @test msg("A = 1:3") == "\":\" is not allowed in a channel expression."
    @test msg("A = \"MAG\"") == "Text in quotes is not allowed."
    @test msg("A = \"\$MAG\"") == "Text in quotes is not allowed."
    @test msg("A = \$MAG") == "Interpolation with \$ is not allowed."
    @test msg("A = max(MAG; init = 0)") == "\";\" is not allowed in a channel expression."
    @test msg("A = max(MAG, init = 0)") == "Keyword arguments are not allowed."
    @test msg("A = MAG[1]") == "\"[\" is not allowed in a channel expression."
    @test msg("A = {MAG}") == "\"{\" is not allowed in a channel expression."
    @test msg("A = (MAG, IGRF)") == "Lists of values are not allowed."
    @test msg("A = :MAG") == "\":\" is not allowed in a channel expression."
    @test msg("A = true") == "true and false are not allowed. Use a comparison, such as MAG > 0."
    @test msg("A = 99999999999999999999") == "The number 99999999999999999999 is too large."
    @test msg("A = sqrt") == "sqrt is a function. Call it with values in brackets, such as sqrt(MAG)."
    @test msg("A = sqrt(MAG, IGRF)") == "sqrt takes 1 value, not 2."
    @test msg("A = ifelse(MAG > 0, MAG)") == "ifelse takes 3 values, not 2."
    @test msg("A = max(MAG)") == "max takes at least 2 values, not 1."
    @test msg("A = MAG & IGRF") == "& and | need true or false values on both sides, such as (MAG > 0) & (IGRF < 1)."
    @test msg("A = ifelse(MAG, 1, 2)") == "The first value of ifelse must be true or false, such as MAG > 0."
    @test msg("A = MAG && IGRF") == "&& is not allowed. Use & instead."
    @test msg("A = MAG || IGRF") == "|| is not allowed. Use | instead."
    @test msg("A = !isnan(MAG)") == "\"!\" is not allowed in a channel expression."
    @test msg("A = MAG ? 1 : 2") == "\"?\" is not allowed in a channel expression."
    @test msg("A = MAG % 2") == "\"%\" is not allowed in a channel expression."
    @test msg("A = √MAG") == "\"√\" is not allowed in a channel expression."
    @test msg("A = MAG #= note =#") == "Block comments #= =# are not allowed."
    @test msg("A = MAG == 1e-3 + 0x1F + .5 + 1.5E+2 + 2MAG") == ""            # numbers and juxtaposition pass
    @test msg("A = 2begin MAG end") == "\"begin\" is not allowed in a channel expression. " *
        "A channel of that name goes in backticks, such as `begin`."
    @test parse_channel_expr("A = `end` + 1", ["end"]) == Expr(:(=), :A, Expr(:call, :+, :end, 1.0))
    @test msg("A = `end(` + 1") == "There is no channel end(."             # backtick text is not scanned
    @test msg("A = false") == "true and false are not allowed. Use a comparison, such as MAG > 0."
    @test msg("A = (x -> x)(MAG)") == "Only the allowed functions can be called, by name."
    @test msg("A = begin MAG end") == "\"begin\" is not allowed in a channel expression. " *
        "A channel of that name goes in backticks, such as `begin`."
    @test msg("A = MAG'") == "\"'\" is not allowed in a channel expression."
    @test msg("A = MAG...") == "This part of the expression is not allowed: ...."
end

@testset "channel math: deep nesting is refused, never a stack overflow" begin
    deep_call = "A = " * "sqrt("^10_000 * "MAG" * ")"^10_000
    deep_brackets = "A = " * "("^100_000 * "MAG" * ")"^100_000
    msg(text) = try
        parse_channel_expr(text, ["MAG"])
        ""
    catch err
        err isa ToolError ? err.msg : rethrow()
    end
    @test msg(deep_call) == "The expression is too long: it has 60007 characters, and at most 10000 are allowed."
    @test msg(deep_brackets) == "The expression is too long: it has 200007 characters, and at most 10000 are allowed."
    @test msg("A = " * "sqrt("^201 * "MAG" * ")"^201) == "The expression has brackets nested more than 200 deep."
    @test msg("A = " * "- "^1001 * "MAG") == "The expression has more than 1000 operator characters."
    @test msg("A = " * "MAG^"^400 * "MAG") == "The expression is nested more than 200 deep."
    @test msg("A = " * "MAG-"^300 * "MAG") == "The expression is nested more than 200 deep."
    @test parse_channel_expr("A = " * "sqrt("^200 * "MAG" * ")"^200, ["MAG"]) isa Expr    # 200 deep is allowed
    @test parse_channel_expr("A = " * "("^200 * "MAG" * ")"^200, ["MAG"]) == :(A = MAG)   # plain brackets add no depth
    @test parse_channel_expr("A = " * "- "^190 * "MAG", ["MAG"]) isa Expr
    @test parse_channel_expr("A = " * join(fill("MAG", 150), " + "), ["MAG"]) isa Expr  # one flat call
    # through run_tool: a refusal, not a job, and nothing on stderr
    (; s, id) = make_db_with(MAG = [1.0])
    for text in (deep_call, deep_brackets)
        r = run_tool(s, "database.channel_math"; inputs = Dict("database" => id), expr = text, lines = "all")
        @test r isa Tuple && r[1] == false && r[3] === nothing
        @test startswith(r[2], "Expression is too long")
    end
    # keyword nesting has no brackets and no operators; it is refused before any parse
    keyword_nests = [
        "A = " * "return "^600 * "MAG" => "return",
        "A = " * "local "^1400 * "MAG" => "local",
        "A = " * "begin "^900 * "MAG" * " end"^900 => "begin",
        "A = " * "let "^1200 * "MAG" * " end"^1200 => "let",
        "A = " * "if MAG "^600 * "MAG" * " end"^600 => "if",
        "A = " * "try "^900 * "MAG" * " end"^900 => "try",
        "A = " * "quote "^900 * "MAG" * " end"^900 => "quote",
    ]
    for (text, word) in keyword_nests
        want = "\"$word\" is not allowed in a channel expression. " *
               "A channel of that name goes in backticks, such as `$word`."
        @test msg(text) == want
        @test JuliaMagCore.setting_problem(ExprSetting("e", "Expression"), text) == want
        r = run_tool(s, "database.channel_math"; inputs = Dict("database" => id), expr = text, lines = "all")
        @test r isa Tuple && r == (false, want, nothing)
    end
    # every Julia keyword is refused
    for word in ("begin", "end", "let", "if", "elseif", "else", "return", "local", "global", "const", "quote",
                 "try", "catch", "finally", "for", "while", "function", "macro", "module", "baremodule",
                 "struct", "mutable", "abstract", "primitive", "type", "do", "using", "import", "export",
                 "outer", "where", "in", "isa")
        @test startswith(msg("A = MAG + $word"), "\"$word\" is not allowed in a channel expression.")
    end
    # in a fresh process, nothing is printed on stderr: no stack overflow warning
    code = """
        using JuliaMagCore
        texts = ["A = " * "return "^600 * "MAG", "A = " * "local "^1400 * "MAG",
                 "A = " * "begin "^900 * "MAG" * " end"^900, "A = " * "let "^1200 * "MAG" * " end"^1200,
                 "A = " * "if MAG "^600 * "MAG" * " end"^600, "A = " * "try "^900 * "MAG" * " end"^900,
                 "A = " * "quote "^900 * "MAG" * " end"^900, "A = " * "sqrt("^10_000 * "MAG" * ")"^10_000,
                 "A = " * "("^100_000 * "MAG" * ")"^100_000]
        for t in texts
            try
                parse_channel_expr(t, ["MAG"])
                error("not refused")
            catch e
                e isa ToolError || rethrow()
            end
            JuliaMagCore.setting_problem(ExprSetting("e", "Expression"), t) === nothing && error("not refused")
        end
        print("refused all")
        """
    err = IOBuffer()
    out = read(pipeline(`$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`;
                        stderr = err), String)
    @test out == "refused all"
    @test isempty(String(take!(err)))
    # empty backticks
    @test msg("`` = MAG") == "The left side of = must be one channel name, such as MAG_IGRF."
    @test msg("A = `` + MAG") == "Empty backticks are not a channel name."
end

@testset "channel math: evaluation" begin
    chans = ["X", "Y"]
    ev(text; X = [4.0, -1.0, 0.0, NaN], Y = [2.0, 0.0, 0.0, 1.0]) =
        JuliaMagCore.eval_channel_expr(parse_channel_expr(text, chans),
                                       Dict(:X => X, :Y => Y), length(X))
    @test isequal(ev("A = X / Y"), [2.0, -Inf, NaN, NaN])        # division by zero as in Julia
    @test isequal(ev("A = sqrt(X)"), [2.0, NaN, 0.0, NaN])      # out of domain gives NaN, not an error
    @test isequal(ev("A = log(X)"), [log(4.0), NaN, -Inf, NaN])
    @test isequal(ev("A = log10(X)"), [log10(4.0), NaN, -Inf, NaN])
    @test isequal(ev("A = X ^ 0.5"), [2.0, NaN, 0.0, NaN])
    @test isequal(ev("A = X ^ 3"), [64.0, -1.0, 0.0, NaN])
    @test isequal(ev("A = sin(X / Y)"), [sin(2.0), NaN, NaN, NaN])  # sin(Inf) is NaN, not an error
    @test isequal(ev("A = 7"), fill(7.0, 4))
    @test isequal(ev("A = X > 0"), [1.0, 0.0, 0.0, 0.0])
    @test isequal(ev("A = ifelse(isnan(X), -99, X)"), [4.0, -1.0, 0.0, -99.0])
    @test isequal(ev("A = ifelse((X > -2) & (Y < 1), 1, 0)"), [0.0, 1.0, 1.0, 0.0])
    @test isequal(ev("A = ifelse(-2 < X <= 0, 1, 0)"), [0.0, 1.0, 1.0, 0.0])
    @test isequal(ev("A = max(X, Y, 1)"), [4.0, 1.0, 1.0, NaN])
    @test isequal(ev("A = min(X, Y)"), [2.0, -1.0, 0.0, NaN])
    @test isequal(ev("A = -X + +Y"), [-2.0, 1.0, 0.0, NaN])
    @test isequal(ev("A = atan(Y, X)"), [atan(2.0, 4.0), atan(0.0, -1.0), 0.0, NaN])
    @test isequal(ev("A = abs(X) * pi"), [4pi, pi, 0.0, NaN])
    @test isequal(ev("A = ifelse(X > 0, NaN, -Inf)"), [NaN, -Inf, -Inf, -Inf])
    @test isequal(ev("A = X"; X = Float64[], Y = Float64[]), Float64[])
    @test isequal(ev("A = 1 + 2"; X = Float64[], Y = Float64[]), Float64[])
end

@testset "channel math tool: new channel, lines, undo and redo" begin
    s, id = two_line_db()
    @test tool("database.channel_math").mode == :job
    @test tool("database.channel_math").places == [Place("Database Tools", "Channels")]
    meta = cm_meta(s, id)
    job = cm_run(s, id; expr = "D = MAG - IGRF", lines = "all")
    @test status(job) == JOB_DONE && isempty(s.busy)
    db = database(s.project, id)
    c = channel(db, "D")
    @test c.eltype == Float64 && !c.protected && c.decimals == -1 && c.arraylen == 1
    @test read_channel(db, CM_L1, "D") == [0.5, 1.5, 2.5] && read_channel(db, CM_L2, "D") == [3.0, 4.0, 5.0]
    @test occursin("D = MAG - IGRF", String(take!(copy(job.report))))
    @test last(s.undo_stack).items == [id]
    # undo removes the channel exactly; redo puts it back
    @test undo!(s)
    @test cm_meta(s, id) == meta && !isfile(cm_file(s, id, "D"))
    @test redo!(s)
    @test read_channel(database(s.project, id), CM_L2, "D") == [3.0, 4.0, 5.0]
    @test undo!(s)
    # integer channels are read as Float64, with their missing value as NaN
    @test status(cm_run(s, id; expr = "C2 = CNT * 2", lines = "all")) == JOB_DONE
    @test isequal(collect(read_channel(database(s.project, id), CM_L1, "C2")), [2.0, NaN, 6.0])
    # selected lines only: the other lines of a new channel stay missing
    set_line_selected!(s, id, CM_L1, false)
    @test status(cm_run(s, id; expr = "S = MAG + 1", lines = "selected")) == JOB_DONE
    db = database(s.project, id)
    @test all(isnan, read_channel(db, CM_L1, "S")) && read_channel(db, CM_L2, "S") == [5.0, 6.0, 7.0]
    set_line_selected!(s, id, CM_L2, false)
    job = cm_run(s, id; expr = "S2 = MAG", lines = "selected")
    @test status(job) == JOB_FAILED && job.error == "No lines are selected in database $id."
    # the current line
    job = cm_run(s, id; expr = "CUR = MAG", lines = "current")
    @test status(job) == JOB_FAILED && job.error == "No current line."
    set_cursor!(s, Cursor("db-other", CM_L1, 1))
    job = cm_run(s, id; expr = "CUR = MAG", lines = "current")
    @test status(job) == JOB_FAILED && job.error == "No current line."
    set_cursor!(s, Cursor(id, CM_L1, 2))
    @test status(cm_run(s, id; expr = "CUR = MAG", lines = "current")) == JOB_DONE
    db = database(s.project, id)
    @test read_channel(db, CM_L1, "CUR") == [1.0, 2.0, 3.0] && all(isnan, read_channel(db, CM_L2, "CUR"))
    @test isempty(cm_sides(s, id)) && isempty(s.busy)
end

@testset "channel math tool: overwrite, undo and redo are exact" begin
    s, id = two_line_db()
    db0 = database(s.project, id)
    @test read_channel(db0, CM_L1, "MAG") == [1.0, 2.0, 3.0]     # maps the file in this old view
    bytes = read(cm_file(s, id, "MAG"))
    meta = cm_meta(s, id)
    job = cm_run(s, id; expr = "MAG = MAG * 2 - IGRF", lines = "all")
    @test status(job) == JOB_DONE && isempty(s.busy)
    @test cm_meta(s, id) == meta
    @test read_channel(database(s.project, id), CM_L2, "MAG") == [7.0, 9.0, 11.0]
    @test read_channel(db0, CM_L2, "MAG") == [7.0, 9.0, 11.0]    # written in place: old views see it
    new_bytes = read(cm_file(s, id, "MAG"))
    @test undo!(s)
    @test read(cm_file(s, id, "MAG")) == bytes && cm_meta(s, id) == meta
    @test read_channel(db0, CM_L1, "MAG") == [1.0, 2.0, 3.0]
    @test redo!(s)
    @test read(cm_file(s, id, "MAG")) == new_bytes
    @test undo!(s) && read(cm_file(s, id, "MAG")) == bytes
    # a new step drops the redo data and its side folder
    @test !isempty(cm_sides(s, id))
    @test status(cm_run(s, id; expr = "MAG = MAG", lines = "all")) == JOB_DONE
    @test length(cm_sides(s, id)) == 1                       # only the new run's copy is left
    # only the chosen lines change
    set_line_selected!(s, id, CM_L1, false)
    @test status(cm_run(s, id; expr = "MAG = 0", lines = "selected")) == JOB_DONE
    db = database(s.project, id)
    @test read_channel(db, CM_L1, "MAG") == [1.0, 2.0, 3.0] && read_channel(db, CM_L2, "MAG") == [0.0, 0.0, 0.0]
end

@testset "channel math tool: refusals" begin
    s, id = two_line_db()
    meta = cm_meta(s, id)
    job = cm_run(s, id; expr = "MAGP = MAG", lines = "all")
    @test status(job) == JOB_FAILED && job.error == "Channel MAGP is protected and cannot be edited."
    job = cm_run(s, id; expr = "CNT = MAG", lines = "all")
    @test status(job) == JOB_FAILED &&
          job.error == "Channel CNT holds Int32 values. Channel Math writes only Float64 channels. Pick another output channel."
    job = cm_run(s, id; expr = "mag = MAG", lines = "all")
    @test status(job) == JOB_FAILED &&
          job.error == "Channel mag is too like channel MAG: names may not differ only in case."
    job = cm_run(s, id; expr = "`A/B` = MAG", lines = "all")
    @test status(job) == JOB_FAILED && startswith(job.error, "Channel A/B cannot be made: ")
    job = cm_run(s, id; expr = "A = NOPE", lines = "all")
    @test status(job) == JOB_FAILED && job.error == "There is no channel NOPE."
    @test cm_meta(s, id) == meta && isempty(s.busy) && isempty(s.undo_stack)
    JuliaMagCore.mark_busy!(s, id)
    job = cm_run(s, id; expr = "A = MAG", lines = "all")
    @test status(job) == JOB_FAILED && job.error == "Database $id is busy: an import is running."
    JuliaMagCore.unmark_busy!(s, id)
    # bad settings never start a job
    ok, msg, _ = run_tool(s, "database.channel_math"; inputs = Dict("database" => id), expr = "A = (", lines = "all")
    @test !ok && startswith(msg, "Expression is not a valid Julia expression")
    @test cm_meta(s, id) == meta && isempty(cm_sides(s, id))
end

@testset "channel math tool: cancel and failure leave the database as it was" begin
    s, id = two_line_db()
    ins = Dict("database" => id)
    bytes = read(cm_file(s, id, "MAG"))
    meta = cm_meta(s, id)
    # cancel after the first line was written
    cancel_second() = (n = Ref(0); JuliaMagCore.Progress(_ -> nothing, () -> (n[] += 1) > 1))
    st = Dict{String,Any}("expr" => "MAG = MAG * 10", "lines" => "all")
    @test_throws JuliaMagCore.JobCancelled JuliaMagCore.run_channel_math(s, ins, st, cancel_second(), IOBuffer())
    @test read(cm_file(s, id, "MAG")) == bytes && cm_meta(s, id) == meta
    st = Dict{String,Any}("expr" => "NEW = MAG * 10", "lines" => "all")
    @test_throws JuliaMagCore.JobCancelled JuliaMagCore.run_channel_math(s, ins, st, cancel_second(), IOBuffer())
    @test cm_meta(s, id) == meta && !isfile(cm_file(s, id, "NEW"))
    @test isempty(cm_sides(s, id)) && isempty(s.busy) && isempty(s.undo_stack)
    # a cancelled job is cancelled and changes nothing
    job = run_tool(s, "database.channel_math"; inputs = ins, expr = "MAG = MAG + 1", lines = "all")
    cancel!(job)
    wait_job(job)
    @test status(job) in (JOB_CANCELLED, JOB_DONE)
    status(job) == JOB_DONE && undo!(s)
    @test read(cm_file(s, id, "MAG")) == bytes && cm_meta(s, id) == meta && isempty(s.busy)
end

@testset "channel math: masking with NaN (R14)" begin
    (; s, id, L) = make_db_with(MAG = [50000.0, 50010.0, 50020.0], ALT = [150.0, 250.0, NaN])
    job = wait_job(run_tool(s, "database.channel_math"; inputs = Dict("database" => id),
                            expr = "MAG_M = ifelse(ALT > 200, NaN, MAG)", lines = "all"))
    @test status(job) == JOB_DONE
    @test isequal(collect(read_channel(database(s.project, id), L, "MAG_M")), [50000.0, NaN, 50020.0])
    @test parse_channel_expr("A = Inf", ["MAG"]) == Expr(:(=), :A, Inf)
    @test parse_channel_expr("A = NaN", ["NaN"]) == :(A = NaN)     # a channel named NaN wins
end

@testset "channel math replays by script" begin
    s, id = two_line_db()
    copy_folder = joinpath(mktempdir(), "copy")
    cp(s.project.folder, copy_folder)
    @test status(cm_run(s, id; expr = "D = (MAG - IGRF) / 2", lines = "all")) == JOB_DONE
    @test status(cm_run(s, id; expr = "MAG = ifelse(isnan(CNT), -1, MAG)", lines = "all")) == JOB_DONE
    text = replace(script_text(s), repr(s.project.folder) => repr(copy_folder))
    @test occursin("wait_job(run_tool(s, \"database.channel_math\"", text)
    include_string(Module(), text)
    a = database(s.project, id)
    b = database(open_project(copy_folder), id)
    for name in ("D", "MAG"), lid in (CM_L1, CM_L2)
        @test isequal(collect(read_channel(a, lid, name)), collect(read_channel(b, lid, name)))
    end
    @test read_channel(a, CM_L1, "MAG") == [1.0, -1.0, 3.0]
end
