"""Build the target board's iOS 13 DeviceTree from its native iOS 12 tree."""
from core.patch import Patch
from core.impl import run_impl


class DtBase(Patch):
    id = "dt.base"
    layer = "dt"
    role = "base"
    feature = "core"
    scope = "version"
    note = "从本机 12.5.8 与 N66 13.7 设备树生成目标板 iOS13 设备树"

    def apply(self, ctx, art=None):
        run_impl(ctx, "dt/dt_patch.py", ["--repack", ctx.tool("devicetree-repack"),
                                        "--out", ctx.work], output_dir=ctx.work)
        board = ctx.t["device"]["model"]
        return ctx.wk(f"DeviceTree.{board}_native.bin")
