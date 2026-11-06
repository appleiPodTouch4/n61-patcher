import os

from core import log
from core.overlay import SourceOverlay, resolve_ui_items


PATHS = (
    "System/Library/PrivateFrameworks/Preferences.framework/Accessibility@3x.png",
    "System/Library/PrivateFrameworks/Preferences.framework/Assets.car",
    "System/Library/PrivateFrameworks/Preferences.framework/Shortcuts@3x.png",
    "System/Library/PrivateFrameworks/Preferences.framework/UnreadBubble@3x.png",
    "System/Library/PrivateFrameworks/Preferences.framework/iconCache@3x.artwork",
    "System/Library/PrivateFrameworks/PreferencesUI.framework/Assets.car",
)


class SettingsIcons(SourceOverlay):
    id = "rootfs.settings_icons"
    feature = "ui"
    requires = ("rootfs.base_stream", "rootfs.ui_resources")
    note = "从 UI donor 补设置图标（@3x 缺省、4.7 机型自动落 @2x）"

    def apply(self, ctx, art=None):
        donor = ctx.mount_rootfs(ctx.t.get("ui_donor", "n66"))
        self.items, skipped = resolve_ui_items(donor, PATHS)
        for path in skipped:
            log.log(f"  跳过（donor 无此分辨率）: {os.path.basename(path)}")
        super().apply(ctx, art)
