from pathlib import Path

app = Path(defines["app"]).resolve()
files = [str(app)]
symlinks = {"Applications": "/Applications"}
format = "UDZO"
filesystem = "HFS+"
icon = str(app / "Contents/Resources/AppIcon.icns")
background = "builtin-arrow"
window_rect = ((240, 180), (640, 280))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
icon_size = 96
text_size = 14
label_pos = "bottom"
hide_extensions = []
icon_locations = {app.name: (140, 120), "Applications": (500, 120)}
