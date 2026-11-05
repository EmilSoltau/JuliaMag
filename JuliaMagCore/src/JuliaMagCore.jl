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
include("storage/grid.jl")
include("project/project.jl")
include("map/map_item.jl")
include("display/colours.jl")
include("display/histogram.jl")
include("jobs/job.jl")
include("session/lock.jl")
include("session/session.jl")
include("session/undo.jl")
include("history/script.jl")
include("io/textscan.jl")
include("tools/settings.jl")
include("io/registry.jl")
# The export frames come before the formats that use their types.
include("io/line_export.jl")
include("io/grid_export.jl")
include("io/line_import.jl")
include("io/xyz_import.jl")
include("io/grid_import.jl")
include("io/georef.jl")
include("io/gdal_grid.jl")
include("io/geosoft_grd.jl")
include("io/cfb.jl")
include("io/grd_files.jl")
include("io/csv_fields.jl")
include("io/csv_import.jl")
include("io/csv_templates.jl")
include("io/gdb_format.jl")
include("io/lzrw1.jl")
include("io/gdb_blobs.jl")
include("io/gdb_values.jl")
include("io/gdb_admin.jl")
include("io/gdb_lines.jl")
include("io/parquet_export.jl")
include("jobs/jobs.jl")
include("tools/registry.jl")
include("crs/crs.jl")
include("builtin/coordinates.jl")
include("builtin/channel_math.jl")
include("builtin/grid_properties.jl")
include("session/map_edits.jl")
include("storage/line_points.jl")
include("builtin/statistics.jl")

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
export new_item_id, database, grid
export read_channel, write_value!, write_channel!
export GridError, GdbError, GridStyle, colour_tables, colour_table, GridSource, Grid, GRID_BLOCK_BYTES, create_grid, open_grid, save_grid_meta
export values_path, block_rows, read_rows, write_rows!, with_grid_values, cell_centre, grid_corners
export UndoStep, HistoryEntry, Cursor, Session, ProtectedError, ItemBusyError
export LOCK_FILE, ProjectLockedError
export open_session, new_session, close_session!, close_left_open, check_not_busy, push_undo!, undo!, redo!, can_undo, can_redo
export revision, warnings, SessionClosedError, item_revision, item_revisions, data_revision, data_revisions
export LinePoints, read_line_points
export record!, set_cell!, set_line_selected!, set_cursor!, script_text, script_call
export rename_item!, set_marked!, set_channel_protected!, rename_channel!, delete_channel!, set_channel_info!
export add_pair!, remove_pair!, set_lines_selected!
export eachfileline, ImportWarning, ImportResult, Progress, report, is_cancelled, NO_PROGRESS
export GridHeader, GridSink, put_rows!, put_columns!, import_grid
export georef_from_affine, affine_from_grid, read_gdal_grid
export GrdHeader, read_grd_header, grd_eltype, grd_dummy, read_geosoft_grd
export grd_kind, crs_from_grd_xml, crs_from_grd_gi
export ImporterSpec, register_importer!, importers, importer_for, import_xyz
export CsvColumn, CsvLayout, sniff_csv, preview_rows, import_csv
export save_template, load_template, list_templates, layout_json
export JobStatus, JOB_RUNNING, JOB_DONE, JOB_FAILED, JOB_CANCELLED, JOB_UNDONE, Job
export start_job!, cancel!, status, wait_job, jobs, rerun!, import_file, export_file
export JobFailedError
export JobReport, report_text, job_warning!, job_warnings
export ExportResult, ExporterSpec, register_exporter!, unregister_exporter!, exporters, exporter_for
export export_xyz, export_csv, export_parquet, export_geosoft_grd, export_geotiff, export_ers
export SettingSpec, NumberSetting, TextSetting, ExprSetting, ChoiceSetting, BoolSetting, FileSetting,
    ChannelSetting, ChannelListSetting, LinesSetting, CRSSetting, PairSetting, ExtentSetting, PointSetting,
    ItemSetting
export Place, ToolSpec, ToolError, register_tool!, unregister_tool!, tools, tool, tabs, registry_generation
export default_settings, validate, setting_problems, is_active, last_settings, reset_settings!, run_tool
export valid_crs, crs_name, crs_from_wkt, crs_from_name, crs_wkt, guess_utm, reproject_xy
public crs_axis_unit, deactivate_settings, PROJECT_FILE
export parse_channel_expr, ChannelStats, channel_stats, grid_stats
export set_grid_crs!, set_grid_georef!, set_grid_style!
export LayerStyle, MapLayer, MapItem, MapError, MAP_FILE, create_map, open_map, save_map, map_item
export colour_position, effective_style, auto_zfactor, sun_vector
export HIST_BINS, ValueHistogram, reset!, add_values!, quantile_value, equalize_table, equalize_table!, stretch_range
export default_colour_channel, new_map!, add_layer!, remove_layer!, move_layer!, set_layer!

# The one `__init__` of the package. Each part that needs setup when the
# package loads gets a named function, called from here.
function __init__()
    atexit(release_held_locks)
    quiet_gdal!()
    set_gdal_cache!()
    return nothing
end

end # module
