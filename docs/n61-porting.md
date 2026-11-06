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
