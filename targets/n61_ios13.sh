# shellcheck shell=bash
# iPhone 6 (N61AP) × iOS 13.7 目标清单（纯 shell 版，对应 targets/n61_ios13.py）
# 只定义 T_* 变量，由 lib/target.sh 加载。

T_NAME="n61-ios13"
T_SOURCE_ROOT="donors"

# ---- 设备级常量 ----
T_MODEL="n61ap"
T_PRODUCT="iPhone7,2"
T_ECID="0x000470c830476826"
T_UDID="b5aa23c5c16866a369194530c7db5241e5900af9"
T_PMU="d2186"
T_TOUCH="multi-touch,n61"
T_CODEC="CS42L67"
T_CHARGER="SN2400"

T_ROOT_PART="4"
T_VOL_CREATE="SystemB DataB"
T_ROLES="3:0x80 4:0x1 5:0x40"
T_DATA_PROTECTION="encrypted"

T_MNT_SYSTEM_B="4"     # /mnt6
T_MNT_DATA_B="5"       # /mnt7
T_MNT_SYSTEM12="1"     # /mnt1

T_RAMDISK_PORT="2222"
T_RAMDISK_PASSWORD="alpine"
T_RAMDISK_DIR="tools/SSHRD_Script/sshramdisk"
T_BOOT_CHAIN="iBSS iBEC DeviceTree TrustCache KernelCache"

T_BOOTARGS="rd=disk0s1s4 -v amfi_get_out_of_my_way=1 cs_enforcement_disable=1 wdt=-1 debug=0x2014e"
T_UI_DONOR="n71"

# ---- 版本级常量 ----
T_IPSW_N61="iPhone_4.7_12.5.8_16H88_Restore.ipsw"
T_IPSW_N66="iPhone_5.5_13.7_17H35_Restore.ipsw"
T_IPSW_N71="iPhone_4.7_13.7_17H35_Restore.ipsw"
T_IPSW_J96="iPad_64bit_TouchID_13.7_17H35_Restore.ipsw"

T_BUILD_N61="16H88"
T_BUILD_N66="17H35"
T_BUILD_N71="17H35"
T_BUILD_J96="17H35"

T_ROOTFS_ENTRY_N61="038-87263-058.dmg"
T_ROOTFS_ENTRY_N66="038-68134-036.dmg"
T_ROOTFS_ENTRY_N71="038-69187-036.dmg"
T_ROOTFS_ENTRY_J96="038-68261-036.dmg"

# ---- 派生输入（ipsw/cache/derived/）----
T_DERIVED_IBSS="extracted/n61ap_ios12/iBSS.n61.patched"
T_DERIVED_IBEC="extracted/n61ap_ios12/iBEC.n61.dec"
T_DERIVED_J96_KERNEL="extracted/j96ap_ios13/kernelcache.release.ipad5"
T_DERIVED_TRUSTCACHE="extracted/j96ap_ios13/038-68261-036.dmg.trustcache"

# ---- donor ----
T_DONOR_APFS14="projects/dualra1n-bin/apfsios14"

# ---- 补丁选挂 ----
T_BASE_DT="dt.base"
T_BASE_KC="kc.j96_clean"
T_FEATURES="pmu touch charging chestnut wifi vibration audio core ui bluetooth baseband sep health checkra1n"
T_PATCHES=""
T_EXCLUDE=""
T_FULL_TRUSTCACHE="1"

# ---- 工具（相对仓库；缺失时回退 ${LIOS_BIN}）----
T_TOOL_img4="tools/img4lib/img4"
T_TOOL_devicetree_repack="tools/devicetree-parse/devicetree-repack"
T_TOOL_iBoot64Patcher="tools/SSHRD_Script/Darwin/iBoot64Patcher"
T_TOOL_KPlooshFinder="tools/SSHRD_Script/Darwin/KPlooshFinder"
T_TOOL_gaster="tools/SSHRD_Script/Darwin/gaster tools/bin/gaster"
T_TOOL_irecovery="tools/SSHRD_Script/Darwin/irecovery"
T_TOOL_iproxy="tools/SSHRD_Script/Darwin/iproxy"
T_TOOL_sshpass="tools/SSHRD_Script/Darwin/sshpass"
T_TOOL_Kernel64Patcher="tools/dualra1n/binaries/Darwin/Kernel64Patcher"
T_TOOL_kairos="tools/dualra1n/binaries/Darwin/kairos"

# ---- 本机 SystemA 的 B1 无线固件（N61 = tempranillo，N56 = barbera）----
T_WIFI_SRCDIR="usr/share/firmware/wifi/C-4345__s-B1"
T_WIFI_FILES="tempranillo.trx tempranillo.clmb tempranillo.txcb"
