"Kind of survey line. The letter codes are in `line_letter`."
@enum LineType LINE TIE BASE TEST TREND SPECIAL RANDOM

const LINE_LETTERS = ('L', 'T', 'B', 'S', 'R', 'P', 'D')

"Return the one-letter code of a line type."
line_letter(t::LineType)::Char = LINE_LETTERS[Int(t) + 1]

"Return the line type for a letter. Upper and lower case both work."
function line_type(c::Char)::LineType
    i = findfirst(==(uppercase(c)), LINE_LETTERS)
    i === nothing && throw(ArgumentError("unknown line type letter: $(repr(c))"))
    return LineType(i - 1)
end

"What a channel means to the tools."
@enum ChannelRole ROLE_NONE ROLE_X ROLE_Y ROLE_Z ROLE_TIME ROLE_DATE ROLE_LON ROLE_LAT ROLE_ELEVATION ROLE_MASK ROLE_LINE

"Identity of a line: type, number and version. Equal when all three are equal."
struct LineId
    type::LineType
    number::Int
    version::Int
end

"Return the line name, such as `L1001`, or `L1001.2` when the version is above 0."
function line_name(id::LineId)::String
    base = string(line_letter(id.type), id.number)
    return id.version > 0 ? string(base, ".", id.version) : base
end

"""
Facts about one line. `offset` is the first row of the line in the channel files.
"""
mutable struct LineInfo
    id::LineId
    flight::Int
    date::String
    fid_start::Float64
    fid_step::Float64
    nrows::Int
    offset::Int
    selected::Bool
end

"""
Facts about one channel.

- `format` is one of `:normal`, `:exponential`, `:date`, `:time`.
- `decimals == -1` means "not set". Importers set -1 and exporters then use `repr`.
- `arraylen` is 1 for plain channels.
"""
mutable struct ChannelInfo
    name::String
    label::String
    eltype::DataType
    units::String
    role::ChannelRole
    format::Symbol
    width::Int
    decimals::Int
    protected::Bool
    arraylen::Int
end

"Names of the two channels that give a position, and their coordinate system."
mutable struct PositionPair
    x::String
    y::String
    "A code such as `\"EPSG:7855\"`, or `\"\"` when unknown."
    crs::String
end
