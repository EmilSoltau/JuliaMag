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
include("jobs/job.jl")
include("session/session.jl")
include("session/undo.jl")
include("history/script.jl")
include("io/textscan.jl")
include("tools/settings.jl")
include("io/registry.jl")
include("io/line_import.jl")
include("io/xyz_import.jl")
include("io/csv_import.jl")
include("jobs/jobs.jl")
include("tools/registry.jl")

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
export UndoStep, HistoryEntry, Cursor, Session, ProtectedError, ItemBusyError
export open_session, new_session, check_not_busy, push_undo!, undo!, redo!, can_undo, can_redo
export record!, set_cell!, set_line_selected!, set_cursor!, script_text
export eachfileline, ImportWarning, ImportResult, Progress, report, is_cancelled, NO_PROGRESS
export ImporterSpec, register_importer!, importers, importer_for, import_xyz
export CsvColumn, CsvLayout, sniff_csv, preview_rows, import_csv
export save_template, load_template, list_templates, layout_json
export JobStatus, JOB_RUNNING, JOB_DONE, JOB_FAILED, JOB_CANCELLED, JOB_UNDONE, Job
export start_job!, cancel!, status, wait_job, jobs, rerun!, import_file
export SettingSpec, NumberSetting, TextSetting, ExprSetting, ChoiceSetting, BoolSetting, FileSetting,
    ChannelSetting, LinesSetting, CRSSetting, PairSetting, ExtentSetting, PointSetting
export Place, ToolSpec, ToolError, register_tool!, unregister_tool!, tools, tool, tabs
export default_settings, validate, last_settings, reset_settings!, run_tool

end # module
