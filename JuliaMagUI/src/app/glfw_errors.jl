# GLFW errors that must not end the app.
#
# GLFW.jl sets an error callback that throws a Julia exception. GLFW calls it from C,
# also from inside ImGui's C++ GLFW backend and from GC-safe waits. Throwing through
# those frames is not safe, and some errors are harmless: on WSLg a monitor change makes
# the video mode query fail ("X11: Failed to query video mode") while ImGui lists the
# monitors. So the app sets its own callback, which only records the error. The render
# loop logs it, and the calls that must succeed check their own results.

const GLFW_ERRORS = Threads.Atomic{Int}(0)     # errors seen so far
const GLFW_LAST_CODE = Threads.Atomic{Int}(0)  # the code of the last one
const GLFW_TEXT_SIZE = 512
const GLFW_LAST_TEXT = Ref{Ptr{UInt8}}(C_NULL) # the text of the last one; malloc'd once
const GLFW_LOGGED = Ref(0)
const GLFW_CALLBACK = Ref{Ptr{Cvoid}}(C_NULL)  # the installed callback

# Called by GLFW. It throws nothing and allocates nothing.
function glfw_error_callback(code::Cint, description::Ptr{UInt8})::Cvoid
    buf = GLFW_LAST_TEXT[]
    if buf != C_NULL
        n = 0
        if description != C_NULL
            while n < GLFW_TEXT_SIZE - 1
                b = unsafe_load(description, n + 1)
                b == 0x00 && break
                unsafe_store!(buf, b, n + 1)
                n += 1
            end
        end
        unsafe_store!(buf, 0x00, n + 1)
    end
    GLFW_LAST_CODE[] = Int(code)
    Threads.atomic_add!(GLFW_ERRORS, 1)
    return nothing
end

"""
    install_glfw_error_callback()

Replace GLFW.jl's throwing error callback with one that records the error
(see `log_glfw_errors` and `glfw_last_error`). Once per process; call it on thread 1.
"""
function install_glfw_error_callback()
    if GLFW_CALLBACK[] == C_NULL
        GLFW_LAST_TEXT[] = Ptr{UInt8}(Libc.calloc(GLFW_TEXT_SIZE, 1))
        GLFW_CALLBACK[] = @cfunction(glfw_error_callback, Cvoid, (Cint, Ptr{UInt8}))
    end
    ccall((:glfwSetErrorCallback, GLFW.libglfw), Ptr{Cvoid}, (Ptr{Cvoid},), GLFW_CALLBACK[])
    return nothing
end

"""
    glfw_last_error() -> (code, text)

The last GLFW error the callback recorded, or `(0, "")`.
"""
function glfw_last_error()::Tuple{Int,String}
    buf = GLFW_LAST_TEXT[]
    text = buf == C_NULL ? "" : unsafe_string(buf)
    return (GLFW_LAST_CODE[], text)
end

# The error for a GLFW call that failed. `before` is `GLFW_ERRORS[]` from before the
# call; the message names the last GLFW error when the call recorded one.
function glfw_failure(what::AbstractString, before::Integer)::ErrorException
    GLFW_ERRORS[] > before || return ErrorException(what)
    code, text = glfw_last_error()
    return ErrorException("$what: $text (GLFW error 0x$(string(code; base = 16)))")
end

# Errors that only mean a monitor changed or went away while GLFW asked about it.
monitor_error(code::Integer, text::AbstractString)::Bool =
    code == Int(GLFW.PLATFORM_ERROR) &&
    (occursin("video mode", text) || occursin("monitor", lowercase(text)))

"""
    log_glfw_errors()

Log the GLFW errors recorded since the last call, from the render loop, where logging
is safe. Monitor errors are expected (a monitor changed) and are only debug messages.
"""
function log_glfw_errors()
    n = GLFW_ERRORS[]
    n > GLFW_LOGGED[] || return nothing
    count = n - GLFW_LOGGED[]
    GLFW_LOGGED[] = n
    code, text = glfw_last_error()
    msg = "$count GLFW error(s); the last: $text (0x$(string(code; base = 16)))"
    if monitor_error(code, text)
        @debug msg
    else
        @warn msg
    end
    return nothing
end
