# Toasts: short messages in the bottom right corner. This file holds the model; Task 9 draws them.

const TOAST_KINDS = (:ok, :info, :warn, :error)
const TOAST_MS = 4200             # a plain toast stays this long
const TOAST_ACTIONS_MS = 9000     # a toast with action buttons
const TOAST_JOB_FAILED_MS = 12000 # the toast of a failed job
const MAX_TOASTS = 3              # at most this many are shown; the oldest goes first

"""
    Toast(kind, text; sub = "", actions = Pair{String,Function}[], ms, born = time())

A short message.

- `kind`: `:ok`, `:info`, `:warn` or `:error`.
- `text`: the message; `sub`: a second line in a dimmer colour, or `""`.
- `actions`: buttons, as label => function. Each function takes the app.
- `ms`: how long it stays. The default is $(TOAST_MS) ms, or $(TOAST_ACTIONS_MS) ms with actions.
- `born`: the `time()` it was made.
"""
struct Toast
    kind::Symbol
    text::String
    sub::String
    actions::Vector{Pair{String,Function}}
    ms::Int
    born::Float64
    function Toast(kind::Symbol, text::AbstractString; sub::AbstractString = "",
            actions::AbstractVector = Pair{String,Function}[],
            ms::Union{Nothing,Integer} = nothing, born::Real = time())
        kind in TOAST_KINDS ||
            throw(ArgumentError("a toast kind is one of $(join(TOAST_KINDS, ", ")), not :$kind"))
        acts = Pair{String,Function}[String(first(a)) => last(a) for a in actions]
        t = ms === nothing ? (isempty(acts) ? TOAST_MS : TOAST_ACTIONS_MS) : Int(ms)
        return new(kind, String(text), String(sub), acts, t, Float64(born))
    end
end

"True when toast `t` has been shown for its full time at `now`."
toast_expired(t::Toast, now::Real = time())::Bool = now - t.born >= t.ms / 1000

"""
    add_toast!(toasts, t)

Add `t` to the list. With more than $(MAX_TOASTS), the oldest are dropped.
"""
function add_toast!(toasts::Vector{Toast}, t::Toast)
    push!(toasts, t)
    while length(toasts) > MAX_TOASTS
        popfirst!(toasts)
    end
    return t
end

"""
    toast!(app, kind, text; sub = "", actions = Pair{String,Function}[], ms = nothing)

Show a toast. Call it on the render thread. `app` is an `AppState`.
See `Toast` for the arguments and the default times.
"""
function toast!(app, kind::Symbol, text::AbstractString; sub::AbstractString = "",
        actions::AbstractVector = Pair{String,Function}[], ms::Union{Nothing,Integer} = nothing)
    t = add_toast!(app.toasts, Toast(kind, text; sub, actions, ms))
    w = app.window
    w === nothing || request_frames!(w, 0.25)
    return t
end

"""
    prune_toasts!(app, now = time())

Remove the toasts whose time is up.
"""
function prune_toasts!(app, now::Real = time())
    filter!(t -> !toast_expired(t, now), app.toasts)
    return nothing
end
