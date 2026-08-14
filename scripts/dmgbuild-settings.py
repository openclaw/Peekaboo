"""Finder layout for the signed Peekaboo release disk image.

The release driver supplies absolute artifact paths through dmgbuild's ``-D``
arguments. dmgbuild writes Finder metadata directly, so creating a release image
does not need a GUI session or an automation permission prompt.
"""

app_name = defines["app_name"]
app_path = defines["app_path"]

files = [(app_path, f"{app_name}.app")]
symlinks = {"Applications": "/Applications"}

icon = defines["volume_icon"]
background = defines["background"]

window_rect = ((200, 120), (720, 460))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

default_view = "icon-view"
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
text_size = 13
icon_size = 128
label_pos = "bottom"
icon_locations = {
    f"{app_name}.app": (180, 230),
    "Applications": (540, 230),
}
hide_extensions = [f"{app_name}.app"]

format = "UDZO"
filesystem = "HFS+"
