"""Finder layout for the Home Speaker drag-to-Applications disk image."""

from pathlib import Path

root = Path(defines["project_dir"])
files = [
    (defines["app_path"], "Home Speaker.app"),
    (str(root / "Resources" / "DMGDragArrow.png"), "Drag →.png"),
]
symlinks = {"Applications": "/Applications"}
icon = str(root / "Resources" / "HomeSpeakerIcon.icns")
background = "#edf5ff"
format = "UDZO"
filesystem = "APFS"
window_rect = ((120, 120), (680, 390))
default_view = "icon-view"
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_pathbar = False
show_tab_view = False
icon_size = 100
text_size = 13
label_pos = "bottom"
arrange_by = None
show_icon_preview = True
icon_locations = {"Home Speaker.app": (145, 195), "Drag →.png": (340, 195), "Applications": (535, 195)}
# SetFile's extension-hidden flag writes FinderInfo into the app bundle root,
# which invalidates a stapled Developer ID signature. Finder hides .app by default.
hide_extensions = ["Drag →.png"]
