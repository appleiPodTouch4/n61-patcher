from core.overlay import SourceItem, SourceOverlay


class B1Firmware(SourceOverlay):
    id = "rootfs.b1_firmware"
    feature = "wifi"
    scope = "device"
    note = "从本机 SystemA 复制完整 B1 Wi-Fi/蓝牙固件目录"

    def apply(self, ctx, art=None):
        spec = ctx.t["extract"]["wifi"]
        srcdir = spec["srcdir"]
        files = spec["files"]
        self.items = (
            SourceItem(source="device_s1:" + srcdir, dest=srcdir,
                       op="copy", depends_on_signing=True),
        )
        ctx.verify_device_system(ctx.ssh)
        base = "/mnt1/" + srcdir
        ctx.ssh.sh(" && ".join(f'test -s "{base}/{name}"' for name in files))
        super().apply(ctx, art)
