using Test
import JuliaMagCore as Core
using JuliaMagUI: Camera, MapViewState, MapImage, MapMode, MAP_GL, MAP_CPU, choose_mode, should_transform, image_rect,
    render_item, set_map_drawing!, build_scene!, render_cpu!, fit_extent, spare_free, update_layers!, submit!,
    start_cpu_frame!, frame_scene!, cpu_uses, set_session!, load_config, LineDraw, GridDraw, Scene, FRAME_BUDGET

# Run `f(s)` on the worker, then wait for the snapshot and the layer loads it starts.
function edit_and_load!(app, f)
    submit!(app, "edit", f)
    wait_drained(app)
    refresh_now!(app)
    wait_layers(app)
    return nothing
end

# Drain the results until the CPU frame in flight has come back.
function wait_cpu_frame(app; timeout = 20)
    r = app.map.renderer
    deadline = time() + timeout
    while r.cpu_task !== nothing
        time() > deadline && error("the CPU frame did not come back within $timeout s")
        UI.drain!(app)
        timedwait(() -> isready(app.queue.results), 0.05; pollint = 0.002)
    end
    return nothing
end

# The first `w * h` pixels of a CPU frame's buffer, its rows bottom first, as `render_cpu!` lays them out.
function frame_pixels(buf::Matrix{UInt32}, w, h)
    img = Matrix{UInt32}(undef, w, h)
    for y in 1:h, x in 1:w
        img[x, y] = buf[(h-y)*w+x]
    end
    return img
end

plan_alloc(r, st) = (UI.plan_frame!(r, st, 800, 600, "m"); @allocated UI.plan_frame!(r, st, 800, 600, "m"))
image_rect_alloc(img, cam) = (image_rect(img, cam, 800, 600); @allocated image_rect(img, cam, 800, 600))

@testset "map frame" begin
    @testset "renderer choice and adaptive frames" begin
        @test choose_mode("auto", "") == MAP_GL && choose_mode("auto", "no FBO") == MAP_CPU
        @test choose_mode("cpu", "") == MAP_CPU && choose_mode("gpu", "no R32F") == MAP_CPU
        @test choose_mode("gpu", "") == MAP_GL
        @test should_transform(true, 0.030) && !should_transform(true, 0.010) && !should_transform(false, 0.5)
        @test !should_transform(true, FRAME_BUDGET)
        img = MapImage(UInt32(1), Camera(0.0, 0.0, 1.0), (800, 600), UInt64(0), 0.05)
        @test image_rect(img, Camera(-10.0, 0.0, 1.0), 800, 600) == (10f0, 0f0, 810f0, 600f0)
        @test image_rect(img, Camera(0.0, 0.0, 0.5), 800, 600) == (-400f0, -300f0, 1200f0, 900f0)
        # The same camera and size: exactly the view, also at a res with no exact binary form.
        img2 = MapImage(UInt32(1), Camera(500_123.4, 7_012_345.6, 0.1), (1183, 761), UInt64(0), 0.05)
        @test image_rect(img2, img2.camera, 1183, 761) == (0f0, 0f0, 1183f0, 761f0)
        # A smaller view: the image keeps its size, centred.
        @test image_rect(img, Camera(0.0, 0.0, 1.0), 600, 400) == (-100f0, -100f0, 700f0, 500f0)
        # North is up: a camera moved north shows the image lower.
        @test image_rect(img, Camera(0.0, 5.0, 1.0), 800, 600) == (0f0, 5f0, 800f0, 605f0)
        @test image_rect_alloc(img, Camera(3.0, 4.0, 0.7)) == 0
        # The plan of a frame: a moving view with a slow picture moves the picture.
        r = UI.MapRenderer()
        r.image = MapImage(UInt32(1), Camera(0.0, 0.0, 1.0), (800, 600), UInt64(7), 0.05, "m")
        st = MapViewState(Camera(-10.0, 0.0, 1.0))
        r.gl = UI.GlMap()                                   # made, no GL calls
        @test UI.plan_frame!(r, st, 800, 600, "m") == (0f0, 0f0, 800f0, 600f0) && r.full   # GL draws now
        st.gesture = :pan
        @test UI.plan_frame!(r, st, 800, 600, "m") == (10f0, 0f0, 810f0, 600f0) && !r.full
        r.image.cost = 0.005
        @test UI.plan_frame!(r, st, 800, 600, "m") == (0f0, 0f0, 800f0, 600f0) && r.full
        r.mode = MAP_CPU                                    # the CPU picture comes later: it moves meanwhile
        @test UI.plan_frame!(r, st, 800, 600, "m") == (10f0, 0f0, 810f0, 600f0) && r.full
        @test UI.plan_frame!(r, st, 800, 600, "other map") === nothing
        r.mode = MAP_GL
        r.handover = true                                   # a CPU picture: GL waits for its uploads
        @test UI.plan_frame!(r, st, 800, 600, "m") == (0f0, 0f0, 800f0, 600f0) && r.full   # none wait
        r.gl = nothing                                      # not made yet: not ready
        @test UI.plan_frame!(r, st, 800, 600, "m") == (10f0, 0f0, 810f0, 600f0) && !r.full
        r.image.cost = 0.05
        @test plan_alloc(r, st) == 0
        # A GL frame with no GL objects yet cannot draw: the picture stays where it is.
        r.handover = false
        r.image.cost = 0.005
        @test UI.plan_frame!(r, st, 800, 600, "m") == (10f0, 0f0, 810f0, 600f0) && r.full

        # A CPU picture uploaded in the pass is swapped in by the next view: texture and camera together.
        r.mode = MAP_CPU
        r.back_texture, r.back_size = UInt32(5), (40, 30)
        r.texture_size = (800, 600)
        r.ready = UI.CpuFrameDone(UInt64(9), Matrix{UInt32}(undef, 0, 0), 0.02, Camera(1.0, 2.0, 3.0), (40, 30), "m", 0, nothing)
        UI.take_cpu_frame!(r)
        @test r.ready === nothing && r.image.texture == 5 && r.back_texture == 1 && r.texture_size == (40, 30)
        @test r.back_size == (800, 600) && r.image.key == 9 && r.image.camera == Camera(1.0, 2.0, 3.0)
        @test r.image.size == (40, 30) && r.image.cost == 0.02
    end

    @testset "the status bar render item" begin
        @test render_item(false, MAP_GL, "") == ("GPU", "The graphics card draws the maps.")
        @test render_item(true, MAP_GL, "") == ("Software", "Software rendering: the graphics card is not used.")
        @test render_item(false, MAP_CPU, "") == ("CPU map", "The CPU draws the maps, as Map Drawing is set to CPU.")
        @test render_item(true, MAP_CPU, "The framebuffer for the map is not complete.") ==
              ("CPU map", "The CPU draws the maps. The framebuffer for the map is not complete.")
        with_app(test_app_state(nothing)) do app
            @test UI.status_texts(app).render == "GPU"          # no window: no renderer name
            app.config.map_drawing = "cpu"
            @test UI.status_texts(app).render == "CPU map"
            app.config.map_drawing = "auto"
            app.map.renderer.gl_problem = "No R32F textures."
            st = UI.status_texts(app)
            @test st.render == "CPU map" && occursin("No R32F textures.", st.render_help)
        end
    end

    @testset "Map Drawing: the setting, its commands and its toggles" begin
        with_app(test_app_state(nothing)) do app
            @test app.config.map_drawing == "auto"
            checked(id) = UI.find_command(app, id).checked(app)
            @test checked("settings.map_auto") && !checked("settings.map_gpu") && !checked("settings.map_cpu")
            @test UI.find_command(app, "settings.map_cpu").name == "Map Drawing: CPU"
            @test UI.find_command(app, "settings.map_gpu").name == "Map Drawing: Graphics Card"
            @test UI.find_command(app, "settings.map_auto").name == "Map Drawing: Auto"
            UI.run_command!(app, "settings.map_cpu")
            @test app.config.map_drawing == "cpu" && checked("settings.map_cpu") && !checked("settings.map_auto")
            set_map_drawing!(app, "gpu")
            @test app.config.map_drawing == "gpu"
            @test_throws ArgumentError set_map_drawing!(app, "fast")
            wait_drained(app)
            @test load_config(app.config_dir)[1].map_drawing == "gpu"
        end
    end

    @testset "a CPU frame draws a copy of the scene" begin
        s = fresh_session(); db = survey_database!(s); g = add_test_grid!(s, Float32[i + j for i in 1:30, j in 1:20])
        m = Core.new_map!(s); Core.add_layer!(s, m, g); Core.add_layer!(s, m, db)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m
            wait_layers(app)
            ms = app.map; r = ms.renderer
            mv = app.snap.maps[m]
            st = get!(MapViewState, ms.views, m)
            st.camera = fit_extent(UI.map_extent(app, mv), 160, 120)
            sc = build_scene!(ms.scene, app, mv, st, 160, 120)
            fs = frame_scene!(r, sc)
            @test fs !== sc && fs.key == sc.key && fs.camera == sc.camera && length(fs.layers) == 2
            @test all(fs.layers[k] !== sc.layers[k] && fs.layers[k].data === sc.layers[k].data for k in 1:2)
            @test all(fs.layers[k].lut !== sc.layers[k].lut && fs.layers[k].lut == sc.layers[k].lut for k in 1:2)
            want = render_cpu!(Matrix{UInt32}(undef, 160, 120), sc)
            # The render thread changes the draws the scene was built from: the copy keeps its own.
            sc.layers[1].lo = -1f6
            fill!(sc.layers[2].lut, 0x00)
            st.camera = Camera(st.camera.cx + 50, st.camera.cy, st.camera.res)
            @test render_cpu!(Matrix{UInt32}(undef, 160, 120), fs) == want
            build_scene!(ms.scene, app, mv, st, 160, 120)   # the look-up tables of the looks again
        end
    end

    @testset "a spare an in-flight CPU frame draws from is not built into" begin
        s = fresh_session(); db = survey_database!(s); m = Core.new_map!(s); Core.add_layer!(s, m, db)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m
            wait_layers(app)
            ms = app.map; r = ms.renderer
            mv = app.snap.maps[m]
            e = only(values(ms.entries))
            a = e.data
            st = get!(MapViewState, ms.views, m)
            st.camera = fit_extent(a.extent, 200, 150)
            sc = build_scene!(ms.scene, app, mv, st, 200, 150)
            key = sc.key
            want = render_cpu!(Matrix{UInt32}(undef, 200, 150), sc)
            hold = Channel{Nothing}(1)
            r.cpu_hold = hold                                   # the frame waits for a put!
            start_cpu_frame!(app, r, sc, m)
            @test r.cpu_task !== nothing && cpu_uses(r, a)
            cell!(v) = edit_and_load!(app, s -> Core.set_cell!(s, db, Core.LineId(Core.LINE, 1001, 0), "MAG", 1, v))
            cell!(9.0)                                          # a reload: `a` becomes the spare
            @test e.spare === a && e.data !== a && !spare_free(ms, e)
            submit!(app, "edit", s -> Core.set_cell!(s, db, Core.LineId(Core.LINE, 1001, 0), "MAG", 1, 8.0))
            wait_drained(app)
            refresh_now!(app)
            for _ in 1:5
                update_layers!(app)
            end
            @test !e.loading && e.revision < app.snap.item_revisions[db] && e.spare === a   # no load into `a`
            build_scene!(ms.scene, app, mv, st, 200, 150)       # the render thread goes on meanwhile
            put!(hold, nothing)
            wait_cpu_frame(app)
            done = r.done
            @test done !== nothing && done.key == key && done.size == (200, 150) && done.seconds >= 0
            @test frame_pixels(done.buffer, 200, 150) == want   # not torn by the reload
            @test !cpu_uses(r, a) && spare_free(ms, e)
            wait_layers(app)
            @test e.revision == app.snap.item_revisions[db] && e.data.points.value[1] == 8f0
            r.cpu_hold = nothing
        end
    end

    @testset "CPU frames take the two buffers in turn and a frame of the old project is dropped" begin
        s = fresh_session(); db = survey_database!(s); m = Core.new_map!(s); Core.add_layer!(s, m, db)
        with_app(test_app_state(s)) do app
            refresh_now!(app); app.ui.current_map = m
            wait_layers(app)
            ms = app.map; r = ms.renderer
            mv = app.snap.maps[m]
            st = get!(MapViewState, ms.views, m)
            st.camera = fit_extent(UI.map_extent(app, mv), 64, 48)
            sc = build_scene!(ms.scene, app, mv, st, 64, 48)
            start_cpu_frame!(app, r, sc, m)
            wait_cpu_frame(app)
            first_buf = r.done.buffer
            r.done = nothing
            start_cpu_frame!(app, r, sc, m)
            wait_cpu_frame(app)
            @test r.done.buffer !== first_buf
            r.done = nothing
            start_cpu_frame!(app, r, sc, m)
            wait_cpu_frame(app)
            @test r.done.buffer === first_buf                   # reused, not made again
            r.done = nothing
            hold = Channel{Nothing}(1)
            r.cpu_hold = hold
            start_cpu_frame!(app, r, sc, m)
            set_session!(app, nothing)
            put!(hold, nothing)
            wait_cpu_frame(app)
            @test r.done === nothing && r.image.key == 0
            r.cpu_hold = nothing
        end
        isopen(s) && Core.close_session!(s)
    end
end
