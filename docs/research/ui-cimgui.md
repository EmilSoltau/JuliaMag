# CImGui.jl research for a desktop UI in Julia

Installed and tested in a throwaway env: /tmp/claude-1000/-home-ems-work--projects-coding-workspace--sh--Mag-processing-tool/6fff0214-f69e-4305-96ef-73fefd074d74/scratchpad/cimgui-env (depot inside it).
Scripts used: /tmp/claude-1000/-home-ems-work--projects-coding-workspace--sh--Mag-processing-tool/6fff0214-f69e-4305-96ef-73fefd074d74/scratchpad/run/min.jl, rich.jl, idle.jl, fields.jl.
Screenshot taken by the test: /tmp/claude-1000/-home-ems-work--projects-coding-workspace--sh--Mag-processing-tool/6fff0214-f69e-4305-96ef-73fefd074d74/scratchpad/run/shot.png.
Source paths below are under /tmp/claude-1000/-home-ems-work--projects-coding-workspace--sh--Mag-processing-tool/6fff0214-f69e-4305-96ef-73fefd074d74/scratchpad/cimgui-env/depot/packages/CImGui/88gqf (call it CIMGUI).

## 1. Version, docking, backend, minimal example

Latest CImGui.jl is v10.1.0 (2026-10-22), see CIMGUI/Project.toml:3 and CIMGUI/docs/src/_changelog.md:10.
It wraps Dear ImGui 1.93.0 plus a newer docking-branch commit; imgui_version() returned v"1.93.1-WIP" here (_changelog.md:15-21).
The docking branch IS included: DockSpace, DockSpaceOverViewport, DockBuilder* exist in CIMGUI/src/wrapper.jl:3038-3055 and :13536, and ImGuiConfigFlags_DockingEnable and ViewportsEnable are defined.
Docking was run here: DockSpaceOverViewport() with two windows worked.
The JLL is CImGuiPack_jll 0.14, built with FreeType and wide characters since v9.0.0 (_changelog.md:41-44).
Only one backend exists: GLFW + OpenGL3 (CIMGUI/docs/src/backends.md:7-10; CIMGUI/src/CImGui.jl:~211 set_backend).
It lives in a package extension: CIMGUI/ext/GlfwOpenGLBackend.jl, triggered when GLFW and ModernGL are loaded (Project.toml extensions block).
No SDL, no Vulkan, no wgpu backend.
Registry packages found: CImGui 10.1.0, ImGuiTestEngine 3.0.0, ImPlot 0.8.2 (compat CImGui 10), ImPlot3D (compat CImGui 8 only, so stale).
Render API: ig.render(ui, ctx; hotloading, on_exit, clear_color, window_size, window_title, engine, opengl_version, wait_events, vsync, fps_limit, spawn, wait) (CIMGUI/src/CImGui.jl:183-253).
The loop is built in (ext/GlfwOpenGLBackend.jl:94-250); no manual loop is needed.
Return :imgui_exit_loop from ui() to quit.
Default OpenGL is 3.2; GLMakie needs 3.3.

Minimal example (ran here, worked):

    using CImGui, GLFW, ModernGL
    import CImGui as ig
    ig.set_backend(:GlfwOpenGL3)
    ctx = ig.CreateContext()
    ig.render(ctx; window_title="min") do
        ig.Begin("Hello"); ig.Text("hi"); ig.End()
        nothing   # return :imgui_exit_loop to quit
    end

Pointer-style access: io = ig.GetIO() is a Ptr, use unsafe_load(io.ConfigFlags), and style = Ptr{ig.lib.ImGuiStyle}(ig.GetStyle()).
Property assignment on Ptr works (style.WindowRounding = 6f0).
The loop has a hot-reload hook: with hotloading=true it calls ui via @invokelatest (Revise-friendly).
The loop calls ig.DestroyContext(ctx) at exit, so make a new context for each render call.

## 2. Makie integration

Yes.
Extension CIMGUI/ext/MakieIntegration.jl, triggered by GLFW + ModernGL + GLMakie (GLMakie compat 0.13; registry has GLMakie 0.13.16).
API: ig.MakieFigure("id", fig::GLMakie.Figure; auto_resize_x=true, auto_resize_y=false, tooltip=true, stats=false) (CIMGUI/src/CImGui.jl:104-142).
How it works: a custom ImMakieWindow is wrapped in a GLMakie.Screen; GLMakie renders into an offscreen framebuffer; the colour texture is shown as an ImGui image; mouse events are forwarded to Makie only while hovered (ext/MakieIntegration.jl:1-75).
Interaction works: scroll zoom, drag-rectangle zoom, right-drag pan, ctrl+click reset.
Docs call it "very experimental" and not covered by semver (docs/src/makie.md:6-10).
Known limits from the docstring:
- Drag leaving the figure keeps stale mouse state.
- Scroll zoom also scrolls the ImGui window.
- Segfaults after zooming far when a window was opened several times in one process.
- Pass opengl_version=v"3.3" or shaders fail.
Thread rule (docs/src/makie.md:21-30): no ImGui call and no Figure update (including Observables) from other threads; build Figures on any thread.
Open issues: #191 GLMakie scalefactor wrong (HiDPI), #148 theming Makie plots gives artefacts, #154 no way to delete a figure from makie_context.
Example: CIMGUI/examples/makie_demo.jl.
Not tested here (GLMakie is a very large install).
Alternative for plots: ImPlot.jl (native ImGui plotting, GPU-light, no Makie). It is registered and compatible with CImGui 10.
Another: draw yourself via ImDrawList (AddPolyline, AddRectFilled) or upload a texture with ig.ImTextureRef helpers (_create_image_texture, ext:34-60).

## 3. Fonts and DPI

Load TTF: fonts = unsafe_load(ig.GetIO().Fonts); ig.AddFontFromFileTTF(fonts, path, 16) (CIMGUI/examples/demo.jl:41-49). Returns Ptr{ImFont} (C_NULL on failure).
Verified here: Roboto-Medium.ttf then merge DroidSans.ttf worked using cfg = ig.lib.ImFontConfig_ImFontConfig(); cfg.MergeMode = true; ig.AddFontFromFileTTF(fonts, path2, 16, cfg).
Icon font merge uses the same path: add the text font, then the icon TTF with MergeMode=true and a glyph range (the C_NULL range arg takes a Ptr{ImWchar} array; keep that array alive). Phosphor/Lucide were NOT tested (not installed). Their PUA code points need glyph_ranges, or in 1.92+ with dynamic fonts the glyphs load on demand so ranges are mostly not needed.
ImFontConfig fields available: MergeMode, OversampleH/V, GlyphOffset, GlyphMinAdvanceX, RasterizerMultiply, RasterizerDensity, SizePixels, FontLoader, FontLoaderFlags.
Dear ImGui 1.92+ model: font size is dynamic. style.FontSizeBase, style.FontScaleMain, style.FontScaleDpi exist; ig.PushFont(font, size) takes a size.
Fonts are rasterised on demand at the size used, so re-scaling for DPI does not need a rebuilt atlas.
io.ConfigDpiScaleFonts and io.ConfigDpiScaleViewports exist (Fields printed by fields.jl).
The GLFW backend functions ImGui_ImplGlfw_GetContentScaleForWindow / ForMonitor are exported in lib.
CImGui.jl does not set DPI scale for you. Plan: scale = GLFW.GetWindowContentScale(ig.current_window()); set style.FontScaleDpi = scale and call ScaleAllSizes(style, scale) once, or set io.ConfigDpiScaleFonts = true. Test here: content scale 1.0, framebuffer 1280x720, so the high DPI path was NOT exercised. Needs a test on a real Windows HiDPI screen.
Crisp text: JLL has FreeType (v9.0.0 changelog). FreeType loader is in lib (ImGuiFreeType_GetFontLoader). Dear ImGui's default atlas oversampling gives acceptable text. In the screenshot Roboto 16 looked clean.
Bundled fonts: CIMGUI/fonts (Cousine, DroidSans, Karla, Roboto-Medium, Recursive, Proggy). Roboto and Inter style fonts look closest to egui's default.
Emoji: colour glyphs possible since v9.0.0 with FreeType.

## 4. Styling

ImGuiStyle fields (printed from the installed lib): Alpha, WindowPadding, WindowRounding, WindowBorderSize, ChildRounding, PopupRounding, FramePadding, FrameRounding, FrameBorderSize, ItemSpacing, ItemInnerSpacing, CellPadding, IndentSpacing, ScrollbarSize, ScrollbarRounding, GrabMinSize, GrabRounding, TabRounding, TabBarBorderSize, SeparatorTextBorderSize, SelectableRounding, ButtonTextAlign, Docking* and Colors (array of ImVec4 indexed by ImGuiCol_*).
Set at runtime (verified):
    style = Ptr{ig.lib.ImGuiStyle}(ig.GetStyle())
    style.WindowRounding = 6f0; style.FrameRounding = 4f0; style.FramePadding = ig.ImVec2(8,5)
    ig.c_set!(style.Colors, ig.ImGuiCol_Button, ig.ImVec4(0.1,0.5,0.9,1))
    ig.c_get(style.Colors, ig.ImGuiCol_Button)
Presets: ig.StyleColorsDark(), StyleColorsLight(), StyleColorsClassic().
Theme switch: keep a Dict of theme => (colours, rounding, padding) and re-apply in the ui function when the theme changes. The style is plain memory, changes take effect next frame.
Scoped overrides: ig.PushStyleColor / PushStyleVar (examples/app_property_editor.jl:51).
Verified in the screenshot: the blue button colour and rounding applied.

## 5. Testing

Dear ImGui Test Engine: yes, as a sub-package inside the repo, registered as ImGuiTestEngine.jl v3.0.0 (CIMGUI/ImGuiTestEngine.jl/Project.toml, compat CImGui 10). Pass engine = te.CreateContext() to ig.render(...; engine). Use @register_test and @imcheck, ItemClick, MenuClick, SetRef etc. (CIMGUI/test/runtests.jl:100-200).
Test run is driven inside a real window; exit_on_completion=true ends the loop.
CImGui.jl's own tests use this, plus renderloop tests for threads, vsync and fps_limit (runtests.jl:1-90). CI needs a display (not checked how upstream provides it).
Screenshots: the test engine capture tool needs io.ScreenCaptureFunc, which CImGui.jl does NOT install (ImGuiTestEngine.jl/src/engine.jl:171-195 warns "capture skipped"). So use your own capture.
Own capture verified here: inside ui(), at frame 30, GL.glReadPixels(0,0,w,h,GL_RGBA,GL_UNSIGNED_BYTE,buf) before swap (reads the back buffer) gave a valid 1280x720 image. I wrote PPM and converted to PNG with PIL. The image shows docked windows, Roboto text, blue rounded button. (Note: the capture happens inside the ui callback, so it shows the previous frame content; capture after ig.Render + RenderDrawData needs a custom loop or one extra frame.)
Headless: Xvfb is NOT installed here, so xvfb was not tested. WSLg works (DISPLAY=:0, GL renderer "D3D12 (Intel(R) UHD Graphics 770)", via Mesa). Xvfb or OSMesa would need llvmpipe GL 3.2+; ImGui needs only 3.2, so it should work. Untested.
Recommended test layers: (a) logic tests with no GUI; (b) test-engine scripts in a window; (c) glReadPixels golden-image checks with tolerance.
Raw ImGui can also run with no window: create context, build font atlas, NewFrame, Render, then inspect ImDrawData (vertex counts). Not tried.

## 6. Idle and frame timing (measured, 3 s each)

- Default loop (PollEvents, vsync=true): 575 frames in 3 s, 0.85 s CPU (28 percent of a core). WSLg did not honour vsync, so a real GPU will differ.
- fps_limit=30: 96 frames, 0.18 s CPU (6 percent).
- wait_events=true (GLFW.WaitEvents): 25 frames in 3.7 s, 0.04 s CPU (about 1 percent). This is true idle.
Gotcha (issue JuliaImGui/CImGui.jl#186): WaitEvents blocks thread 1, including the Julia libuv loop. A Julia sleep()/Timer or async task cannot wake it, since they need thread 1. Waking with GLFW.PostEmptyEvent() worked here only from a task on another thread that does not need thread 1 (I used ccall usleep in Threads.@spawn; plain sleep() deadlocked and had to be killed by timeout).
Plan: with wait_events=true, run worker threads that call GLFW.PostEmptyEvent() when a job finishes or a redraw is needed (use a Threads.Condition-free approach, e.g. a ccall-based wait or a channel read from a spawned thread, since libuv timers will not fire).
Alternative: a fixed low fps_limit (e.g. 30) while jobs run, and wait_events when idle. The loop in the extension takes only static arguments, so this needs a custom loop copy (the extension is 150 lines and easy to copy) or wait_events with a heartbeat thread.
ImGui itself also needs one or two extra frames after input (menus, tooltips animate), so post an empty event a few times after each action.

## 7. Startup time (measured, Julia 1.12.7, 32 cores, WSLg)

Precompile of CImGui + GLFW + ModernGL + the extension: about 20 s once (52 deps), plus about 100 s total for first install and artifact download.
Per run after precompile: using = 0.19-0.21 s; first frame = 0.43-0.61 s after that; total process wall 1.5-1.8 s including exit.
So time-to-first-frame is about 0.6-0.8 s from the Julia prompt. PackageCompiler is not needed for startup.
The extension ships a PrecompileTools workload (ext/GlfwOpenGLBackend.jl, last block) that opens a window at precompile time; CImGui's test env turns it off (CIMGUI/test/LocalPreferences.toml).
Your own app code (first call of each widget closure, and any Makie) will add compile time. GLMakie first plot is the slow part (not measured).
PackageCompiler caveat: issue #68 (compiled app showed no or faded GUI on Windows, 2022, 14 comments, unresolved in the listing). Treat sysimage/app builds as something to test early.

## 8. Threads

- Default spawn=1: the render loop runs pinned to thread 1 (CIMGUI/src/CImGui.jl:218-236). GLFW wants the main thread. spawn=true picks the last thread of the interactive pool; the docs say only thread 1 is sure to be portable (macOS needs the main thread; Windows needs a consistent thread).
- ImGui calls only from the render thread (docs/src/makie.md:21-30).
- Verified here: julia -t 4,1, render on thread 1 while Threads.@spawn ran a 10^8 loop; the UI kept running and the job result was read from the ui callback via a plain Ref (done=true seen).
- Use Channel or Threads.Atomic for results; read them in ui().
- The loop enters a GC-safe region around PollEvents/WaitEvents/SwapBuffers when no GLFW callbacks are set, so GC in worker threads does not stall (ext:122-143). Do not register GLFW callbacks if you want that.
- The extension disables GLFW thread assertions (GLFW.jl >= 3.4.4) and leaves safety to you.
- Thread 1 also runs libuv: a render loop that never yields starves timers and IO tasks on thread 1. The loop calls yield() each frame. Put jobs on :default threads started with -t N,1 (or JULIA_NUM_THREADS=auto,1).
- Tests for thread pinning exist in CIMGUI/test/runtests.jl:9-58.

## 9. Known problems, Windows and others

- Issue #188 (Nov 2025): random hard crash (EXCEPTION_ACCESS_VIOLATION in ImGui::SetNavFocusScope in libcimgui.dll) on Windows and macOS, Julia 1.12.0 with a custom render loop. Not solved in the thread.
- Issue #191 (2026): GLMakie scale factor wrong, HiDPI.
- Issue #186: WaitEvents wake-up (see section 6).
- Issue #68: PackageCompiler app shows blank or faded window on Windows.
- Issue #149: "Error in CImGui GlfwOpenGL3 renderloop!" open since 2024.
- Issue #205: julia_demo example slightly broken (2026).
- No Windows machine was available here; Windows HiDPI, DPI-awareness manifest, and OpenGL driver issues are untested. Intel iGPU and old drivers on Windows may lack GL 3.3 (needed for GLMakie).
- ImGui is immediate-mode and has no native menus or file dialogs; you need a separate file-dialog (e.g. NativeFileDialog.jl) or ImGui-based one.
- Text input: IME and non-Latin input is limited. Clipboard works through GLFW.
- Accessibility: none. Window decorations come from GLFW (native), not egui-like custom ones.
- Only OpenGL: no Vulkan/DX backends.
- WSLg note: framebuffer was the D3D12 Mesa driver; works fine.

## Summary (15 lines)

1. CImGui.jl 10.1.0 wraps Dear ImGui 1.93.1-WIP docking branch; docking works (verified).
2. One backend: GLFW + OpenGL3, via extension when GLFW and ModernGL are loaded; ig.render(ctx; ...) do ... end is the whole loop.
3. Minimal example ran here: window opened, 120 frames, exit clean (GL renderer D3D12 on WSLg).
4. Time to first frame is about 0.6-0.8 s after precompile (using 0.2 s); PackageCompiler not needed.
5. Makie: ig.MakieFigure exists (GLMakie >= 0.13), marked very experimental; use ImPlot.jl as safer plot option (not tested).
6. Fonts: AddFontFromFileTTF plus MergeMode config works (verified); dynamic font sizes in 1.92+; FreeType is built in; icon fonts untested.
7. DPI is manual: read GLFW.GetWindowContentScale, set style.FontScaleDpi or io.ConfigDpiScaleFonts; HiDPI untested here.
8. Styling is plain memory: style.WindowRounding, FramePadding, c_set!(style.Colors, ImGuiCol_*, ImVec4) verified; themes are a Dict re-applied at runtime.
9. Test engine exists (ImGuiTestEngine.jl 3.0.0) and drives a real window; its own screenshot hook is not wired, but glReadPixels to PNG worked.
10. No Xvfb here, so headless was untested; WSLg works.
11. Idle: wait_events=true gives about 1 percent CPU; default polling 28 percent; fps_limit=30 gives 6 percent.
12. Gotcha: WaitEvents blocks thread 1 and libuv; wake it with GLFW.PostEmptyEvent from a worker thread that does not use sleep()/timers on thread 1.
13. Threads: run with -t N,1, render on thread 1, workers via Threads.@spawn, share results through Ref/Channel, never call ImGui off the render thread (verified).
14. Windows risks: issue #188 random crash (1.12.0), #68 PackageCompiler blank window, #191 HiDPI with Makie; no Windows test done.
15. Overall: workable for an egui-like tool UI; plan for a custom render loop copy (150 lines) to control idle, DPI, and screenshots.
