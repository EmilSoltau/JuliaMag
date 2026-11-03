# App settings, kept in one JSON file in the user's config folder.

const MAX_RECENT = 10
const DISTANCE_UNITS = ("m", "km", "ft")
const THEME_NAMES = ("light" => THEME_LIGHT, "dark" => THEME_DARK, "system" => THEME_SYSTEM)

"""
    AppConfig

The settings the app remembers between runs.
`recent` holds project folders, newest first, at most $MAX_RECENT.
A `window` of `(0, 0, w, h)` means centred.
`advanced_open` lists the tools whose dialog shows its Advanced settings.
`last_folder` is the folder of the last file picked for an import or an export.
"""
Base.@kwdef mutable struct AppConfig
    theme::ThemeMode = THEME_SYSTEM
    recent::Vector{String} = String[]
    open_last::Bool = false
    hidden_tabs::Vector{String} = String[]
    distance_units::String = "m"
    grid_colours::String = "geosoft"
    temp_folder::String = ""
    software_rendering::Bool = false
    window::NTuple{4,Int} = (0, 0, 1480, 920)
    left_width::Float32 = 272
    right_width::Float32 = 300
    ribbon_collapsed::Bool = false
    advanced_open::Vector{String} = String[]
    last_folder::String = ""
end

"""
    config_dir() -> String

The folder that holds `settings.json`.
"""
function config_dir()::String
    haskey(ENV, "JULIAMAG_CONFIG_DIR") && return ENV["JULIAMAG_CONFIG_DIR"]
    Sys.iswindows() && return joinpath(ENV["APPDATA"], "JuliaMag")
    base = get(ENV, "XDG_CONFIG_HOME", joinpath(homedir(), ".config"))
    return joinpath(base, "juliamag")
end

settings_path(dir::AbstractString) = joinpath(dir, "settings.json")

function theme_name(mode::ThemeMode)::String
    for (name, m) in THEME_NAMES
        m == mode && return name
    end
    error("unknown theme mode $mode")
end

function theme_from_name(name)::ThemeMode
    for (n, m) in THEME_NAMES
        n == name && return m
    end
    throw(ArgumentError("theme must be \"light\", \"dark\" or \"system\", got $(repr(name))"))
end

# Read `key` as type `T`, or return `default` when the key is absent.
function field_or(obj, key::Symbol, ::Type{T}, default::T) where {T}
    haskey(obj, key) || return default
    v = obj[key]
    v isa T || throw(ArgumentError("\"$key\" must be a $(T), got $(repr(v))"))
    return v
end

# Read `key` as a width in logical pixels: a finite number above 0, not `true` or `false`
# (in Julia a `Bool` is a number). Absent, it is `default`.
function width_or(obj, key::Symbol, default::Float32)::Float32
    haskey(obj, key) || return default
    v = obj[key]
    (v isa Real && !(v isa Bool) && isfinite(v) && v > 0) ||
        throw(ArgumentError("\"$key\" must be a width above 0, got $(repr(v))"))
    return Float32(v)
end

function string_list(obj, key::Symbol)::Vector{String}
    haskey(obj, key) || return String[]
    v = obj[key]
    v isa AbstractVector && all(x -> x isa AbstractString, v) ||
        throw(ArgumentError("\"$key\" must be a list of text"))
    return String[x for x in v]
end

function config_from_json(obj)::AppConfig
    obj isa JSON3.Object || throw(ArgumentError("the settings file must hold one JSON object"))
    c = AppConfig()   # the defaults; each key that is there replaces one
    haskey(obj, :theme) && (c.theme = theme_from_name(obj[:theme]))
    c.recent = first(string_list(obj, :recent), MAX_RECENT)
    c.open_last = field_or(obj, :open_last, Bool, c.open_last)
    c.hidden_tabs = string_list(obj, :hidden_tabs)
    units = field_or(obj, :distance_units, String, c.distance_units)
    units in DISTANCE_UNITS ||
        throw(ArgumentError("distance_units must be \"m\", \"km\" or \"ft\", got $(repr(units))"))
    c.distance_units = units
    c.grid_colours = field_or(obj, :grid_colours, String, c.grid_colours)
    c.temp_folder = field_or(obj, :temp_folder, String, c.temp_folder)
    c.software_rendering = field_or(obj, :software_rendering, Bool, c.software_rendering)
    if haskey(obj, :window)
        # x and y may be below 0 (a screen left of the main one); the size is above 0.
        bad = ArgumentError("\"window\" must be a list of 4 whole numbers, its width and height above 0")
        w = obj[:window]
        w isa AbstractVector && length(w) == 4 || throw(bad)
        v = Int[x for x in w if x isa Integer && !(x isa Bool)]
        length(v) == 4 && v[3] > 0 && v[4] > 0 || throw(bad)
        c.window = (v[1], v[2], v[3], v[4])
    end
    c.left_width = width_or(obj, :left_width, c.left_width)
    c.right_width = width_or(obj, :right_width, c.right_width)
    c.ribbon_collapsed = field_or(obj, :ribbon_collapsed, Bool, c.ribbon_collapsed)
    c.advanced_open = string_list(obj, :advanced_open)
    c.last_folder = field_or(obj, :last_folder, String, c.last_folder)
    return c
end

"""
    load_config(dir = config_dir()) -> (AppConfig, Union{Nothing,String})

Read `settings.json`.
A missing file gives the defaults and `nothing`.
A broken file gives the defaults and a message that says what is wrong.
"""
function load_config(dir::AbstractString = config_dir())::Tuple{AppConfig,Union{Nothing,String}}
    path = settings_path(dir)
    isfile(path) || return (AppConfig(), nothing)
    try
        return (config_from_json(JSON3.read(read(path, String))), nothing)
    catch e
        e isa InterruptException && rethrow()
        return (AppConfig(), "Could not read $path: $(sprint(showerror, e))")
    end
end

function config_to_dict(c::AppConfig)
    return (; theme = theme_name(c.theme), recent = c.recent, open_last = c.open_last,
        hidden_tabs = c.hidden_tabs, distance_units = c.distance_units,
        grid_colours = c.grid_colours, temp_folder = c.temp_folder,
        software_rendering = c.software_rendering, window = collect(c.window),
        left_width = c.left_width, right_width = c.right_width,
        ribbon_collapsed = c.ribbon_collapsed, advanced_open = c.advanced_open,
        last_folder = c.last_folder)
end

"""
    save_config(c, dir = config_dir())

Write `settings.json`. The file is written to a temp file in `dir` first and then renamed,
so a crash never leaves half a file.
"""
function save_config(c::AppConfig, dir::AbstractString = config_dir())
    mkpath(dir)
    tmp, io = mktemp(dir)
    try
        JSON3.pretty(io, config_to_dict(c))
        close(io)
        mv(tmp, settings_path(dir); force = true)
    catch
        close(io)
        rm(tmp; force = true)
        rethrow()
    end
    return nothing
end

"""
    add_recent!(c, folder)

Put `folder` (made absolute with `realpath`) first in the recent list. Keeps $MAX_RECENT.
"""
function add_recent!(c::AppConfig, folder::AbstractString)
    c.recent = recent_after_open(c.recent, realpath(folder))
    return c
end

"""
    recent_after_open(recent, path) -> Vector{String}

The recent list after `path` (already absolute) opened: `path` first, no copy of it
further down, at most $MAX_RECENT. It reads no file, so the render thread may call it.
"""
function recent_after_open(recent::AbstractVector{<:AbstractString}, path::AbstractString)::Vector{String}
    out = String[String(path)]
    append!(out, (String(p) for p in recent if p != path))
    length(out) > MAX_RECENT && resize!(out, MAX_RECENT)
    return out
end

"""
    command_says_dark(cmd, is_dark; timeout = 2.0) -> Bool

Run `cmd`, give its output to `is_dark`, and return the answer.
A missing command, a non-zero exit and a timeout all give `false`.
A command that runs out of time is stopped and waited for, so no process is left behind.
"""
function command_says_dark(cmd::Cmd, is_dark::Function; timeout::Real = 2.0)::Bool
    try
        proc = open(pipeline(ignorestatus(cmd); stderr = devnull))
        if timedwait(() -> process_exited(proc), Float64(timeout); pollint = 0.02) != :ok
            kill(proc)
            # One that ignores the request to stop is killed.
            timedwait(() -> process_exited(proc), 1.0; pollint = 0.02) == :ok || kill(proc, Base.SIGKILL)
            wait(proc)
            return false
        end
        out = read(proc, String)
        return success(proc) && is_dark(out)::Bool
    catch e
        e isa InterruptException && rethrow()
        return false
    end
end

"""
    system_dark(ask = command_says_dark) -> Bool

Does the operating system use a dark app theme? Any failure means `false`.
Call it once at start. It waits at most 2 s. `ask(cmd, is_dark)` runs the command; the
tests give their own, so they do not depend on the machine's theme.
"""
function system_dark(ask = command_says_dark)::Bool
    if Sys.iswindows()
        key = raw"HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        cmd = `reg query $key /v AppsUseLightTheme`
        return ask(cmd, out -> occursin(r"REG_DWORD\s+0x0+\s*$"m, out))::Bool
    elseif Sys.islinux()
        cmd = `gsettings get org.gnome.desktop.interface color-scheme`
        return ask(cmd, out -> occursin("prefer-dark", out))::Bool
    end
    return false
end
