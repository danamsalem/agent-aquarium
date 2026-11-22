# Layout of the DMG installer window, for dmgbuild (run by macos/release.sh).
# The window and background leave room for Finder's title, path and status bars.
import os

app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
background = defines["background"]
format = "UDZO"
window_rect = ((240, 120), (680, 520))
default_view = "icon-view"
show_status_bar = show_tab_view = show_toolbar = show_pathbar = show_sidebar = False
icon_size = 96
text_size = 12
icon_locations = {
    os.path.basename(app): (170, 166),
    "Applications": (510, 166),
    ".background.tiff": (620, 450),  # only visible to people who show hidden files
}
