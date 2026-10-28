"""
    JuliaMagCore

Headless core for airborne magnetic data processing.
"""
module JuliaMagCore

include("model/types.jl")
include("model/missing.jl")
include("storage/columns.jl")
include("storage/atomic.jl")
include("storage/database.jl")
include("project/project.jl")

export LineType, LINE, TIE, BASE, TEST, TREND, SPECIAL, RANDOM
export line_letter, line_type, line_name
export ChannelRole, ROLE_NONE, ROLE_X, ROLE_Y, ROLE_Z, ROLE_TIME, ROLE_DATE,
    ROLE_LON, ROLE_LAT, ROLE_ELEVATION, ROLE_MASK, ROLE_LINE
export LineId, LineInfo, ChannelInfo, PositionPair
export missing_value, ismissingvalue
export LineDatabase, DatabaseError, create_database, open_database, save_meta
export add_channel!, add_line!, channel, line, total_rows
export ColumnAppender, open_appenders, append_value!, end_line!, close_appenders!
export ItemKind, ITEM_DATABASE, ITEM_GRID, ITEM_MAP, ProjectItem, Project, ProjectError
export create_project, open_project, save_project, add_item!, remove_item!, item, item_missing
export new_item_id, database
export read_channel, write_value!, write_channel!

end # module
