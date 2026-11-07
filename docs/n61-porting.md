# N61（iPhone 6）移植进度

目标：iPhone 6 / N61AP / iPhone7,2，用 iOS 12.5.8 (16H88) 的板级数据 + iOS 13.7 (17H35) 的 J96 内核基底，
产出可启动的 iOS 13.7 系统。

## 已完成（离线可复现）

| 层 | 状态 | 说明 |
|---|---|---|
| target | ✅ | 新增 `targets/n61_ios13.py`，`ui_donor=n71`，KPF 在 features 中 |
| 派生输入 | ✅ | `tools/extract_ipsw.py` 改为 target 驱动；N61 内核/DT/无线固件/iBSS/iBEC 均已落地 `ipsw/cache/derived` |
| DeviceTree | ✅ | `build/offline-n61/DeviceTree.n61ap_native.bin`（128228 B），含 `multi-touch,n61` + `multi-touch,j96` |
| 内核链 | ✅ | base(KPF)→pmu→sn2400→chestnut→mt→wifi→vibration→legacy-sep→audio 全通，49 s |
| SSH ramdisk | ✅ | `tools/SSHRD_Script/sshramdisk` 已按 N61 重建（`version.txt=12.5.8`，DT 里 `iPhone7,2`） |
| rootfs 层 | ✅ | 17 个 patch 跑完，role 已改（s3=0x80 / s4=0x1 / s5=0x40），systembag 1511 B |
| 首次启动 | ✅ | **2026-11-07 00:52 启动成功**：Darwin 19.6.0 / xnu-6153.142.1~8 / ARM64_T7000 / N61AP，17H35 |

### 首启实测（设备侧）

```
uname -a  → Darwin 19.6.0 ... RELEASE_ARM64_T7000 iPhone7,2 arm64 N61AP
SystemVersion → 13.7 / 17H35
```

- 进程 166 个，SpringBoard / backboardd / wifid / bluetoothd / CommCenter + CommCenterMobileHelper 全在；
- 触摸 `AppleMultitouchSPI` 命中 7 处，音频 `CS42L67` 命中 8 处；
- Wi-Fi 接口是 **en1**（iOS 13 不是 en0），`AppleBCMWLAN*` 驱动 44 处，MAC 已从 NVRAM 读出（`ce:29:f5:a2:04:f2`）；
- 蜂窝 `en2` UP+RUNNING，说明 CommCenter 与基带链路正常；
- PMU：`AppleARMPMU` / `SystemPower` / `Charger` / `PowerSource` 均在；
  电池读到真实值 `CurrentCapacity=98`、`Voltage=4330mV`、`CycleCount=1192`、
  `FullAvailableCapacity=1525 / DesignCapacity=1751`（健康度约 87%）、`BatteryInstalled=Yes`；
- bootstrap：`com.apple.checkra1nd`(82) 与 `com.n56.checkra1n`(66) 均退出码 0，
  dropbear 直接监听 `127.0.0.1:44`（已开机自启，无需额外配置）；
- 无内核崩溃：`/Library/Logs/CrashReporter/Panics` 为空；
- `/etc/fstab` 写的是 `disk0s1/disk0s2 hfs`，看似错，实为原厂哑文件——
  iOS 13 已把 fstab 移进 DeviceTree 的 `/filesystems/fstab`（`vol.fs_role`），
  rootfs 里这份被内核忽略，真正生效的是 DT 里的 role。
- **profile_cdhashes 6/6 全等**（把二进制拉回 Mac 用 codesign 算的）：

```
bluetoothd             ea9b6b492e5f1fc2e1692a0ec93c65ab594c20c4
BlueTool               e001b09ea59f73cc2804d1654059138ed571029a
nanoregistryd          f2a9b00a2e7fb8e0fefbccdf80bfc79a2aec2202
nanoregistrylaunchd    2f4f85f4bdd0937195536da3d89927dfd01b142f
fairplayd.H2           44b3dce9c846916db1419304401ceabe9b872031
healthappd             eff0e0b43afd6e72cfd81fda04325ce4282d9824
```

即沿用 N56 的值是对的（同 build 同一份二进制）。

### 运行时注意

- 现在是**半绑定**状态：直接重启会回到 iOS 12.5.8（s1 完好未动）。要再进 13.7 必须重新走
  `boot`（DFU → 发 iBSS/iBEC/DT/TC/KC → bootx）。
- 系统内 SSH：checkra1n bootstrap 的 dropbear 监听 `127.0.0.1:44`，用 `iproxy 4444 44` 转发后
  `ssh -p 4444 root@127.0.0.1`（密码 alpine）。注意 44 是特权端口，iproxy 不能直接绑。

## 施工中修掉的问题

1. `core/overlay.py: _apply_bytes_patch` 改为幂等（当前值已等于 `after` 就跳过），
   否则同一阶段中断后重跑会在 dyld cache 的 162 字节补丁上报 `before 不匹配`；
2. 运行阶段必须 `unset PYTHONPATH`：WorkBuddy 注入的 `sitecustomize` 会把 `os.chmod`/`os.remove`
   转成宿主审批并抛 `EPERM`（`checkra1n/prepare` 里 `script.chmod(0o755)` 就是这么挂的）；
3. `rootfs` 阶段必须真正以 root 跑（代码里有 `geteuid()` 检查），否则 tar 记录的属主会变成 501:20。

### 板级真值（已取证）

- 触摸：人格取 `multi-touch,n61`，`fll-mval` / `mt-merge-personality` 从 N61 12.5.8 内核重取，`mt` 阶段实际改动 8 B。
- 无线：N61 是 `tempranillo`（N56 是 `barbera`），目录同为 `C-4345__s-B1`。
  **J96 13.7 的 hashstore 本来就批准 tempranillo 的三份摘要**，`audit.json` 记 `already_approved: true`，
  所以 N61 不需要改 Wi-Fi 校验（N56 才需要）。
- 机型文件：`jetsamproperties.N61.plist`、`N61.mtprops`、`Audio/Tunings/N61`、`MediaToolbox/N61`、
  `ACTFramework/N61`、`ThermalMonitor.bundle/N61AP.bundle` 在 N61 rootfs 中全部存在。
- UI 资源：N71 与 N66 的 rootfs **不是**同一份（3609 MB vs 3794 MB）。
  N71 里 34 条 UI 资源只有 6 条能按 @3x 命中，但 **27 条 @2x 全部存在**，
  因此 `ui_resources` / `settings_icons` 改为按 donor 实际内容在 @3x / @2x 之间选择。

### Intel 主机上的 checkra1n KPF

`xnu_pf_emit` 生成的是 arm64 匹配器，`xnu_pf_apply` 直接 `call` 它 —— 只有 arm64 主机能执行。
原仓库自带的 `kpf-test.macos` 也是 arm64-only。现在：

1. `tools/checkra1n-kpf/scripts/gen_blob.py` 修正 Mach-O `section_64` 解析（原 `<3Q` 应为 `<QQI`，
   导致 `.bin` 为 0 字节、所有符号落在同一地址）；
2. `src/drivers/xnu/xnu.c` 增加 `N56_KPF_NOJIT=1`：emit 照常执行（内核侧写入的 trampoline 与补丁不变），
   只把匹配循环换成等价的 C 实现；
3. `patches/impl/kc/checkra1n.py` 在非 arm64 主机上自动设置该变量。

arm64 主机行为不变（仍走 JIT 快路径）。

### rootfs 层离线干跑（tools/lint_rootfs.py）

用假 SSH 把 15 个 overlay 的 `apply()` 全走一遍，只校验「要拷的东西在 donor 里是否存在」：

- **5274 个文件 + 5 个目录全部命中**，包括 1620 份 iPhone 设置资源、3559 份 Health bundle、41 份 App 图标；
- `resolve_ui_items` 在 N71 下落 @2x、跳过 1 条 5.5" 专用 `DefaultIconState-414w-736h`；
- 剩余告警全部是离线拿不到的东西：`state/IM4M.bin`、SystemA 版本、目标侧 plist/bytes-patch 校验、
  以及 WorkBuddy 删除保护钩子拦下 `rmtree` 造成的无消息 `SystemExit`。

同时修掉两个会在真机上静默失效的点：

1. `core/context.py: verify_device_system` 硬编码 `source_profiles["n56"]` → 改为按 `device.model` 推导
   （`n61ap → n61`），否则 N61 下 SystemA 版本校验会被整个跳过；
2. `core/log.py: Die` 带上 `message`，让 `lint_rootfs.py` 能区分「缺设备」与「真缺文件」。

## 完整施工顺序（已实际走通）

设备：iPhone 6，UDID `b5aa23c5c16866a369194530c7db5241e5900af9`，ECID `0x000470c830476826`（均已写入 target）。

```bash
# 前置：手机已刷 12.5.8 (16H88)，已备份，已关「查找我的 iPhone」

# 1. 手机进 DFU
python3 n56patcher.py ramdisk --target n61-ios13        # SSHRD 启动链 + iproxy 2222   （23 s）
python3 n56patcher.py extract-im4m --target n61-ios13  # 读 NOR 提 IM4M → state/IM4M.bin
python3 n56patcher.py volumes --target n61-ios13       # 建 s4 SystemB / s5 DataB

# 2. rootfs 阶段必须以 root 跑（代码内有 geteuid 检查），且要先 unset PYTHONPATH
sudo -E env -u PYTHONPATH python3 n56patcher.py rootfs --target n61-ios13        # 流式写入（9 min）
sudo -E env -u PYTHONPATH python3 n56patcher.py patch-rootfs --target n61-ios13  # 17 个 patch + set_roles（8 min）

# 3. 重新进 DFU（iBSS/iBEC 解密只能在 DFU 做）
python3 n56patcher.py build --target n61-ios13         # 解密 + DT + KC 链 + 5 个 img4（7 min）
python3 n56patcher.py boot --target n61-ios13          # 发链 + bootx
```

`build` 与 `boot` 每次都会新建带时间戳的 workdir，所以 `boot` 若没找到组件会自己重跑一次 build。

## 激活：必须从 12.5.8 迁移记录

13.7 从未对 N61AP 签名，`mobileactivationd` 用 12.5.8 的 APTicket 算出的 SIK 走到 albert
只会被拒；仓库本身没有任何激活绕过（`patches/rootfs/apticket.py` 只负责把 IM4M 放到
`/System/Library/Caches/apticket.der`，剩下靠正常联网）。所以强制升级的设备只能做**记录迁移**：
激活记录只绑设备（序列号/IMEI/UDID），不绑 OS 版本。

**源端（12.5.8，需已越狱 + OpenSSH，且本身已激活）**

```sh
# iproxy 2222 22，root / alpine
cd / && tar cf - private/var/containers/Data/System/*/Library/activation_records \
  private/var/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist \
  private/var/mobile/Library/FairPlay/iTunes_Control/iTunes | tar xpf - -C backup/activation-i12
```

> `tar` 前必须 `cd /`，否则 OpenSSH 的 cwd 是 `/root`，相对路径全部找不到；GNU tar 认 `-p` 保留权限位。

**目标端（13.7 运行中）**

1. 容器 UUID 不能照抄，按 metadata 反查：

```sh
for d in /private/var/containers/Data/System/*/; do
  m="${d}.com.apple.mobile_container_manager.metadata.plist"
  [ -f "$m" ] && echo "$(/bin/grep -a -o 'com\.apple\.[A-Za-z0-9._-]*' "$m" | head -1)  $d"
done
# com.apple.mobileactivationd -> 51022B39-DCA9-4C9B-AAE0-8182E543B25D
```

> 13.7 的 rootfs 里**没有 `strings`**（只有 `/bin/grep`），metadata 是二进制 plist，用
> `grep -a -o` 提取即可；`plutil` 也不支持 `-p`（那是 macOS 的），只能用 `-convert xml1`。

2. 停 daemon → 写三处 → 改属主：

```sh
killall -9 mobileactivationd
C=/private/var/containers/Data/System/<uuid>
mkdir -p "$C/Library/activation_records"
cp activation_record.plist "$C/Library/activation_records/"
chown mobile:mobile "$C/Library/activation_records" "$C/Library/activation_records/activation_record.plist"
chmod 755 "$C/Library/activation_records"; chmod 644 "$C/Library/activation_records/activation_record.plist"

mkdir -p /private/var/mobile/Library/FairPlay/iTunes_Control/iTunes
cp IC-Info.sisv IC-Info.sidb IC-Info.sidt /private/var/mobile/Library/FairPlay/iTunes_Control/iTunes/
chown -R mobile:mobile /private/var/mobile/Library/FairPlay

cp com.apple.commcenter.device_specific_nobackup.plist /private/var/wireless/Library/Preferences/
chown _wireless:_wireless /private/var/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist
chmod 600 /private/var/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist

rm -rf /private/var/mobile/Library/Caches/com.apple.mobileactivationd
launchctl kickstart -k system/com.apple.mobileactivationd
```

> `IC-Info.sid*` 通配符匹配不到 `IC-Info.sisv`（sid**b**/sid**t** 与 sis**v** 前缀不同），必须单列。

3. 验证：读 `$C/Library/internal/data_ark.plist`（先 `cp` 到可写目录再 `plutil -convert xml1`），
   应出现 `-ActivationState = Activated`、`-BuildVersion = 17H35`。

4. 让 `Setup.app` 重查：`killall -9 Setup budd`，SpringBoard 会重新拉起它。通过后
   `com.apple.purplebuddy.plist` 出现 `SetupDone = true` / `SetupFinishedAllSteps = true`，
   `Setup.app` 退出、`IconState.plist` 生成，即已进桌面。

三处都在 Data 卷（s5）上，重启不会丢；下次 DFU 重新 boot 进 13.7 仍是已激活。

## 蜂窝诊断（未解决）

设备侧现象：状态栏「正在搜索」，`en2` UP 但只有 169.254 链路本地地址，无 Carrier/Signal。

**已排除**

- DT：`baseband` 节点 `compatible = baseband,n41`（与 N66 13.7 同名），
  `function-bb_rst/reset_det/radio_on/bb_on/bb_usb_delay/bb_usb_mux/pmu_exton/bb_ldo/
  bb_ap_time_sync/coredump/sac/hsic_ready/backpowering-*` 全在；只缺
  `sw_sdn/refclk/vdd_1v8_ap/pmu_exton_config(_v2)/ppm_bb_ebrake/charger_desense/bb_tx_inhibit/uart1_rts`，
  这些在 12.5.8 里也没有，属可选。
- `com.apple.driver.AppleBasebandN61 (1.0.0d1)` 已加载并 match 到 DT 的 `baseband` 节点。
- `patches/rootfs/baseband.py` 的 dyld 补丁**确实已生效**（表首 `010219…`、代码 `08440051/1f410171`、
  `290300b0/29813091` 都在位）；`iPhone7,2` 在 dyld cache 里出现 6 次，产品表并不缺机型。
- s3（role `0x80`）正常挂在 `/private/var/wireless/baseband_data`。
- 硬件：`hsic-baseband@04100000` 上电率 99%（`kPortStatPowerStateTime` On 893343 ms），
  `kPortStatConnectCount = 1` —— 基带芯片是通着电、HSIC 上也连上的。

**关键现象**

1. 每次开机 `MobileGestalt` 都会记一条
   `MGBasebandSupport.c:53: _CTServerConnectionCopyFirmwareVersion: CommCenter error: 1:45 (Operation not supported)`
   —— CommCenter 在基带就绪前就被问过一次，回了「不支持」，之后不再重试。
2. 此时 `ioreg -c AppleBasebandN61` 只有节点本体 + locationd 的 `AppleBasebandUserClient`，
   没有任何子 nub。
3. `killall -9 CommCenter` 并等 20~25 s 后，HSIC 下会**长出**
   `hsic-baseband <AppleUSBHSICDevice>` → `AppleUSBHSICCellularController` → `pdp_ip0`。
   说明驱动链路本身是通的，只是开机那次没走完。
4. 但即便如此，`AppleBasebandManager` 始终为 0 实例，`bbfs/efs1.bin` 的 mtime 不动
   （EFS 从未被挂/读），`ifconfig pdp_ip0` 无地址，仍无 Carrier/Signal —— 没走到 SIM 阶段。

**结论与下一步**

基带是「起了一半」：电源 + HSIC + 数据 nub 都成立，卡在 kext 与 modem 的协议握手
（`AppleBasebandManager` 没建出来，EFS 没挂）。下一步建议按顺序做：

1. 回 12.5.8 抓一份健康基线：`ioreg -p IOService -c AppleBasebandN61 -r -l` 看正常时子 nub
   叫什么、`AppleBasebandManager` 是否存在、`bbfs` 何时被读；
2. 对比 `AppleBasebandN61` 的 `start`/`modemThreadMainLoop` 在两条内核上的差异
   （12.5.8 内核 vs 13.7 内核里同一 kext 的版本号不同）；
3. 若确认是「开机时序」问题，可用 launchd job 在开机后延时重启一次 CommCenter 兜底
   （第 3 条现象已证明重启能把 HSIC 拉起来）。

## 已知未验证项

- KPF 走 C 匹配路径的结果与 arm64 JIT 路径逐字节一致性：两者调用的是同一组 C 回调，
  但 `N56_KPF_NOJIT` 仍未与真实 arm64 机器的产物做过 diff。
- PMU 的 D2186 LDO 表沿用 N56 的板级表（同一颗 PMU），N61 的供电走线未逐条核对；
  实测 `AppleARMPMUSystemPower/Charger/PowerSource` 都正常注册，电池读数待观察。
- Wi-Fi 已验证可用：`en0` 拿到 `192.168.31.71`，`ping 223.5.5.5` 0% 丢包；吞吐未测。
  （前提是 `hashstore_patch` 把 tempranillo 三件套的摘要换成板上实际值，见「施工中修掉的问题」。）
- 基带未注网（详见下节「蜂窝诊断」）。注意：早前以为 `AppleBasebandPlatform`/`HSICDevice`
  「已枚举」是错的——那是 `ioreg -l | grep` 在整个注册表里匹配到了 kext 的类名字符串，
  `ioreg -c` 查实例数一律为 0。
- `mobileactivationd` 的 `-CollectionRetryAttempt` / `-UCRTOOBRetryAttempt` 会持续 +1
  （albert 侧 collection 请求不通过），不影响 `-ActivationState = Activated`，但属于遗留噪声。

### 补充观察（2026-11-07 02:50，换用带 KPF 的 011044 构建再启动一次）

按上一节的实验计划做了一次带时间轴的观测，结果与第一次启动不同，需订正「开机时序」的表述：

| 时点 | `AppleUSBHSICDevice` | `AppleBasebandN61` 上的 user client | `bbfs/efs1.bin` mtime |
|---|---|---|---|
| 开机后约 1.5 min（被动） | 1 个，`identifier=<01000200>`、`CurrentState=7` | 1 个（`pid 60, locationd`） | 仍是 12.5.8 那次启动的 02:29 |
| `killall -9 CommCenter` 后每 12 s 采样、持续 2 min | 同上 | 始终只有 locationd，CommCenter 一个新 client 都没建 | 不动 |

即这次 HSIC 设备在开机阶段**自己就枚举出来了**（与 12.5.8 健康基线一致），不必重启 CommCenter；
但 CommCenter（重启后 pid 268、`launchctl` 显示 `runs = 2`）依然一个用户态 client 都不向基带打开，
EFS 也没被读写。因此瓶颈更可能不在「HSIC 枚举时序」，而在 CommCenter 自身的基带初始化被跳过
（前面日志里那句 `MGBasebandSupport.c:53 ... CommCenter error: 1:45 (Operation not supported)`），
下一步优先查这条错误码的来源，而不是加重启延时任务。

### 硬件配置定位（2026-11-07 20:05，静态比对 12.5.8 vs 13.7）

`CommCenter error: 1:45` 的来源查清了：CommCenter 拿不到「硬件配置」这条最基本的输入。

`libCommCenterBase.dylib` 里的 `GsmRadioPersonality::getHardwareConfiguration`
（13.7 缓存文件偏移 `0x20F03024`）就是一个按产品号分发的大开关：

```
0x1a0f03024  bl   TelephonyRadiosGetProduct   ; 本机 iPhone7,2 → 26
0x1a0f03028  sub  w8, w0, #0x1b               ; 下标 = 产品号 - 27
0x1a0f0302c  cmp  w8, #0x46                   ; 表长 70 → 覆盖产品号 27..96
0x1a0f03030  b.hi default                     ; 越界 → 0x2b（未知）
0x1a0f03038  adrp x9, 0x1a0f40000
0x1a0f0303c  add  x9, x9, #0xc16              ; u16 跳转表 @0x1a0f40c16
```

产品号 26 在 13.7 的表下界（27）之下——iPhone 6 不在 13.7 支持列表里，所以直接落
默认分支拿到 `0x2b`。原补丁把下界改成 `0x11`、表基址换成另造的一张表，实测结果是
**任何入参都返回 0x2b**（连通用的 iPhone 8,1 也被打成未知），等于把产品表整体废掉。

判定「对」的取值靠 12.5.8 比对：挂载 12.5.8 的 IPSW 根分区，取出同名的
`libCommCenterBase.dylib`，其等价开关是 `sub w8,w0,#0xf / cmp #0x4b`，
跳转表 @`0x19b901c84`（int32 偏移），产品号 26 → 下标 11 → `0x19b901650: mov w20,#9`。
即 **本机正常工作时的硬件配置是 9**。13.7 侧返回 9 的分支对应产品号 45，
与 iPhone 6 同属 Mav10 硬件家族，语义吻合。

所以补丁收敛成一条指令：`sub w8, w0, #0x1b` → `sub w8, w0, #8`，
让产品号 26 落到下标 18 → 分支 `0x1a0f0393c: mov w0,#9`。跳转表与 adrp/add 全部还原成原版。

同轮排除/确认的其它点：

- 从任意 root 进程对 `AppleBasebandN61` 逐个 `IOServiceOpen(type=0..15)` **全部成功**，
  说明内核侧 user client 没有拦人，瓶颈完全在用户态。`probe3 open` 可复现。
- `MGGetStringAnswer("HWModel")` 返回 nil 是**键名别名问题**，不是值缺失：
  用混淆键 `/YYygAofPDbhrwToVsXdeA` 能正常取到 `N61AP`，`h9jDsbgj7xIVeIQ8S/3XQ` → `iPhone7,2`。
  MobileGestalt 缓存（`systemgroup.com.apple.mobilegestaltcache`）内容完整，无需重建。
- `usr/standalone/firmware/Baseband/Mav10` 11 个文件齐备，13.7 的 `libTelephonyUtilDynamic`
  与 `libBBUpdaterDynamic` 里都还留着 `Mav10` 字样，固件更新链路没有缺失。
- 可用的在线观察通道：建好 `/var/wireless/Library/Logs/CoreTelephonyTraceScratch/`
  后 CommCenter 会把 IMS/Bambi 的明文 trace 写进去（`/var/wireless/Library/Preferences/com.apple.ipTelephony.plist`
  里 `ImsLoggingEnabled=1` 已开）。基带层日志仍未产出，说明基带初始化确实没走到。

### 重启验证（2026-11-07 20:10）：补丁生效，CommCenter 走进基带初始化后空指针崩溃

补丁首次带补丁重启，结果分层：

1. **补丁确实生效**。参数量准了才发现 `getHardwareConfiguration` 的第 2 个入参才是 productType
   （函数靠它找 `iPhone`/`iPad` token 才会进 switch）：

   ```
   cfg("N61AP",     "iPhone7,2") = 9    ← CommCenter 用的就是这个顺序，正确命中配置 9
   cfg("iPhone7,2", "N61AP")     = 43   ← 顺序反了，token 不匹配，走默认分支
   cfg("iPhone8,1", "N71AP")     = 43   ← 同上
   ```

   并用 `probe9` 在进程内核对：`bl` 目标 == `TelephonyRadiosGetProduct`（返回 26）、
   开关处字节 == `082000511f190171…`、表 `[18]` = 0x23b → 目标 `mov w0,#9`。全链路自洽。

2. **CommCenter 行为变了，但变成崩溃循环**。此前它安静地跳过基带（`ps` 里 pid 77 常驻），
   现在从 19:57:50 开始每 10 s 崩一次，共 25 次后被 launchd 节流，当前 `CommCenter` 进程不存在：

   ```
   Exception Type:  EXC_BAD_ACCESS (SIGSEGV) / KERN_INVALID_ADDRESS at 0x0
   Thread 11 Crashed:
    0  CommCenter + 0x7A8DD8   ldr x8, [x19]        ; x19 = [x26, #0x1b8] == NULL
   ```

   即某个成员对象是空指针，随后取它的虚表。说明流程已经越过「拿硬件配置」这一关，
   卡在「按配置构造 personality/服务对象」这一步。

3. 静态链路的旁证：`getHardwareConfiguration` 在本镜像里只有一个调用点（`0x1a0f02ac8`），
   它是个薄包装：`bl getHardwareConfiguration(x1,x2)` → 把返回值当第 2 个参数
   尾调 `0x1a0f02af0`（`new(0x210)` + `0x1a0f03c84` 构造 → 读 `[obj+0x50]`）。
   崩溃点在这条链的下游，要继续就得沿着 `x26` 找那个没被构造出来的对象。

4. 缓存里**没有任何板号字符串**（`N61AP`/`N71AP`/`J96AP` 全为 0 命中），
   产品表纯靠数字产品号；`Mav10` 只出现在 `libTelephonyUtilDynamic` / `libBBUpdaterDynamic` /
   Powerlog / libswiftSpeech，`libCommCenterBase` 里没有——personality 不是按 Mav10 命名的。

回滚方式：设备上 `/var/tmp/bb-prev.bin` 存着改动前的 24 字节（旧补丁状态），
要退回「稳定但无蜂窝」就把它写回 `0x20F03028`。

### 复核原项目的基带方案（2026-11-07 20:25）

原项目自带基带修复：`patches/rootfs/baseband.py` 在 Initial commit 里就有，
`targets/n56_ios13.py` 的 features 里挂着 `baseband`，`docs/conclusions.md` 也把基带
写成「需要同时满足」的四条（产品表认 N56、Mav10 双路径、Carrier Bundles 取 N66、
s3 role `0x80` 且改后缓存 cdhash 进 TC）。

把原补丁那张 81 项手工表（@`0x1a0f68c20`）解出来对照，结论和之前的判断相反：

```
prod 17        → 0x1a0f03854
prod 18 .. 26  → 0x1a0f038b4   ← 其中包含 N56(25) 和 N61(26)
```

`0x1a0f038b4` 就是 `b.hi` 的默认分支，它先比 `"iPad"`（`mov w19,#0x5069; movk #0x6461,lsl#16`），
命中返回 `0x29`，否则返回 **`0x2b`(43)**。也就是说：

- 原项目对 N56 **也是返回 0x2b**，而 conclusions 认为 N56 的基带是正常的。
  所以 `0x2b` 不是「未知硬件配置」，而是 13.7 给 iPhone 这一档的通用配置。
- 上一轮把 N61 从 `0x2b` 重定向到 `mov w0,#9`（12.5.8 的枚举值）是**跨版本误比**：
  两个版本的硬件配置枚举语义不同，9 对应的 personality 在 13.7 上构造不出来，
  CommCenter 才会 `EXC_BAD_ACCESS` @`+0x7A8DD8`（`[x26+0x1b8] == NULL`）。
- 因此 N61 蜂窝不注网的原因**不在产品表**——N61 原本就走 `0x2b`，与 N56 同档。
  要回到 `Carrier Bundles`、personality 资源、`s3` role/TC 这几条上找。

待办：把设备上的 `sub w8,w0,#8` 还原（回滚点 `/var/tmp/bb-prev.bin`），
让 N61 回到 `0x2b`，再排查真正的注网阻塞点。

### 回滚验证与二轮排除（2026-11-07 20:40）

按上一条结论把缓存里的 `sub w8,w0,#8` 还原成原版 `sub w8,w0,#0x1b` 后重启：

- CommCenter 恢复常驻（pid 77/625，无新增崩溃报告，崩溃计数停在回滚前的 25 个）；
- 基带状态回到原样：`AppleBasebandUserClient` 仍只有 locationd 那 1 个，EFS 不读；
- 说明「改成 9」确实是崩溃的唯一来源，而不是新关卡。

本轮同时排掉几项：

- `disk0s1s3` 已挂在 `/private/var/wireless/baseband_data`（APFS nobrowse），s3 role 没问题；
- `System/Library/Caches/com.apple.factorydata` 8 件齐全，`scrt-00007000-000470C830476826`、
  `seal-00007000-000470C830476826` 的 CPID/ECID 与本机一致，签名材料不是缺口；
- 13.7 的 carrier bundle 不按机型设限（`Info.plist` 只有 `CFBundleDeviceFamily=iPhone`），
  缺 `overrides_N56_N61` 只影响 APN/VoLTE，不会阻止基带启动。

一个可疑的新线索：13.7 把 personality 数据结构从 12.5.8 的 `PersonalityInfo` 重构成
`PersonalitySpecific` / `PersonalitySpecificImpl`，但两版都保留
`"Can't find personality info for: %s"` 与 `"Personality Shop is not ready"` 两个日志点。
若 CommCenter 在 13.7 上取不到 N61 的 personality，就会走「跳过基带」而不是报错。

注入观察这条路已试过并失败：用 `DYLD_INSERT_LIBRARIES` + `launchctl setenv` 起 CommCenter，
钩子库的 constructor 一次都没执行——launchd 对 Apple 签名的 daemon 会剥掉 `DYLD_*`。
要看到 CommCenter 内部的判定，只能走静态调用链或改 job 的 plist（后者同样可能被过滤）。

### 产品号枚举与「默认分支」修正（2026-11-07 20:40）

**13.7 的 rootfs 其实是 iPad（J96）的**：`usr/standalone/update/all_flash` 里全是
`~ipad` 资源，并且 `usr/standalone/update/Mav10.Release.bbfw`（26,407,084 字节）是
rootfs 原生自带的。也就是说 **13.7 用户态本身带 Mav10 支持**（iPad mini 4 / Air 2 那一档），
之前「13.7 不支持 Mav10」的担心不成立。注意它和 12.5.8 的
`Mav10.Release.bbfw`（26,380,490 字节）不是同一版本。

**产品号是缓存变量，可以伪造**。`TelephonyRadiosGetProduct()` 的实现是：

```
adrp x8, page ; ldr x8, [x8, #0x878]   ; once 标志，-1 表示已算好
cmn x8, #1    ; b.ne → 走一次计算
adrp x8, page ; ldr w0, [x8, #0x86c]   ; 缓存的 product
```

在探针（`probe11`）里把 `page+0x878` 写成 -1、`page+0x86c` 写成目标产品号，就能让
`getHardwareConfiguration` 按任意机型的编号分发。枚举结果（13.7，传 `("N61AP","iPhone7,2")`）：

```
prod   1..26  -> 43      ← 表外，全部走 b.hi 默认分支
prod  27      -> 3       ← 表内下标 0
prod  30/31/33-> 0/1/2
prod  34,36   -> 4       prod 35,37 -> 5      prod 38 -> 6
prod  43..46  -> 7,8,9,10
prod  52,53   -> 11,12   prod 57,68 -> 13     prod 62..67 -> 15..20
prod  73      -> 21      prod 79..84 -> 22,23,23,25,26,24
prod  89..96  -> 30..37   prod 97+ -> 43
```

两点结论：

1. **43 不是某个真实配置，而是「产品号不在表内」的兜底值**。iPhone 6 的产品号 26
   正好落在表下界 27 之下，所以拿到 43，CommCenter 就不认这块基带。
   `TelephonyRadiosGetProductName()` 对所有产品号都返回 NULL，产品号没有可读名字表。
2. 原项目那张「把下界改到 0x11、另造 81 项表」的补丁之所以让所有机型都返回 43，
   是因为它造的表把 18..26 全指向了默认分支——它没有真正解决任何机型。

**这一版的补丁只改一条指令**：默认分支里 `mov w0, #0x2b` → `mov w0, #3`
（`0x20F039EC` / 文件偏移 `552614380`，`60058052` → `60008052`）。
产品表、表长、跳转基址全部保持原版，**表内所有机型的映射不受任何影响**，
只有原本落默认分支的 iPhone 会从 43 变成 3。选 3 的理由：它是 13.7 表内下标 0
（产品号 27，iOS 13 支持的最老 iPhone）的配置，是这台机器上「离 iPhone 6 最近」的一档。

### 基带修复成功（2026-11-07 20:50，实测注网）

默认分支那一行改动生效后，iPhone 6 + iOS 13.7 的蜂窝链路**完整打通**：

```
cfg("N61AP","iPhone7,2")        = 3        ← 原为 43
CommCenter 持有的 user client    = 13 个    ← 原为 0（只有 locationd 那 1 个是别的进程）
/private/var/wireless/baseband_data/bbfs/efs1.bin
                                mtime = 20:45（本次开机）  ← 原来停在 12.5.8 那次开机
pdp_ip0                          UP, RUNNING, 10.138.236.113
scutil --nwi                     pdp_ip0: Reachable, Transient Connection, WWAN
CTCarrier                        name=中国移动  mcc=460  mnc=02  iso=cn
currentRadioAccessTechnology     CTRadioAccessTechnologyLTE
```

蜂窝数据通路也验证过（绑定 pdp_ip0 源地址做 TCP 直连，绕开 Wi-Fi 默认路由）：

```
probe13 10.138.236.113 223.5.5.5 80
  bind 10.138.236.113 ok
  connecting 223.5.5.5:80 ... connect OK
  resp: HTTP/1.0 404 Not Found          ← 真实回包，数据链路通
```

`CommCenter` 常驻（pid 77），崩溃报告停在改动前的 20:01，本次开机以来**零崩溃**。

#### 根因定论

`getHardwareConfiguration` 的产品表覆盖产品号 27..96，iPhone 6 的产品号是 **26**，
恰好落在表下界之下，命中 `b.hi` 默认分支。该分支先判 `"iPad"` token（是则返回 `0x29`），
否则返回 `0x2b`。`0x2b` 不是「未知硬件配置」的占位值，而是「这台设备不属于本表任何一档」
的兜底值——`TelephonyRadiosGetProductName()` 对所有产品号都返回 NULL，也没有名字表可反查。
CommCenter 拿到兜底值后不报错，直接跳过基带初始化，于是表现为「进程常驻、EFS 从不读写、
user client 只有 locationd 一个」。

改成 `mov w0,#3`（表内下标 0，产品号 27 的配置）后，CommCenter 认为硬件配置合法，
开始完整驱动基带：加载 Mav10 固件 → 读 EFS → 建 PDP → 注网。

#### 为什么这个改法是对的

- 只动默认分支的**一条**出口指令，表内 70 项映射、表长、跳转基址全部保持原版；
- 早期那次「把下界改到 0x11 + 另造 81 项跳转表」的补丁之所以失败，是因为造出来的表把
  18..26 全指向默认分支，等于对**所有**机型都返回兜底值，包括本来正常的 iPhone 8,1；
- 中间试过的「重定向到 12.5.8 的配置值 9」是跨版本误比：12.5.8 与 13.7 的硬件配置
  枚举语义不同，9 在 13.7 上对应的 personality 构造不出来，导致
  `EXC_BAD_ACCESS @ CommCenter+0x7A8DD8`（`[x26+0x1b8] == NULL`）的崩溃循环。

#### 遗留（不影响注网）

- 13.7 的 carrier bundle 只有 `overrides_N66` / `overrides_N71`，缺 `overrides_N56_N61`。
  这会影响 APN / VoLTE / 彩信等运营商参数，但**不影响基带启动与注网**（已实测）。
  需要时从 12.5.8 的 `Carrier Bundles/iPhone/*/overrides_N56_N61.plist` 补过去，
  改完 `killall CommCenter` 即可生效，不用重启。
