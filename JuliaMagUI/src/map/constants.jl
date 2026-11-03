# Constants of the map view. Each lives here once. The core owns HIST_BINS, the
# equalization table size, the colour table size and the hillshade and clip defaults.

# Zoom
const WHEEL_POINTS = 50           # points per wheel notch, as RustGIS's scroll delta
const EXTENT_PAD = 0.06           # zoom to extent pads each side by this share of the span
const MIN_RES = 0.01              # world units per device pixel
const MAX_RES = 1e7
const HISTORY_LIMIT = 50          # extent history entries each way

# Timing
const SETTLE = 0.15               # s after the last input before a gesture counts as done
const FRAME_BUDGET = 1 / 60       # s

# Line levels
const LOD_FACTOR = 8
const LINE_LEVELS = (1, 8, 64, 512, 4096)   # points per bucket
const POINT_BUDGET = 0.5          # drawn points per view pixel, at most
const CULL_MARGIN = 0.5           # share of the view size kept on each side

# Grid tiles and uploads
const TILE = 2048                 # cells per tile side, plus a 1-cell border on each side
const UPLOAD_BYTES = 8 * 2^20     # per frame, one tile or one line batch at most

# Pick and labels
const PICK_RADIUS = 20            # logical px, for pick and readout
const LABEL_LIMIT = 300           # line labels per frame

# Map view
const ZOOM_STEP = 2.0             # Zoom In and Zoom Out, about the centre
