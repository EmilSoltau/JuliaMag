# Toasts: short messages in the bottom right corner: the model and the drawing.

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
- `born`: the start of its lifetime, first the `time()` it was made. While the mouse is
  over the toast, its clock stops: `born` moves forward by the time the mouse stays.
- `shown`: the `time()` it was made; it never moves, and drives the slide-in.
- `id`: a serial number, unique in the process; it names the toast's ImGui window.
"""
mutable struct Toast
    kind::Symbol
    text::String
    sub::String
    actions::Vector{Pair{String,Function}}
    ms::Int
    born::Float64
    shown::Float64
    id::Int
    function Toast(kind::Symbol, text::AbstractString; sub::AbstractString = "",
            actions::AbstractVector = Pair{String,Function}[],
            ms::Union{Nothing,Integer} = nothing, born::Real = time())
        kind in TOAST_KINDS ||
            throw(ArgumentError("a toast kind is one of $(join(TOAST_KINDS, ", ")), not :$kind"))
        acts = Pair{String,Function}[String(first(a)) => last(a) for a in actions]
        t = ms === nothing ? (isempty(acts) ? TOAST_MS : TOAST_ACTIONS_MS) : Int(ms)
        return new(kind, String(text), String(sub), acts, t, Float64(born), Float64(born),
            Threads.atomic_add!(TOAST_SERIAL, 1) + 1)
    end
end

const TOAST_SERIAL = Threads.Atomic{Int}(0)

"""
    toast_ref(t) -> String

The test engine reference of toast `t`'s window; its items are `toast_ref(t) * "/Close"`
and so on. The name stays while older toasts come and go.
"""
toast_ref(t::Toast) = "//###toast$(t.id)"

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

# --- Drawing ---

const TOAST_SLIDE = 0.14   # s; a new toast slides up 6 px and fades in, as the prototype
const TOAST_MAX_WIDTH = 380
const TOAST_ICONS = Dict(:ok => "ok", :info => "info", :warn => "warn", :error => "error")

"""
    ToastLayout

Where the parts of one toast go, in device pixels, relative to its top left corner.
"""
struct ToastLayout
    width::Float32
    height::Float32
    lines::Vector{String}
    sub_lines::Vector{String}
    action_widths::Vector{Float32}
end

"""
    toast_layout(t, scale, measure) -> ToastLayout

Lay out toast `t` as the prototype's `.toast`: 1 px border, padding 8 10 8 12, a 16 px
icon, 8 px gap, the text (12.5 on 17.5 px lines), the `sub` text (11.5 on 16.1 px lines),
a row of small buttons 6 px under the text, 8 px gap and a 22 px close button.
At most $(TOAST_MAX_WIDTH) px wide; longer text wraps.
`measure(role, size, text)` is the text width in device pixels, `wrap(role, size, text,
max_width)` the wrapped lines and `button_w(label)` the width of a small button.
"""
function toast_layout(t::Toast, scale::Real, measure, wrap, button_w)::ToastLayout
    p(x) = px(scale, x)
    chrome = 2 * hairline(scale) + p(12 + 16 + 8 + 8 + 22 + 10)
    text_max = p(TOAST_MAX_WIDTH) - chrome
    lines = wrap(FONT_REGULAR, BODY_FONT_SIZE, t.text, text_max)
    sub_lines = isempty(t.sub) ? String[] : wrap(FONT_REGULAR, 11.5, t.sub, text_max)
    action_widths = Float32[button_w(first(a)) for a in t.actions]
    text_w = 0f0
    for l in lines
        text_w = max(text_w, measure(FONT_REGULAR, BODY_FONT_SIZE, l))
    end
    for l in sub_lines
        text_w = max(text_w, measure(FONT_REGULAR, 11.5, l))
    end
    if !isempty(action_widths)
        text_w = max(text_w, sum(action_widths) + p(4) * (length(action_widths) - 1))
    end
    text_w = min(text_w, text_max)
    # Line pitches keep their fraction, as in a browser; only the total is rounded.
    block = Float32((17.5 * length(lines) + 16.1 * length(sub_lines)) * scale) +
            (isempty(action_widths) ? 0f0 : p(6 + 22))
    h = 2 * hairline(scale) + p(8 + 8) + max(p(22), block)
    return ToastLayout(round(chrome + text_w), round(h), lines, sub_lines, action_widths)
end

# Ease-out, close to CSS `ease-out`.
ease_out(x::Real) = 1 - (1 - clamp(Float32(x), 0f0, 1f0))^2

"How far toast `t` has slid in at `now`: 0 at first, 1 when it is in place."
toast_slide(t::Toast, now::Real = time())::Float32 = ease_out((now - t.shown) / TOAST_SLIDE)

"""
    draw_toasts(app)

Draw the toasts in the bottom right corner, oldest on top, the newest 38 px above the
bottom edge and 12 px from the right, 8 px apart. Each toast is an ImGui window, so its
close and action buttons are items; the cards are drawn on the foreground draw list, so
they sit above dialogs as in the prototype. The mouse over a toast stops its clock.
"""
function draw_toasts(app)
    isempty(app.toasts) && return nothing
    w = app.window::Window
    s = w.scale
    t = app.tokens
    now = time()
    vp = unsafe_load(ig.GetMainViewport())
    measure = (role, size, text) -> text_width(role, size, text)
    button_w = label -> button_width(app, label; small = true)
    layouts = [toast_layout(x, s, measure, wrap_lines, button_w) for x in app.toasts]
    bottom = vp.Pos.y + vp.Size.y - px(s, 38)
    right = vp.Pos.x + vp.Size.x - px(s, 12)
    dl = ig.GetForegroundDrawList()
    removed = nothing
    run = nothing
    for i in reverse(eachindex(app.toasts))
        toast, l = app.toasts[i], layouts[i]
        k = toast_slide(toast, now)
        k < 1 && request_frames!(w, 0.05)
        dy = round(px(s, 6) * (1 - k))
        b = Box(right - l.width, bottom - l.height + dy, right, bottom + dy)
        bottom -= l.height + px(s, 8)
        ig.SetNextWindowPos((b.x0, b.y0))
        ig.SetNextWindowSize((width(b), height(b)))
        ig.PushStyleVar(ig.ImGuiStyleVar_WindowPadding, (0, 0))
        ig.PushStyleVar(ig.ImGuiStyleVar_WindowBorderSize, 0)
        ig.Begin("###toast$(toast.id)", C_NULL, TOAST_WINDOW_FLAGS)
        ig.PopStyleVar(2)
        if ig.IsWindowHovered()
            toast.born += unsafe_load(ig.GetIO().DeltaTime)   # the lifetime stops, the slide goes on
        end
        act, closed = draw_toast(app, dl, toast, l, b, k)
        ig.End()
        closed && (removed = toast)
        if act !== nothing
            removed = toast
            run = act
        end
    end
    removed === nothing || filter!(x -> x !== removed, app.toasts)
    run === nothing || guarded(app, run)
    return nothing
end

const TOAST_WINDOW_FLAGS = ig.ImGuiWindowFlags_NoDecoration | ig.ImGuiWindowFlags_NoBackground |
    ig.ImGuiWindowFlags_NoSavedSettings | ig.ImGuiWindowFlags_NoFocusOnAppearing |
    ig.ImGuiWindowFlags_NoNav | ig.ImGuiWindowFlags_NoMove

# One toast card. Returns (the action to run or nothing, closed).
function draw_toast(app, dl, toast::Toast, l::ToastLayout, b::Box, alpha::Float32)
    s = app.window.scale
    t = app.tokens
    p(x) = px(s, x)
    hl = hairline(s)
    radius = p(8)
    draw_shadow(dl, b, radius, p(6), p(18), t.shadow, alpha)
    ig.AddRectFilled(dl, (b.x0, b.y0), (b.x1, b.y1), u32(t.menu, alpha), radius)
    stroke = toast.kind === :error ? t.red : t.border_strong
    ig.AddRect(dl, (b.x0, b.y0), (b.x1, b.y1), u32(stroke, alpha), radius, hl)
    top = b.y0 + hl + p(8)
    draw_icon(dl, TOAST_ICONS[toast.kind], (b.x0 + hl + p(12), top + p(1)), 16; alpha)
    x = b.x0 + hl + p(12 + 16 + 8)
    y = top
    for line in l.lines
        draw_text_mid(dl, FONT_REGULAR, BODY_FONT_SIZE, x, y + 8.75f0 * s, u32(t.text, alpha), line;
            line = 1.4)
        y += 17.5f0 * s
    end
    for line in l.sub_lines
        draw_text_mid(dl, FONT_REGULAR, 11.5, x, y + 8.05f0 * s, u32(t.text_dim, alpha), line;
            line = 1.4)
        y += 16.1f0 * s
    end
    act = nothing
    if !isempty(toast.actions)
        y = round(y + p(6))
        for (k, (label, f)) in enumerate(toast.actions)
            # Not while a project opens or closes: the action would act on the old one.
            button(app, "$label##action$k", label, x, y; small = true, alpha, dl,
                enabled = app.switching === nothing) && (act = f)
            x += l.action_widths[k] + p(4)
        end
    end
    close = Box(b.x1 - hl - p(10 + 22), top, b.x1 - hl - p(10), top + p(22))
    closed, hovered = icon_button(app, "Close", "close", close; alpha, dl)
    hovered && item_tip!(app, "Dismiss")
    return act, closed
end
