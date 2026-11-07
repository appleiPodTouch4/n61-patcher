from core.overlay import SourceItem, SourceOverlay


CACHE = "System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64"
# iPhone 6（产品号 26）在 13.7 的产品表下界（27）之外，会走 b.hi 的默认分支。
# 该分支对 iPhone 返回 0x2b（"不受支持"），CommCenter 据此跳过基带初始化。
# 这里把默认分支的返回值改成 3：13.7 表内下标 0（产品号 27，iOS 13 支持的最老
# iPhone）所用的硬件配置。产品表本身与其中所有机型的映射都不动。
EDITS = (
    (552614380, "60058052", "60008052"),   # 0x20F039EC: mov w0,#0x2b → mov w0,#3
    (1709334847,
     "76f6c93b3c903448176ae5d2fbecdb04596613e0441ffc8058f850a123db7d5a",
     "ae4a995247dc34ced4af27c2ce23eea91f386297c49a9cb8febf30744fc122e8"),
    (1709338079,
     "dde9e59c2e01920493e04c4a6e1c2ba8b7978fc2698389f595d35df3f0c0ebc1",
     "710f6a212e3650bf4ed678b768b7ae53912347b3199db7ca7a54f17c78494ced"),
)


class BasebandCompatibility(SourceOverlay):
    id = "rootfs.baseband_compatibility"
    feature = "baseband"
    scope = "version"
    note = "CommCenter 硬件配置默认分支、Mav10 固件和 iPhone Carrier Bundles"
    items = tuple(
        SourceItem(source="target:" + CACHE, dest=CACHE, op="bytes-patch",
                   depends_on_signing=True, offset=offset, before=before, after=after)
        for offset, before, after in EDITS
    ) + (
        SourceItem(source="device_s1:usr/local/standalone/firmware/Baseband/Mav10",
                   dest="usr/local/standalone/firmware/Baseband/Mav10",
                   op="copy", depends_on_signing=True),
        SourceItem(source="device_s1:usr/local/standalone/firmware/Baseband/Mav10",
                   dest="usr/standalone/firmware/Baseband/Mav10",
                   op="copy", depends_on_signing=True),
        SourceItem(source="ipsw:n66:System/Library/Carrier Bundles/iPhone",
                   dest="System/Library/Carrier Bundles/iPhone",
                   op="copy", depends_on_signing=True),
    )
