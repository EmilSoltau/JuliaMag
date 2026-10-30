# Compile the startup path ahead of time, so the first frame comes fast.
# It opens no window, so it also works on a machine without a display.

@setup_workload begin
    @compile_workload begin
        # One frame without a window: style, fonts and the empty app.
        ctx = ig.CreateContext()
        try
            io = ig.GetIO()
            io.DisplaySize = ig.ImVec2(800, 600)
            io.IniFilename = C_NULL
            io.BackendFlags = unsafe_load(io.BackendFlags) | lib.ImGuiBackendFlags_RendererHasTextures
            w = Window(GLFW.Window(C_NULL), ctx, LIGHT, 1f0, true, (900, 560), 0,
                Threads.Atomic{Bool}(false), 0.0, 0, false, nothing)
            apply_style!(LIGHT, 1f0)
            load_fonts!(w, :bundled)
            for _ in 1:2
                ig.NewFrame()
                AppFrame(nothing)(w)
                ig.Render()
            end
        finally
            forget_fonts!(ctx)
            ig.DestroyContext(ctx)
        end
        mktempdir() do dir
            save_config(AppConfig(), dir)
            load_config(dir)
        end
        find_system_fonts(String[])
        # The window code itself needs a display to run, so it is only compiled.
        precompile(open_and_run, (Any, String, NTuple{2,Int}, NTuple{2,Int}, Float32, Symbol,
            Any, Any, Tokens, Bool))
        precompile(main, ())
    end
end
