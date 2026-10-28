"""
    missing_value(T)

The value that marks a missing sample in a channel of type `T`.
Floats use `NaN`, signed integers use `typemin`, unsigned integers use `typemax`
(because `typemin` is 0, a real value), and strings use `""`.
"""
missing_value(::Type{T}) where {T<:AbstractFloat} = T(NaN)
missing_value(::Type{T}) where {T<:Signed} = typemin(T)
missing_value(::Type{T}) where {T<:Unsigned} = typemax(T)
missing_value(::Type{String}) = ""

"Return true when `x` is the missing value of its type."
ismissingvalue(x::AbstractFloat)::Bool = isnan(x)
ismissingvalue(x::Union{Signed,Unsigned})::Bool = x == missing_value(typeof(x))
ismissingvalue(x::AbstractString)::Bool = isempty(x)
