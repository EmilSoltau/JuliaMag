# Compile the startup path ahead of time, so the first frame comes fast.
# It opens no window, so it also works on a machine without a display.

@setup_workload begin
    @compile_workload begin
        # One frame without a window: style, fonts, the app state and the empty app.
        ctx = ig.CreateContext()
        app = AppState(AppConfig(), LIGHT)
        try
            io = ig.GetIO()
            io.DisplaySize = ig.ImVec2(800, 600)
            io.IniFilename = C_NULL
            io.BackendFlags = unsafe_load(io.BackendFlags) | lib.ImGuiBackendFlags_RendererHasTextures
            w = Window(GLFW.Window(C_NULL), ctx, LIGHT, 1f0, true, 1f0, (900, 560), 0,
                Threads.Atomic{Bool}(false), 0.0, 0, false, nothing, "")
            apply_style!(LIGHT, 1f0)
            load_fonts!(w, :bundled)
            # A tool dialog, so the first one the user opens draws at once.
            spec = Core.find_tool("database.statistics")
            spec === nothing || push_dialog!(app, ToolDialog(app,
                build_form(app, spec, Core.default_settings(spec), nothing)))
            open_right_pane!(app, :tools)   # the Tools pane, and the command search over the dialog
            for k in 1:3
                k == 2 && open_search!(app)
                k == 3 && (app.ui.left_tab = :jobs)   # the Jobs tab too
                ig.NewFrame()
                AppFrame(app, nothing)(w)
                ig.Render()
            end
        finally
            app.window = nothing
            stop_worker!(app.queue)
            forget_fonts!(ctx)
            ig.DestroyContext(ctx)
        end
        mktempdir() do dir
            save_config(AppConfig(), dir)
            load_config(dir)
        end
        find_system_fonts(String[])
        build_icon_atlas(LIGHT, 1f0)   # Rsvg and Cairo; the upload needs a window
        # The window code itself needs a display to run, so it is only compiled.
        precompile(open_and_run, (Any, String, NTuple{2,Int}, NTuple{2,Int}, Float32, Symbol,
            Any, Any, Tokens, Bool))
        precompile(main, ())
        precompile(update_icons!, (Window,))
        precompile(draw_icon, (Ptr{lib.ImDrawList}, String, NTuple{2,Float32}, Int))
    end
end
