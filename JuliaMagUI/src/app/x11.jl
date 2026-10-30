# X11 errors that must not end the app.
#
# GLFW asks the X server about the monitors when one changes (RRGetCrtcInfo).
# When a monitor goes away during that query, the server answers BadRRCrtc.
# Xlib's default error handler then prints the error and exits the process.
# WSLg does this now and then. This handler ignores that one error and passes every
# other error to the handler that was there before.

const X_PREVIOUS_HANDLER = Ref{Ptr{Cvoid}}(C_NULL)
const X_RANDR_OPCODE = Ref{Cint}(-1)   # the RANDR extension's request code
const X_BAD_RRCRTC = Ref{Cint}(-1)     # the BadRRCrtc error code
const X_IGNORED = Threads.Atomic{Int}(0)
const X_LOGGED = Ref(0)
const X_HANDLER_INSTALLED = Ref(false)

# The offset of `error_code` in XErrorEvent: int type, Display*, XID, unsigned long serial
# (the int is padded to the size of a long). `request_code` follows it.
const X_ERROR_CODE_OFFSET = 4 * sizeof(Clong)

ignore_x_error(request_code::Integer, error_code::Integer)::Bool =
    request_code == X_RANDR_OPCODE[] && error_code == X_BAD_RRCRTC[]

# Called by Xlib, possibly inside a GC-safe GLFW wait. It allocates nothing.
function x_error_handler(display::Ptr{Cvoid}, event::Ptr{UInt8})::Cint
    error_code = unsafe_load(event, X_ERROR_CODE_OFFSET + 1)
    request_code = unsafe_load(event, X_ERROR_CODE_OFFSET + 2)
    if ignore_x_error(request_code, error_code)
        Threads.atomic_add!(X_IGNORED, 1)
        return Cint(0)
    end
    previous = X_PREVIOUS_HANDLER[]
    previous == C_NULL && return Cint(0)
    return ccall(previous, Cint, (Ptr{Cvoid}, Ptr{UInt8}), display, event)
end

"""
    install_x_error_handler()

On Linux with X11, set an Xlib error handler that ignores RANDR BadRRCrtc errors.
Does nothing on Windows, macOS and Wayland, and when it is already set.
"""
function install_x_error_handler()
    X_HANDLER_INSTALLED[] && return nothing
    Sys.islinux() || return nothing
    GLFW.GetPlatform() == GLFW.PLATFORM_X11 || return nothing
    display = ccall((:glfwGetX11Display, GLFW.libglfw), Ptr{Cvoid}, ())
    display == C_NULL && return nothing
    libx11 = Libc.Libdl.dlopen("libX11.so.6"; throw_error = false)
    libx11 === nothing && return nothing
    major, first_event, first_error = Ref{Cint}(0), Ref{Cint}(0), Ref{Cint}(0)
    found = ccall(Libc.Libdl.dlsym(libx11, :XQueryExtension), Cint,
        (Ptr{Cvoid}, Cstring, Ptr{Cint}, Ptr{Cint}, Ptr{Cint}),
        display, "RANDR", major, first_event, first_error)
    found == 0 && return nothing
    X_RANDR_OPCODE[] = major[]
    X_BAD_RRCRTC[] = first_error[] + 1   # RandR errors: BadRROutput, BadRRCrtc, BadRRMode
    handler = @cfunction(x_error_handler, Cint, (Ptr{Cvoid}, Ptr{UInt8}))
    X_PREVIOUS_HANDLER[] = ccall(Libc.Libdl.dlsym(libx11, :XSetErrorHandler), Ptr{Cvoid},
        (Ptr{Cvoid},), handler)
    X_HANDLER_INSTALLED[] = true
    return nothing
end

# Log the ignored X errors, from the render loop, where logging is safe.
function log_x_errors()
    n = X_IGNORED[]
    if n > X_LOGGED[]
        @debug "Ignored $(n - X_LOGGED[]) X11 RANDR BadRRCrtc error(s): a monitor changed."
        X_LOGGED[] = n
    end
    return nothing
end
