# -*- coding: utf-8 -*-
"""iPhone 6 (N61AP) × iOS 13.7：本地 donor 与完整 KC 构建链。

与 n56-ios13 的差别只有 donor 与硬件常量：
  - 12.5.8 donor 换 iPhone_4.7（n61ap），iBSS/iBEC/DT/内核全部来自 N61
  - UI 资源 donor 换 N71（iPhone 6s，4.7"@2x）；Health/Chestnut 仍用 N66
  - 触摸 / PMU / 无线固件等板级数据换成 N61 的（见 patches）
"""
TARGET = {
    "name": "n61-ios13",
    "source_root": "donors",

    # ===================== 设备级常量（跨 iOS 版本不变）=====================
    "device": {
        "model": "n61ap",
        "product": "iPhone7,2",
        "ecid": "0x000470c830476826",
        "udid": "b5aa23c5c16866a369194530c7db5241e5900af9",
        "pmu": "d2186",
        "touch": "multi-touch,n61",
        "codec": "CS42L67",
        "charger": "SN2400",
    },
    # 第二系统根分区号：s4。kairos 把 iBEC 的 root-matching 改成 disk0s1s4。
    "root_part": 4,
    # 卷布局：建 s4=SystemB / s5=DataB（role 0），最后改 role。
    "volumes": {
        "create": ["SystemB", "DataB"],
        "roles": {3: 0x80, 4: 0x1, 5: 0x40},
    },
    "data_protection": "encrypted",
    "mounts": {"system_b": 4, "data_b": 5, "system12": 1},   # /mnt6, /mnt7, /mnt1

    "ramdisk_port": 2222,
    "ramdisk_password": "alpine",
    "ramdisk_dir": "tools/SSHRD_Script/sshramdisk",       # iOS12.5.8 SSHRD 镜像（需按 N61 重建）

    # ===================== 版本级常量（随 iOS 版本变）=====================
    # 成功启动链的 boot-args（debug=0x2014e、amfi/cs 放行、root=disk0s1s4）
    "bootargs": "rd=disk0s1s4 -v amfi_get_out_of_my_way=1 "
                "cs_enforcement_disable=1 wdt=-1 debug=0x2014e",
    "source_profiles": {
        "n61": {"build": "16H88", "rootfs_entry": "038-87263-058.dmg",
                "ipsw": "iPhone_4.7_12.5.8_16H88_Restore.ipsw"},
        "n66": {"build": "17H35", "rootfs_entry": "038-68134-036.dmg",
                "ipsw": "iPhone_5.5_13.7_17H35_Restore.ipsw"},
        "n71": {"build": "17H35", "rootfs_entry": "038-69187-036.dmg",
                "ipsw": "iPhone_4.7_13.7_17H35_Restore.ipsw"},
        "j96": {"build": "17H35", "rootfs_entry": "038-68261-036.dmg",
                "ipsw": "iPad_64bit_TouchID_13.7_17H35_Restore.ipsw"},
    },
    # UI 资源类 overlay（手机 App / 设置 / 图标 / 壁纸）的 donor：4.7"@2x
    "ui_donor": "n71",

    # ===================== 从 IPSW 生成的派生输入（ipsw/cache/derived）=====================
    "extract": {
        "kernels": [
            ["n61", "kernelcache.release.iphone7",
             "extracted/n61ap_ios12/kernelcache.release.iphone7.decompressed"],
            ["n66", "kernelcache.release.n66",
             "extracted/n66ap_ios13/kernelcache.release.n66.decompressed"],
        ],
        "devicetrees": [
            ["n61", "Firmware/all_flash/DeviceTree.n61ap.im4p",
             "extracted/n61ap_ios12/DeviceTree.n61ap.jsonc"],
            ["n66", "Firmware/all_flash/DeviceTree.n66ap.im4p",
             "extracted/n66ap_ios13/DeviceTree.n66ap.jsonc"],
        ],
        "copies": [
            ["j96", "kernelcache.release.ipad5", "extracted/j96ap_ios13/kernelcache.release.ipad5"],
            ["j96", "Firmware/038-68261-036.dmg.trustcache",
             "extracted/j96ap_ios13/038-68261-036.dmg.trustcache"],
        ],
        # N61 的无线模块是 tempranillo（N56 是 barbera），目录名同为 C-4345__s-B1
        "wifi": {
            "profile": "n61",
            "rootfs_entry": "038-87263-058.dmg",
            "srcdir": "usr/share/firmware/wifi/C-4345__s-B1",
            "files": ["tempranillo.trx", "tempranillo.clmb", "tempranillo.txcb"],
            "dest": "wifi/C-4345__s-B1",
        },
        "iboot": {
            "profile": "n61",
            "ibss": "Firmware/dfu/iBSS.n61.RELEASE.im4p",
            "ibec": "Firmware/dfu/iBEC.n61.RELEASE.im4p",
            "out_dir": "extracted/n61ap_ios12",
            "ibss_name": "iBSS.n61.patched",
            "ibec_name": "iBEC.n61.dec",
        },
    },

    # ===================== 工具链（仓库 tools/）=====================
    "tools": {
        "img4": "tools/img4lib/img4",
        "devicetree-repack": "tools/devicetree-parse/devicetree-repack",
        "iBoot64Patcher": "tools/SSHRD_Script/Darwin/iBoot64Patcher",
        "KPlooshFinder": "tools/SSHRD_Script/Darwin/KPlooshFinder",
        "gaster": ["tools/SSHRD_Script/Darwin/gaster", "tools/bin/gaster"],
        "irecovery": "tools/SSHRD_Script/Darwin/irecovery",
        "iproxy": "tools/SSHRD_Script/Darwin/iproxy",
        "sshpass": "tools/SSHRD_Script/Darwin/sshpass",
        "Kernel64Patcher": "tools/dualra1n/binaries/Darwin/Kernel64Patcher",
        "kairos": "tools/dualra1n/binaries/Darwin/kairos",
    },

    # ===================== donor 源（本地 donors/）=====================
    "donors": {
        "apfs14": "projects/dualra1n-bin/apfsios14",
        "sys12_mount_hint": "disk0s1s1",
    },

    # ===================== 派生产物引用 =====================
    "derived": {
        "ibss_src": "extracted/n61ap_ios12/iBSS.n61.patched",
        "ibec_dec": "extracted/n61ap_ios12/iBEC.n61.dec",
        "j96_kernel": "extracted/j96ap_ios13/kernelcache.release.ipad5",
        "trustcache": "extracted/j96ap_ios13/038-68261-036.dmg.trustcache",
    },

    "full_trustcache": True,
    # 与 N56 相同的二进制集合（同 build 的同一个二进制），装完首次启动前需复核
    "profile_cdhashes": [
        "ea9b6b492e5f1fc2e1692a0ec93c65ab594c20c4",  # bluetoothd.xpc13
        "e001b09ea59f73cc2804d1654059138ed571029a",  # BlueTool 16H88
        "f2a9b00a2e7fb8e0fefbccdf80bfc79a2aec2202",  # nanoregistryd
        "2f4f85f4bdd0937195536da3d89927dfd01b142f",  # nanoregistrylaunchd
        "44b3dce9c846916db1419304401ceabe9b872031",  # fairplayd.H2
        "eff0e0b43afd6e72cfd81fda04325ce4282d9824",  # healthappd
    ],

    # ===================== patch 选挂 =====================
    "bases": {
        "dt": "dt.base",
        "kc": "kc.j96_clean",
    },
    "features": [
        "pmu", "touch", "charging", "chestnut", "wifi", "vibration", "audio",
        "core",
        "ui",
        "bluetooth",
        "baseband",
        "sep",
        "health",
        "checkra1n",
    ],
    "patches": [],
    "exclude": [],

    # ===================== 启动链发送顺序 =====================
    "boot_chain": ["iBSS", "iBEC", "DeviceTree", "TrustCache", "KernelCache"],
}
