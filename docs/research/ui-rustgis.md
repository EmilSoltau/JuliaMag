# RustGIS UI research for a Dear ImGui clone

All paths are under `RustGIS/crates/ui-egui/src/` unless noted.
Units are egui points (1 pt = 1 px at scale 1.0).
Stack: eframe + egui 0.37 + egui-wgpu; the shell is `apps/rustgis/src/main.rs`.

## 0. Shell

- The window opens at 1480x920 with a minimum of 900x560 (`apps/rustgis/src/main.rs:395-399`).
- On macOS the title bar is hidden and the header acts as the title bar (`main.rs:405-413`).
- Per-frame entry is `RustGisApp::ui` (`lib.rs:3843`).
- Draw order is `chrome::header`, `ribbon::show`, `chrome::status_bar`, `panes::show`, `table::show`, `timebar::show`, then a `CentralPanel` filled with `t.canvas` that holds the map (`lib.rs:3860-3868`).
- When the backstage is open, only `backstage::show` is drawn instead of those (`lib.rs:3858-3859`).
- Dialogs and overlays are drawn after the panels, in this order: dialogs, layerchooser, confirm_delete, autosave, saveprompt, plugins, update, showme, command_search, about, agentthreads, notices (toasts), fieldmenu (`lib.rs:3870-3883`).

## 1. Theme tokens (`theme.rs`)

Widgets never hard-code colours.
They call `Tokens::get(ctx)`, which returns `dark()` or `light()` from `ctx.global_style().visuals.dark_mode` (`theme.rs:122-124`).
`theme::apply` pushes the tokens into egui `Visuals` and spacing (`theme.rs:187-234`).
It runs when `applied_dark` changes (`lib.rs:3835-3840`).

### Constants (`theme.rs:8-11`)

| Name | Hex | Use |
|---|---|---|
| BRAND | #B84A2C | Project button, logo, backstage nav fill |
| BRAND_DARK | #963A22 | Project button hover |
| CONTEXT | #0E9384 | contextual tab group colour |

### Token table (`theme.rs:50-120`)

| Token | Light | Dark |
|---|---|---|
| header | #EEF1F5 | #171B21 |
| ribbon | #FFFFFF | #242931 |
| tab_strip | #EEF1F5 | #171B21 |
| canvas | #E4E8EE | #12151A |
| pane | #FBFCFD | #1E232A |
| pane_header | #F3F5F8 | #242931 |
| border | #DDE2E9 | #343B45 |
| border_strong | #C3CAD4 | #48515D |
| text | #1F2630 | #E6EAEF |
| text_dim | #5E6977 | #9AA4B1 |
| text_disabled | #A9B1BC | #5C6571 |
| icon | #3A4554 | #C9D1DB |
| hover | #E9F0FB | #2F3744 |
| pressed | #D4E2F8 | #2A3D5E |
| checked | #DCE8FA | #283B5C |
| accent | #2563EB | #5B8DF6 |
| accent_text | #1D4EC4 | #8AAFFA |
| on_accent | #FFFFFF | #FFFFFF |
| input | #FFFFFF | #151920 |
| input_border | #C6CDD7 | #444D59 |
| group_label | #707A88 | #8C96A3 |
| status_bar | #F3F5F8 | #1A1E24 |
| selection | #CFE0FC | #26406E |
| menu | #FFFFFF | #262C34 |
| shadow | black alpha 28 | black alpha 110 |
| green | #169A5A | #3FC282 |
| red | #D13C3C | #F06A6A |
| amber | #E59E1A | #F2B848 |
| context | #0E9384 | #2CC2AE |
| context_tint | #E3F5F2 | #1B3331 |

### Visuals mapping (`theme.rs:188-220`)

- panel_fill = pane; window_fill = menu; extreme_bg_color = input; faint_bg_color = pane_header.
- window_stroke = 1 px border_strong.
- window_corner_radius = 10; menu_corner_radius = 8; widget corner radius = 5 (inactive, hovered, active).
- selection.bg_fill = selection; selection.stroke = 1 px accent; hyperlink = accent_text.
- noninteractive: stroke 1 px border, fg 1 px text.
- inactive: weak_bg_fill = input; bg_stroke 1 px input_border; bg_fill (slider rail, checkbox well) = #DDE3EA light, #3A424D dark.
- hovered: bg_fill and weak_bg_fill = hover; stroke 1 px border_strong.
- active and open: bg_fill and weak_bg_fill = pressed.
- slider_trailing_fill = true.
- popup_shadow: offset (0,6), blur 18, no spread.
- window_shadow: offset (0,10), blur 28.

### Spacing and text (`theme.rs:224-233`)

- item_spacing = (6, 5); button_padding = (8, 3); interact_size.y = 22.
- Body 12.5, Button 12.5, Small 10.5, Monospace 12.0 (egui Hack), Heading = semibold 17.
- Ad hoc sizes seen in code: 11 (group labels, status), 11.5 (ribbon labels, status values), 12 (labels), 13 (semibold, primary button, palette rows), 14 (backstage nav), 15 (tool form title), 12.5 semibold (tabs, title).

### Fonts

- Families are `regular(size)` (Proportional) and `semibold(size)` (Name "semibold") (`theme.rs:127-133`).
- The UI face is the first installed system face from `crates/render/src/fonts.rs:9-22`: Segoe UI / Segoe UI Semibold, SF (SFNS), Arial, Inter, Noto Sans, Open Sans, DejaVu.
- Fallback is egui's bundled Ubuntu Light (`fonts.rs:63`).
- Semibold is a variable-font wght axis at 600 (`fonts.rs:49`, `theme.rs:147-148`).
- Hack is appended as fallback for Georgian.
- CJK and other script faces are added as fallbacks (`theme.rs:137-185`).

### Stroke widths and rounding used in widgets

- Hairlines are 1 px in `border` or `border_strong`.
- Ribbon buttons, hover and checked fill: radius 6 (`widgets.rs:106`); checked adds a 1 px outline of `accent` at 0.55 alpha (`widgets.rs:108`).
- Tab hover radius 5; active tab radius 6 on the top corners only.
- Command search box: radius 12, 1 px `border` (`chrome.rs:154-155`).
- Status separators: 1x14 px rect in border_strong (`chrome.rs:433-436`).
- Toast: radius 8, 1 px stroke (red for errors, else border_strong), margin 12x8 (`chrome.rs:1181-1186`).

## 2. Window layout (top to bottom)

| Band | Height | Source | Fill | Notes |
|---|---|---|---|---|
| Header (title bar + QAT + search) | 34 (`HEADER_HEIGHT`) | `chrome.rs:58,84` | header | inner margin left/right 10, no separator line |
| Tab strip | 32 | `ribbon.rs:79` | tab_strip | margin left/right 8 |
| Ribbon | 72 + 18 + 12 = 102 | `ribbon.rs:90`, `widgets.rs:9-10` | ribbon | margin L8 R8 T5 B3; 1 px `border` line under it, drawn at `max.y+3` (`ribbon.rs:93-94`) |
| Left pane | default 270, range 200..480, resizable | `panes.rs:31` | pane | margin 0 |
| Right pane | default 320, range 260..640, resizable | `panes.rs:73-74` | pane | Web Data pane default 440 |
| Central | rest | `lib.rs:3866` | canvas | the map |
| Status bar | 26 | `chrome.rs:228` | status_bar | margin L10 R10; 1 px `border` line on top edge |

- Side pane header strip is 34 high, fill pane_header, 1 px border line at the bottom (`panes.rs:383-388`).
- A ribbon can be collapsed (Ctrl+F1, tab double-click, chevron at the tab strip right).
- Collapsed: only the tab strip shows. A tab click "peeks" the ribbon, and it closes on the next click outside it (`ribbon.rs:83-122`).
- The left pane is closed with its X; there is no collapse rail.
- The right side holds several open panes as tabs (see section 4).
- Both side panes clip content to the panel width, so long rows never widen the panel (`panes.rs:40-46,75-82`).
- Table, time bar and layout views are additional panels (`table::show`, `timebar::show`), drawn before the central panel.

## 3. Ribbon

### Structure

- It is hand coded per tab, not data driven. Tabs are an array: `TABS = [Home, Data, Style, Labeling, Edit, Analyze, View, Publish, Plugins, Settings, Help]` (`ribbon.rs:19`).
- A `match` on the active tab calls `home_tab`, `data_tab`, etc. (`ribbon.rs:97-110`).
- Plugins can add their own tab as `plugin:<id>` (`ribbon.rs:58-70`).
- Every control carries a command id and runs it through the command registry: `app.run_by_user(id, params)` (`widgets.rs:140`).
- A control is enabled from `registry.get(id).enabled(&session)` (`widgets.rs:55-60`).
- The tooltip shows the title, the shortcut, the description, and "Unavailable: reason" when disabled (`widgets.rs:72-90`).
- `CommandSpec` has id, label, location ("Home > Navigate"), shortcut, params text, mutates, enabled fn, run fn (`crates/engine/src/lib.rs:39-54`).
- The ribbon layout itself is not generated from the registry. Only Command Search, tooltips and the keymap read it.

### Groups and buttons (`widgets.rs`)

- Content area 72 high, label area 18 high (`widgets.rs:9-10`).
- `group(ui, title, add)` lays children left to right with 2x1 spacing and a centred 11 px label in `group_label` colour at `y = CONTENT_H + LABEL_H/2 - 1` (`widgets.rs:407-430`).
- After the group come 6 px space, a 1 px `border` vertical separator from `y+6` to `y+CONTENT_H+LABEL_H-4`, then 7 px space.
- The group width is at least the label width + 12.
- `col(ui, ...)` is a vertical stack of up to three small buttons, spacing 1x1 (`widgets.rs:433-440`).
- Large button `big` (`widgets.rs:116-175`):
  - Size is (max(label width + 14, 50)) x 70, label font regular 11.5.
  - Icon is 32x32, centred at `y = top + 21`.
  - Label starts at `top + 42`, with 13.5 px line pitch, up to two lines split on `\n`.
  - Hover fill is `hover`, pressed is `pressed`, checked is `checked` plus an accent outline; radius 6.
  - A menu button gets a caret (7x4 triangle) after the last line (`widgets.rs:101-103,163-168`).
- Split big button `big_split_menu` (`widgets.rs:177-266`):
  - A primary area of width w plus a 20 px arrow area, both 70 high.
  - A 1 px divider is drawn at the arrow's left edge, inset 6 px top and bottom.
  - A focus ring is 1 px accent, radius 6.
- Small button `small` (`widgets.rs:238-266`):
  - Size is (26 + label width + 8) x 22.
  - Icon is 18x18 centred 13 px from the left; the label starts at x+26 in regular 11.5.
  - An icon-only small button is 26x22.
  - Small menu button: width 26 + label + 20, caret at right - 9.
- Disabled colour: icon and text both `text_disabled`.
- Menus: `egui::Popup::menu`, min width 200 (`widgets.rs:271-275`).
- Form menus (with checkboxes and sliders) stay open until a click outside (`big_form_menu`, `small_form_menu`).
- The ribbon scrolls horizontally with 18 px arrow buttons when too narrow (`ribbon.rs:129-185`).

### Tab strip (`ribbon.rs:204-316`)

- Project button: height 26, width = semibold 12.5 text + 26, fill BRAND (BRAND_DARK on hover), radius 6, white semibold 12.5 text, tooltip "Open, save and create projects". It sets `app.ui.backstage = true`.
- 6 px gap, then the tabs.
- Each tab is 32 high; width = text width + padding clamped to 8..22 (narrower when crowded).
- Text is regular 12.5, semibold when active. Colour is `text_dim`, or `text` when active. Text is centred at `center.y + 1.5`.
- Active tab: body starts 3 px below the top, fill = ribbon colour, 1 px `border` stroke, radius 6 on top corners only.
  - A strip at the bottom (`max.y-1.5 .. max.y+1`) covers the stroke so the tab merges with the ribbon.
  - A 2 px accent bar with radius 1 sits at `max.y-3 .. max.y-1`, inset 8 px each side.
- Hover on an inactive tab: `hover` fill, radius 5, shrunk 1x2.
- Double-click a tab runs `ui.ribbon` (collapse). A click on a tab while collapsed toggles the peek.
- Right side of the strip: a 24x24 collapse button (chevron icon, shrink 5, `hover` fill on hover). Left of it, an optional tool pill (22 high, radius 11, `checked` fill, `accent_text` 11.5 text, text "{tool} tool active · Esc to stop").
- Settings and Help are not pinned right. They are the last two tabs in the same strip. `FIXED_TABS = [Settings, Help]` can never be hidden (`ribbon.rs:22`).
- Hiding: Settings > Customize > Ribbon (a form menu of checkboxes) runs `ui.customizeRibbon {tab}`. The list is `app.ui.hidden_tabs`, saved as pref `hidden_tabs` (`ribbon.rs:3278-3299`, `lib.rs:1095`).
- Keyboard access: no Alt key tips. Ctrl+F1 collapses the ribbon. Controls are egui widgets, so Tab and Space/Enter work. Tabs expose `WidgetInfo::selected` for accessibility.

### Header (`chrome.rs:81-221`)

- Order, left to right: 24x24 logo, 6 px, "RustGIS" semibold 13, 10 px, then the Quick Access Toolbar.
- The QAT holds small icon buttons: new, open, save, undo, redo (with the undo label in the tooltip), then user-chosen extras from `QUICK` (`ribbon.rs:1505`).
- The title is centred: semibold 12.5 project name + " •" if dirty, then "  -  map name" in regular 12 `text_dim`. It drops out when there is no room.
- Command search pill, right aligned: 24 high, width clamp(label+hint+70, 200, 260). It shrinks to 150 min, then to a 26 px round icon.
  - Fill `input` (`hover` on hover), 1 px `border`, radius 12.
  - Search icon 14x14 at x+16; label regular 12 `text_dim` at x+30; hint "Ctrl+K" (or the Mac command-K) regular 11 `text_disabled`, right aligned 12 px from the edge.
  - A click sets `app.ui.command_search = Some("")`.

### Backstage (`backstage.rs`)

- It replaces the whole window content (`lib.rs:3858`). It is a state flag (`ui.backstage`), not a modal.
- Left nav panel is 210 wide, fill BRAND, with a top pad of 16 (or the title bar height) and a bottom pad of 16.
- First row is "Back" (back arrow, 22x22 icon at x+30), 40 high. Then a 12 px gap.
- Pages (`backstage.rs:10-17`): Start, New, Open, Save, Save As, About. Each row is 40 high, icon 18x18 at x+30, text at x+50, regular 14 (semibold when selected), white.
  - Selected row fill is white alpha 46; hover is white alpha 22. Icon accent is #FFD36E.
  - Open, Save and Save As run commands (`ui.open`, `ui.save`, `ui.saveAs`). Save and Save As close the backstage on success. Start, New and About switch the page.
- Content: `CentralPanel` with fill = ribbon colour and margin symmetric 48 horizontal x 36 vertical, in a vertical ScrollArea.
- Start page: a 44x44 logo, then 200x160 cards with 18 px spacing (thumb 176x86 at +12,+12, 48x48 icon in it), then a project info grid with 2 columns, spacing 16x6, dim labels (Name, Location, Maps, Layers) (`backstage.rs:97-170`).

## 4. Side pane

### Left pane (`panes.rs:25-56`, `LEFT_PANES` at 404)

- Three tabs: Layers (`contents`), Browser (`catalog`), Data Sources (`sources`). Each opens through a `ui.pane.*` command, the same as the ribbon.
- Header strip is 34 high. Tabs start at x+6, with 2 px gaps. Tab width = semibold 12.5 text + 18.
- Active tab uses semibold 12.5, text colour, and a 2 px accent underline at `max.y-1.5`, inset 4. Inactive is regular, `text_dim`, with `hover` fill (radius 4, shrunk 1x5) on hover.
- When too narrow, tabs become 32 px wide icon tabs (18x18 icon) with a tooltip.
- A close X button (22x22, icon shrunk 5) sits at `max.x - 18` (`panes.rs:391-401`).
- A search box sits under the header, at the foot of every left pane (`searchbox.rs`).
- The left pane is a single panel switched by `app.ui.left` (None, Contents, Catalog, Sources).

### Right pane (`panes.rs:62-95,112-200,260-375`)

- `RightPane` enum has about 25 variants: Geoprocessing, Symbology, History, Details, Editing, Design, Workflows, Script, Tasks, Jobs (titled "Workflow Manager"), Profile, TimeSeries, Diagnostics, Infographics, Report, Presentation, Notebook, Assistant, Shares, Sql, Directions, Bookmarks, Format and more (`lib.rs:461-486`).
- Panes open as tabs in `right_open`, in the order opened. One is in view.
- Tab = padding 9 + semibold/regular 12.5 text + 4 + a 16 px X + 5. The X closes that pane. A right-click menu closes it, the others, or all.
- A "»" menu (28 px) lists tabs that do not fit. An "all" X (30 px) at the end closes every pane.
- Switching a tab calls the pane's command. Titles and commands are in `right_title` (`panes.rs:112`).

### Tree and list look (Layers)

- Rows are `allocate_exact_size(available_width, row_h)`. `row_h` is 26 for one line, +1 line height for two (names wrap to 2 lines, then ellipsis) (`panes.rs:1640-1680`).
- Row content: expand arrow, visibility checkbox, symbol swatch (18x18), name starting at `NAME_X = 10+16+22+24 = 72`.
- Row geometry: icons centred 13 px below the row top. Hover and selection fills are `r.shrink2(4,1)`, radius 5, using `hover` and `selection`.
- The active layer gets an outline (`active_outline`, `panes.rs:1059`); picked rows are not bolder.
- Name font is regular 12.5. Disabled or non-selectable text is `text_disabled`.
- A selection badge is a right-aligned count (10.5 text, +10 px padding).
- Drag to reorder with a drop indicator (`layer_drop`).
- Group headers use `group_header` (`panes.rs:968`). Folder trees use `egui::CollapsingHeader`.

## 5. Command search (Ctrl+K) (`chrome.rs:843-1030`)

- It is a modal (`egui::Modal`) with a backdrop. A click on the backdrop or Esc closes it.
- Width = clamp(window width - 48, 220, 520). The list height = clamp(window height - 190, 120, 360).
- Top row: 18x18 search icon, frameless text edit with the hint "Search commands - e.g. buffer, basemap, labels", and a 22x22 close X with the tooltip "Close (Esc)". A separator follows.
- Matching is plain case-insensitive substring, not fuzzy: label, id or location contains the query (`chrome.rs:843-846`).
- Result order: geoprocessing tools (only when the query is non-empty), workflow sections, registry commands (all, in registration order), plugin commands, plugin panels, `UI_COMMANDS` (ids that exist only in the UI, `chrome.rs:636`). Limit is 40 rows.
- An empty query lists everything (the first 40).
- Each row: a frameless button, min height 26, full width, label size 13. The right-hand text is size 11 weak: "location   shortcut". The location is dropped when the palette is under 400 wide.
- Hover fill is `hover`, via `row_button`. Unavailable commands stay listed greyed out with the "Unavailable: reason" tooltip.
- Enter runs the first available hit. A click runs the hit.
- Running: `gp:<id>` opens the tool form (`ui.gp.open`); `panel:` opens a plugin panel; `pane:` opens a workflow; a `SearchAction` maps to a dialog, pane or item command; otherwise `app.run_by_user(id, null)`. Commands that need input are shown disabled with "it needs input..." (`chrome.rs:826-840`).
- The scroll bar is solid, with its own gutter.

## 6. Status bar (`chrome.rs:225-431`)

Height 26. Left to right (item spacing 10, 1x14 separators in border_strong):

1. Scale text edit, 96 wide, id `status_scale`. It selects all on focus, parses "1:12,345 / 12345 / 25k", and Enter runs `map.setScale`. Next to it is a frameless "▾" preset menu (5k ... 100M).
2. Monospace 11.5 text "Zoom {z} · Bearing {b}° · Pitch {p}°". It is `text_dim`, or `accent_text` when turned or tilted, and a click resets north.
3. Separator.
4. Pointer coordinates, monospace 11.5 `text_dim`, "-" when none. A click toggles decimal degrees and DMS.
5. Projection name, size 11 `text_dim`, clickable (opens the coordinate system dialog).
6. Separator.
7. "Selected Features: N", 11.5, `accent_text` if N>0. A clear-selection icon (16x16) shows when N>0.
8. Right-to-left cluster: GPU/CPU toggle (monospace 11), separator, "N fps" (monospace 11, `text_disabled`), separator, "N ms" (11, `text_disabled`), separator, the MCP relay state (11.5; red when full access, `accent_text` when clients attached, amber for "File bridge only"), then the latest notice (11.5, `text_dim`, red if error, truncated with a hover tooltip).

## 7. Tool settings (geoprocessing form) (`panes.rs:3013-3500`)

- Forms are generated from tool parameter descriptions: `rustgis_engine::analysis::ToolSpec` has `id, name, summary, toolbox, params`. Each param has `name, label, help, required, kind`.
- `ParamKind` includes Layer, PolygonLayer, PointLayer, Field, NumericField, CoordinateField, Choice(&[..]), RasterLayer(s), VectorLayer(s), Bool, Number, Path, SaveFile{ext}, and text.
- A param is hidden when `param_applies(tool, name, values)` says it does not apply (`panes.rs:3128-3133`).
- Not modal, not a separate dialog. It is the Geoprocessing right pane, switched from the tool finder to the tool form (`app.gp.tool`).
- Tool finder: a search field (icon + frameless box + clear X), a separator, then toolboxes as `CollapsingHeader` "Toolbox (count)" open by default. Rows are full width x 42 with an icon, name and summary, and `hover` fill, radius 6. Searching flattens to dim toolbox headings (size 11, `text_dim`) with rows under them.
- Form layout (single column, label above widget, no label column):
  - Header row: 26x26 back icon button, a 22x22 tool icon, the name in semibold 15.
  - Summary in size 11.5 `text_dim`, then a separator with 4 px space above and below.
  - Per param: label size 12, with " *" if required, and the help text as a hover tooltip. Below it: a full width combo (width = available - 4), a checkbox, a text edit (`desired_width = INFINITY`, hint "number" or "file path"), or a path edit with a Browse / Save As button on its right (right-to-left row). 4 px gap after each.
  - There is no Advanced section and no Reset button. Optional params are marked by a missing "*", and optional combos offer a blank "-" entry.
- Buttons: only Run, right aligned, via `primary_button(label, enabled, (96, 30))` (`widgets.rs:471-490`). It is a green (`t.green`) rect, radius 6, semibold 13 white label centred on the cap height, min height 28, width = max(96, text + 28). Disabled = green at 0.45; hover 0.9; pressed 0.8.
- `dialog_button` (OK/Cancel) is regular 12.5, uses theme button look; with `fill` it is semibold white on a coloured fill (`widgets.rs:493-508`).
- Cancel exists only while a plugin tool runs: a "Running..." row with spinner, bold tool name, and a right-aligned Cancel button, plus the last log line in size 11 `text_dim` as progress (`panes.rs:3455-3475`).
- Result box: after a run, a framed box (radius 6, margin 8, fill green or red at 0.12 alpha via `gamma_multiply`, 1 px stroke green or red), a semibold 12.5 "Completed" or "Failed" head, then message lines at 11.5.
- Generic modal dialogs (other commands) are `egui::Window`: not resizable, not collapsible, centred pivot at `content_center + (0,-40)`, fixed content width (440 default; 520, 560, 660 for some), spacing 8x8, label+field forms in `egui::Grid` with 2 columns and spacing (10, 8) (`dialogs.rs:240-262`).

## 8. Jobs, progress, toasts, errors

- Geoprocessing progress is shown inside the form (spinner + "Running..." + Cancel + last log line). Browser runs show a spinner and "Running...".
- The "Jobs" right pane is a project job tracker (New / In Progress / On Hold / Done lists with Start, Done, Zoom buttons), titled "Workflow Manager" (`workspacepanes.rs:301-340`). It is not a background task queue.
- Tasks pane: a list of recorded step-by-step tasks with a combo, "Edit Steps" checkbox and step rows (`workspacepanes.rs:155`).
- Toasts (`chrome::notices`, `chrome.rs:1151-1195`):
  - Source: `session.notices`. A toast per new notice; at most 3 are shown.
  - Lifetime is 3 s, or 6 s for errors. The timer is held while the pointer is over the toast. The text is selectable.
  - Position: x = window right - 380; first toast bottom at `window bottom - 40 - 44`, stacking upward by 52 each.
  - Frame: width 340 content, margin 12x8, fill `menu`, 1 px stroke (red if error, else border_strong), radius 8, shadow offset (0,4) blur 14. A 12 px dot (circle radius 6) in green or red, then the text at size 12.
  - The latest notice also shows in the status bar (red when error).
- A failed command returns `Err(String)`. Callers show a notice (toast + status bar), or for a tool run an inline red result box. Fetch errors use two levels: a plain "what happened / what to do" pair, plus folded "Details" (`failureui.rs:1-40`).
- Confirmations: modal dialogs (save prompt, recovery offer, delete confirm).

## 9. Keyboard shortcuts

- Defined in `keymap.rs:15-34` (`DEFAULTS`). "Mod" is Ctrl, or Cmd on macOS.
- The list: Mod+K command search, Mod+N new project, Mod+O open, Mod+S save, Mod+Shift+S save as, Mod+Z undo, Mod+Y redo, Mod+Shift+Z redo, Mod+T table, Mod+F1 ribbon collapse, Mod+= and Mod++ zoom in, Mod+- zoom out, Home zoom full, Esc `tool.set explore`, Delete `edit.delete`, Mod+D duplicate layout element.
- Clipboard Mod+C, Mod+X, Mod+V come as egui events, not key presses (`keymap.rs:39`).
- Commands can also declare a default `shortcut` in `CommandSpec`, added when the key is free.
- Users can rebind. `app.ui.keymap` holds the bindings, with a `match_order()`.
- Handler: `chrome::shortcuts` (`chrome.rs:488-677`). It is skipped while any modal is open (`chrome.rs:491`). While a text field is focused, only chords with Ctrl pass, and text undo/redo are left to the field. Arrow keys nudge a selected layout element (Shift for fast).
- Shortcut text: `Ctrl+Shift+S` on Win/Linux, `⇧⌘S` on Mac (`keymap.rs:122-150`). It appears in tooltips, Command Search rows, and the Help > Shortcuts window (`chrome.rs:1098-1145`; a striped 2-column grid, spacing 24x6, non-resizable window).

## 10. Icons

- No icon font or icon set. All icons are original, drawn in code on a 24-unit grid with the egui painter (lines, polygons, arcs, circles), in `icons.rs` (1314 lines): "all original and drawn in code on a 24-unit grid: neutral ink strokes with accent fills" (`icons.rs:1`).
- API: `icons::paint(painter, rect, name, ink, accent)`. Stroke widths scale with `rect.width()/24`, minimum 1 px.
- So there is no third party icon licence to take care of; the artwork is project code.
- Icons are two-tone: ink = `icon` token, accent = `accent` token. Disabled icons use `text_disabled` for both.
- Sizes: 32 in large buttons, 18 in small buttons and left tabs, 22 in the tool header, 16 in rows, 14 in the search pill, 48 in backstage cards.
- For a Dear ImGui clone, the nearest match to this look would be a stroke icon set drawn on a 24 grid (the project draws its own); expect to ship your own glyph drawing (ImDrawList lines) or an icon font with 1.5-2 px strokes.

## 11. State vs drawing, and testing

- State is in plain structs on the app: `RustGisApp { session, ui: UiState, map, gp: GpForm, forms, ws, docs, dialogs, layout, ... }` (`lib.rs:850-870`).
- `UiState` (`lib.rs:524`) holds tab, backstage, backstage_page, left/right/right_open, hidden_tabs, quick_access, keymap, command_search (`Option<String>`; Some = open), ribbon_minimized, ribbon_peek, toasts and so on.
- `session` (engine crate `rustgis-engine`) owns the project, the command registry, notices and undo. The UI contains no business logic: controls call `app.run(id, json)` / `run_by_user`, and engine commands are JSON-parameter functions `run(&mut Session, &Value)`.
- The engine crate is egui-free, so the same commands serve the CLI, Python, web and MCP agents.
- Drawing functions are plain `fn(app, ui)`, immediate mode, reading `Tokens::get(ctx)` every frame.
- Panel functions live in separate modules (chrome, ribbon, panes, backstage, dialogs, ...); `lib.rs` composes them.
- Tests:
  - `egui_kittest` with the `wgpu` and `snapshot` features (`Cargo.toml` dev-dependencies). Harness size 1400x860 (`tests/smoke.rs:12-20`), driven by labels via `kittest::Queryable`, asserting on state. `tests/smoke.rs` is 3377 lines. Buttons expose `WidgetInfo` labels so tests find them.
  - No `assert_snapshot` / `.snapshot(` call was found in the crate, so there are no image snapshot tests in the repo as checked.
  - `examples/ui_shot.rs`: a headless offscreen wgpu screenshot tool driven by a JSON lines script (cmd, click, type, key, shot, dark, width/height, pixelsPerPoint default 2, dt). Default 1480x900. This is the pixel review tool.
  - Unit tests in `chrome.rs` (e.g. header layout, scale parsing, search disabled rules).
  - Many integration tests in `crates/ui-egui/tests/*.rs`.

## Summary (15 lines)

1. Theme: 30 named colour tokens in light and dark (theme.rs:50-120); widgets read `Tokens::get(ctx)` every frame, never hex literals.
2. Brand #B84A2C, accent #2563EB light / #5B8DF6 dark, canvas #E4E8EE / #12151A, green Run button #169A5A.
3. Body text 12.5, small 10.5, ribbon labels 11.5, group labels 11, heading 17 semibold; system sans (Segoe UI, SF, Inter...) with semibold at wght 600.
4. Spacing: item (6,5), button padding (8,3), control height 22; radius 5 widgets, 6 ribbon buttons, 8 menus/toasts, 10 windows; all hairlines 1 px.
5. Vertical stack: header 34, tab strip 32, ribbon 102 (72 content + 18 label + 12 padding), map, status bar 26.
6. Side panes: left default 270 (200..480), right default 320 (260..640), both resizable, header strip 34 with underlined tabs.
7. Ribbon is hand coded per tab, but every control carries a command id and runs through the command registry with enabled/disabled and tooltip from it.
8. Large button 70 high, 32 px icon, 11.5 label up to 2 lines; small button 22 high, 18 px icon; group label centred below, 1 px separator between groups.
9. Active tab: white tab body, 1 px border, rounded top, 2 px accent bar; Project button is a brand red pill that opens a full window backstage (210 px brand nav, 48x36 content margin).
10. Settings and Help are ordinary last tabs, always visible; other tabs can be hidden in Settings; Ctrl+F1 collapses the ribbon, click on a tab peeks it.
11. Command search: Ctrl+K modal, 520 wide max, substring match (not fuzzy) on label, id, location; 26 px rows with location and shortcut at right, Enter runs first enabled hit.
12. Status bar: scale box, zoom/bearing/pitch, pointer coords, CRS, selected count, then GPU/fps/ms, relay state and the latest notice at the right.
13. Tool forms are generated from engine ToolSpec params into a right pane (label above widget, full width, Run only in green); no modal, no Advanced section, no Reset.
14. Toasts: 340 wide cards, bottom right, 3 s (6 s on error), max 3, dot in green or red; errors also go to the status bar and inline red result boxes.
15. Icons are hand drawn vector code (no icon font, no licence); tests use egui_kittest label queries (no image snapshots found) plus a headless ui_shot screenshot example for pixel checks.
