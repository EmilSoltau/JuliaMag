# Parquet export of line data (spec 7), with Parquet2.jl.
#
# - One row group per line. Parquet2 writes each row group to the file as soon
#   as it is made, so memory holds one line at a time: all exported channels of
#   the longest line, plus Parquet2's encoded pages of that line. A line is
#   never split over row groups.
# - The first column, `LINE`, holds the line name, such as `L1001` or `T2001.1`.
# - Float64, Float32, Int32, Int16, Int8, UInt8 and text channels become the
#   same Parquet types. Array channels become one column per value, `SPEC[0]`,
#   `SPEC[1]`, ...
# - Missing values: floats keep `NaN`. Whole numbers and text use Parquet nulls,
#   so other tools (pandas, DuckDB, GIS) do not read `typemin`, `255` or empty
#   text as data. The file metadata key `juliamag.missing` says this too.
# - Progress and cancel are checked once per line, since a line is one row group.
# - No fiducial column is added; the line sampling is not kept in the file.

using Parquet2, Tables

"The file metadata that explains the missing values."
const PARQUET_MISSING_NOTE =
    "Missing values are NaN in float columns and null in whole number and text columns."

"One line as a table for Parquet2: columns that may be views of the block readers' buffers."
struct LineTable
    names::Vector{Symbol}
    columns::Vector{AbstractVector}
end

Tables.istable(::Type{LineTable}) = true
Tables.columnaccess(::Type{LineTable}) = true
Tables.columns(t::LineTable) = t
Tables.columnnames(t::LineTable) = t.names
Tables.schema(t::LineTable) = Tables.Schema(t.names, Type[eltype(c) for c in t.columns])
Tables.getcolumn(t::LineTable, i::Int) = t.columns[i]
function Tables.getcolumn(t::LineTable, name::Symbol)
    k = findfirst(==(name), t.names)
    k === nothing && throw(ArgumentError("the line table has no column $name"))
    return t.columns[k]
end

"""
A Parquet column of values: floats as they are (missing is NaN), whole numbers
and text as `Union{Missing,T}` with `missing` for the missing values.
"""
parquet_column(v::AbstractVector{<:AbstractFloat}) = v
parquet_column(v::AbstractVector{T}) where {T} =
    Union{Missing,T}[ismissingvalue(x) ? missing : x for x in v]

function write_parquet(io::IO, path::String, p::ExportPlan, t::RowProgress)::Vector{String}
    names = column_names(p)
    syms = Symbol[:LINE; Symbol.(names)]
    fw = Parquet2.FileWriter(io, path; metadata = Dict("juliamag.missing" => PARQUET_MISSING_NOTE))
    readers = open_readers(p)
    try
        # A block is a whole line, so each line is one row group.
        for l in p.lines
            cols = AbstractVector[fill(line_name(l.id), l.nrows)]
            for r in readers
                v = read_block(r, l, 1:l.nrows)
                if v isa AbstractMatrix
                    append!(cols, (parquet_column(view(v, e, :)) for e in axes(v, 1)))
                else
                    push!(cols, parquet_column(v))
                end
            end
            Parquet2.writetable!(fw, LineTable(syms, cols))
            rows_done!(t, l.nrows)
        end
    finally
        foreach(close, readers)
    end
    Parquet2.finalize!(fw)
    return String[]
end

"""
    export_parquet(s, item_id, path; lines = "all", channels = String[], progress = NO_PROGRESS) -> ExportResult

Write database `item_id` to an Apache Parquet file (spec 7): one row group per
line, a `LINE` text column first, then one column per channel (array channels
as `NAME[0]`, `NAME[1]`, ...). Missing values are `NaN` in float columns and
null in whole number and text columns. A channel named LINE is refused.
Memory holds one line at a time. Progress and cancel are checked once per line.
The item is busy for reading while the export runs (ruling R12).

The other settings, the history and errors are as for `export_xyz`.
Recorded as `"export.parquet"`.
"""
function export_parquet(s::Session, item_id::AbstractString, path::AbstractString; lines::AbstractString = "all",
                        channels::AbstractVector = String[], progress::Progress = NO_PROGRESS,
                        record::Bool = true)::ExportResult
    return run_export(s, "export.parquet", item_id, path, lines, channels, progress, record;
                      line_column = true) do io, p, t
        write_parquet(io, String(path), p, t)
    end
end

"Run the Parquet exporter from settings: `lines`, `channels`. As `run_xyz_exporter`."
function run_parquet_exporter(s::Session, item_id::String, path::String, settings::AbstractDict,
                              progress::Progress)::ExportResult
    v = spec_values(LINE_EXPORT_SETTINGS, settings, "Parquet export")
    return export_parquet(s, item_id, path; lines = v["lines"]::String, channels = v["channels"]::Vector{String},
                          progress, record = false)
end

register_exporter!(ExporterSpec("export.parquet", "Parquet", ".parquet", ITEM_DATABASE, LINE_EXPORT_SETTINGS,
                                run_parquet_exporter))
