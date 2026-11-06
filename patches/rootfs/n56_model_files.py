from core.overlay import SourceItem, SourceOverlay


def model_paths(tag):
    """按机型短名（N56 / N61）展开的机型文件清单。"""
    return (
        f"System/Library/LaunchDaemons/com.apple.jetsamproperties.{tag}.plist",
        f"usr/share/firmware/multitouch/{tag}.mtprops",
        f"Library/Audio/Tunings/{tag}",
        f"System/Library/Frameworks/MediaToolbox.framework/{tag}",
        f"System/Library/PrivateFrameworks/ACTFramework.framework/{tag}",
        "System/Library/ProductDocuments/RegulatoryImages",
    )


class RootfsModelFiles(SourceOverlay):
    id = "rootfs.n56_model_files"
    feature = "core"
    scope = "device"
    note = "从本机 SystemA 补该板型的机型文件（N56 / N61）"

    def apply(self, ctx, art=None):
        board = ctx.t["device"]["model"]           # n56ap / n61ap
        tag = board.upper().replace("AP", "")      # N56 / N61
        self.items = tuple(
            SourceItem(source="device_s1:" + path, dest=path,
                       op="copy-if-missing", depends_on_signing=False)
            for path in model_paths(tag)) + (
            SourceItem(source=f"device_s1:System/Library/Watchdog/ThermalMonitor.bundle/{tag}AP.bundle/Info.plist",
                       dest=f"System/Library/ThermalMonitor/{tag}AP-Info.plist",
                       op="copy-if-missing", depends_on_signing=False,
                       mode=0o644, uid=0, gid=0, check={"plist": True}),
            )
        super().apply(ctx, art)
