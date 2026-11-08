<div align="center">

# n61-patcher

**iPhone 6（N61AP / iPhone7,2）的 iOS 13.7 第二系统构建与安装工具**

简体中文 · [English](README.en.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md)

![Device](https://img.shields.io/badge/Device-iPhone%206-0A84FF?style=flat-square&logo=apple&logoColor=white)
![iOS](https://img.shields.io/badge/iOS-13.7%20(17H35)-5E5CE6?style=flat-square)
![Host](https://img.shields.io/badge/Host-macOS%20%2B%20Xcode-30363D?style=flat-square)
![Language](https://img.shields.io/badge/Python-3-3776AB?style=flat-square&logo=python&logoColor=white)

[快速开始](#快速开始) · [功能](#功能) · [进阶用法](#进阶用法) · [作者](#作者) · [支持项目](#支持项目)

<sub>同一套流程也适用于 iPhone 6 Plus（N56AP / iPhone7,1），加 `--target n56-ios13` 切换。</sub>

</div>

---

默认从干净 J96 内核重建 KC，同时生成 iBSS、iBEC、DeviceTree、TrustCache 五个启动镜像。内核和设备树变换直接调用本仓库 `patches/impl/`，固件输入放在本地 `donors/`。

项目已从头到尾跑通，最终启动包包含硬件适配、DataB 解密和 checkra1n。技术结论见 [docs/conclusions.md](docs/conclusions.md)，iPhone 6 的移植记录见 [docs/n61-porting.md](docs/n61-porting.md)。

> [!WARNING]
> 本工具会在设备上创建卷并写入系统，操作前请自行备份。本项目与 Apple 无关，按现状提供，风险由使用者自行承担。

## 快速开始

### 1. 准备环境

macOS 安装完整 Xcode（需要 iPhoneOS SDK）后：

```sh
python3 -m pip install -r requirements.txt
python3 tools/setup.py
```

`tools/setup.py` 会生成 `donors/`（checkra1n 用户态和 iOS14 的 fsck、apfs.fs）并从源码构建 gaster。首次构建需设备处于 DFU，用于解密 iBSS、iBEC。

下载 checkra1n 时若报 `CERTIFICATE_VERIFY_FAILED`，是 python.org 版 Python 没装根证书：脚本会自动改用系统证书或 `curl`；也可运行 Python 目录下的 `Install Certificates.command`，或手动下载 0.12.4 DMG 后用 `CHECKRA1N_DMG=/path/checkra1n.dmg python3 tools/setup.py` 离线完成。

SSH ramdisk 需在 DFU 下生成一次（需联网）：

```sh
cd tools/SSHRD_Script && ./sshrd.sh 12.5.8
```

### 2. 下载 IPSW

从 Apple 下载以下文件，文件名不变，放入 `ipsw/`：

```text
ipsw/iPhone_4.7_12.5.8_16H88_Restore.ipsw          # N61 本机 12.5.8：iBSS/iBEC/内核/设备树/无线固件
ipsw/iPhone_5.5_13.7_17H35_Restore.ipsw            # N66：13.7 内核基底
ipsw/iPhone_4.7_13.7_17H35_Restore.ipsw            # N71：4.7" UI 资源（ui_donor）
ipsw/iPad_64bit_TouchID_13.7_17H35_Restore.ipsw    # J96：干净 KC 与 TrustCache
```

首次需要 rootfs 时，流程会把 DMG 提取到 `ipsw/cache/`，之后直接复用。

### 3. 运行端到端流程

首次运行或刷机后，让设备进入 DFU，再运行刷写脚本：

```sh
sudo ./flash.sh all          # 端到端：安装 → 构建 → 启动
# 或分步执行（共享同一工作目录，boot 直接复用 build 产物）：
sudo ./flash.sh install
./flash.sh build
./flash.sh boot
```

```mermaid
flowchart LR
  A["缺文件时解密 iBSS、iBEC"] --> B["进 ramdisk"] --> C["重提 IM4M"] --> D["安装"] --> E["构建"] --> F["启动"]
```

> [!IMPORTANT]
> - 刷机后旧 IM4M 和旧启动包都会失效。`build` 只检查 `state/IM4M.bin` 是否存在，不判断是否过期，单独构建前要先运行 `extract-im4m`。
> - `flash.sh` 默认使用固定的 `build/<target>-latest` 工作目录，分步执行时 `build`/`boot` 复用同一目录的产物；加 `--fresh` 改用带时间戳的新目录，或 `--workdir` 显式指定。
> - `--dry-run` 只打印流程，不访问设备，不写设备，也不生成构建产物。

### 本地目录

以下目录已加入 Git 忽略规则：

| 目录 | 内容 |
| --- | --- |
| `ipsw/` | 自行下载的 IPSW；内核、设备树、TC、Wi-Fi 固件和 Health 库由构建自动生成到 `ipsw/cache/derived/` |
| `donors/` | `tools/setup.py` 生成的固件输入 |
| `state/` | IM4M；`--data-protection none` 还需要自备 `state/keybags.tar`，默认的 `encrypted` 不需要 |
| `build/` | 生成结果 |

## 功能

默认选择全功能。`--features` 按功能选择各层补丁，`--patches` 单独覆盖 KC 选择；依赖自动补齐。

| 功能 | KC patch ID | 自动带入 |
| --- | --- | --- |
| `pmu` | `kc.pmu_d2186` | 基础 KC |
| `touch` | `kc.mt_n56` | PMU、Chestnut |
| `charging` | `kc.sn2400` | PMU |
| `chestnut` | `kc.chestnut_kext` | 基础 KC |
| `wifi` | `kc.wifi` | 基础 KC |
| `vibration` | `kc.vibration` | 基础 KC |
| `sep` | `kc.legacy_sep` | 基础 KC |
| `audio` | `kc.audio` | 基础 KC |

## 进阶用法

<details>
<summary><b>构建与启动</b></summary>

```sh
./flash.sh build
./flash.sh boot
```

`flash.sh` 是 n56patcher.py 的封装：自动做 sudo 与设备 DFU 预检、写盘前确认，并用固定的 `build/<target>-latest` 工作目录贯穿各阶段。也可以直接调用 `python3 n56patcher.py build --workdir build/current`。

构建链：

```text
干净 J96 KC → 通用启动补丁 → D2207 PMU 适配（D2186 硬件）→ SN2400 → Chestnut
           → N61 触摸 → Wi-Fi → DRV2604 → SEP 兼容 → CS42L67
           → complzss + watchtower → boot_KC.img4
```

DeviceTree 从本机 12.5.8（N61 iOS 12）与 N66 iOS 13 原始 JSONC 重建。

TrustCache 以 repair-v7 完整集合为基底，加入现场生成的 mrm、最终 Health 库、蓝牙/SEP 服务和组合 dyld cache cdhash。

Health 覆盖层先从 N66 17H35 部署 50 个目标 bundle 的全部非 Mach-O 资源，再覆盖 repair-v7 修复后的二进制，保证 Core Data model、plist、素材和本地化文件完整。

`ui` 覆盖层从 UI donor（4.7" 用 N71，5.5" 用 N66）17H35 部署 Health、电话、Wallet，覆盖所有缺失或内容不同的 iPhone Settings 资源与设置 bundle 二进制，并补齐启动 Logo、App 图标和壁纸；donor 只有 `@3x` 时自动退化到 `@2x`。App 本体只接受 13.7 donor 来源。

干净构建的 KC、iBSS、DeviceTree 与实机启动包逐字节一致；iBEC 内嵌 boot-args，默认已去掉 `serial=3`。需要串口日志时用 `--bootargs` 覆盖。TrustCache 与同一次构建写入的 rootfs 配套，已安装设备继续使用自己的启动包，见[技术结论](docs/conclusions.md#trustcache-配套)。

</details>

<details>
<summary><b>Cherry-pick</b></summary>

```sh
# 查看只选 Wi-Fi、音频时的实际补丁列表
python3 n56patcher.py list --patches kc.wifi,kc.audio
# 构建这两项 KC 补丁
python3 n56patcher.py build --patches kc.wifi,kc.audio --workdir build/wifi-audio
# 按功能选择触摸，自动带入 PMU 和 Chestnut
python3 n56patcher.py build --features core,touch --workdir build/touch
# 默认全功能减去音频
python3 n56patcher.py build --exclude kc.audio --workdir build/no-audio
```

`--patches` 精确选择 KC，rootfs 继续使用 `--features` 的选择。`--patches ''` 生成基础 KC。依赖自动补齐，执行顺序自动安排。

</details>

<details>
<summary><b>分步安装第二系统</b></summary>

卷布局为 `disk0s1s4` SystemB、`disk0s1s5` DataB。

```sh
python3 n56patcher.py ramdisk
python3 n56patcher.py extract-im4m
sudo python3 n56patcher.py install --workdir build/current
python3 n56patcher.py build --workdir build/current
python3 n56patcher.py boot --workdir build/current
```

默认 DataB 启用加密内容保护，安装流程会自动创建 systembag。Cydia 随 `checkra1n` 功能安装，需要联网下载，首次开机约 30 秒后自动完成配置。

安装流程会修正 `installd` 对空 Application 容器集合的处理，使首个免费签名 App 可以完成安装。

覆盖层直接从 SystemA（N61 12.5.8）、UI donor 与 J96 rootfs 生成。IPSW 不在 `ipsw/` 时可显式传入路径：

```sh
sudo python3 n56patcher.py install \
  --n66-ipsw /path/to/iPhone_5.5_13.7_17H35_Restore.ipsw \
  --j96-ipsw /path/to/iPad_64bit_TouchID_13.7_17H35_Restore.ipsw
```

当前 profile 对应 SystemA 16H88（N61）、N66/N71/J96 17H35。流程会检查 build、关键文件摘要和所有字节补丁的原始内容。

</details>

<details>
<summary><b>源码位置</b></summary>

- `targets/`：设备、输入路径、功能选择。
- `patches/kc/`、`patches/dt/`、`patches/rootfs/`：构建与安装步骤。
- `patches/impl/`：实际修改内核、驱动和设备树的源码与 ABI 映射。
- `core/`：依赖排序、路径解析、工具调用、ramdisk 和 APFS。
- `tools/`：固定版本的上游 submodule、初始化和输入导入工具，见 [UPSTREAM.md](tools/UPSTREAM.md)。

</details>

## 作者

**CelestialSayuki（Celestial紗雪）**，电子科技大学电子工程专业在读，Apple 开发者。

| 平台 | 账号 |
| --- | --- |
| GitHub | [@CelestialSayuki](https://github.com/CelestialSayuki) |
| X | [@CelestialSayuki](https://x.com/CelestialSayuki) |
| Telegram | [@CelestialSayuki](https://t.me/CelestialSayuki) |
| Bilibili | [Celestial紗雪](https://space.bilibili.com/514518697) |
| 邮箱 | [CelestialSayuki@qq.com](mailto:CelestialSayuki@qq.com) |
| 个人主页 | [infodrop.cn](https://infodrop.cn) |

## 支持项目

如果这个项目帮到了你，欢迎[打赏支持](DONATE.md)。

## 许可证

本项目以 [GPL-3.0](LICENSE) 授权。`tools/checkra1n-kpf/` 保留上游 PongoOS 的 MIT 协议，见各文件头；submodule 遵循各自上游的协议。仓库不包含 Apple 固件，IPSW 不在本协议授权范围内。
