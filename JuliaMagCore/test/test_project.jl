using JuliaMagCore

@testset "project" begin
    mktempdir() do tmp
        folder = joinpath(tmp, "coding-workspace (sh)", "Mag survey Å")   # Review Focus 2
        p = create_project(folder, "KH")
        id = new_item_id(p, ITEM_DATABASE)
        create_database(joinpath(folder, "databases", "kh"), "kh")
        add_item!(p, ProjectItem(id, ITEM_DATABASE, "kh", "databases/kh", "", ""))
        save_project(p)
        moved = joinpath(tmp, "moved project")
        mv(folder, moved)
        q = open_project(moved)
        @test item(q, id).name == "kh" && !item_missing(q, item(q, id))
        @test database(q, id) isa LineDatabase
        rm(joinpath(moved, "databases", "kh"); recursive = true)
        @test item_missing(open_project(moved), item(q, id))
        @test_throws ProjectError database(open_project(moved), id)
    end

    @testset "layout, ids, settings, errors" begin
        mktempdir() do tmp
            p = create_project(joinpath(tmp, "p"), "P")
            for d in ("databases", "grids", "jobs", "templates")
                @test isdir(joinpath(p.folder, d))
            end
            @test isfile(joinpath(p.folder, "project.jmag.json"))
            @test new_item_id(p, ITEM_DATABASE) == "db-1"
            @test new_item_id(p, ITEM_GRID) == "grid-1"
            @test new_item_id(p, ITEM_MAP) == "map-1"
            add_item!(p, ProjectItem("db-1", ITEM_DATABASE, "a", "databases/a", "d", "me"))
            add_item!(p, ProjectItem("grid-1", ITEM_GRID, "g", "grids/g", "", ""))
            @test new_item_id(p, ITEM_DATABASE) == "db-2"
            @test_throws ProjectError add_item!(p, ProjectItem("db-1", ITEM_DATABASE, "b", "x", "", ""))
            @test_throws ProjectError item(p, "nope")
            @test_throws ProjectError database(p, "grid-1")
            @test_throws ProjectError database(p, "db-1")   # folder missing
            p.settings["crs"] = Dict("epsg" => 32633, "names" => ["a", "b"])
            save_project(p)
            q = open_project(p.folder)
            @test q.settings["crs"]["epsg"] == 32633 && q.settings["crs"]["names"] == ["a", "b"]
            @test q.settings["crs"] isa Dict{String,Any}
            @test [i.kind for i in q.items] == [ITEM_DATABASE, ITEM_GRID]
            @test item(q, "db-1").description == "d" && item(q, "db-1").made_by == "me"
            r = remove_item!(q, "db-1")
            @test r.id == "db-1" && length(q.items) == 1
            @test_throws ProjectError remove_item!(q, "db-1")
            @test new_item_id(q, ITEM_DATABASE) == "db-2"   # an id is never used again
            save_project(q)
            @test new_item_id(open_project(p.folder), ITEM_DATABASE) == "db-2"
            # older file without counters: highest number in use plus one
            q2 = open_project(p.folder)
            add_item!(q2, ProjectItem("db-7", ITEM_DATABASE, "z", "databases/z", "", ""))
            save_project(q2)
            raw = JuliaMagCore.JSON3.read(read(joinpath(p.folder, "project.jmag.json"), String), Dict{String,Any})
            delete!(raw, "next_ids")
            write(joinpath(p.folder, "project.jmag.json"), JuliaMagCore.JSON3.write(raw))
            @test new_item_id(open_project(p.folder), ITEM_DATABASE) == "db-8"
            @test new_item_id(open_project(p.folder), ITEM_GRID) == "grid-2"
            # errors
            @test_throws ProjectError open_project(joinpath(tmp, "none"))
            write(joinpath(p.folder, "project.jmag.json"), "{ not json")
            err = try open_project(p.folder) catch e e end
            @test err isa ProjectError && occursin("project.jmag.json", err.msg)
        end
    end
end
