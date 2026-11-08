# 纯 bash 版本

同一套流程的 shell 实现，与 Python 版并行维护（Python 版仍是当前完整可用的实现）。

## 进度

| 部分 | 状态 | 说明 |
| --- | --- | --- |
| 框架：参数 / 目标清单 / 工具解析 / 日志 | ✅ | `n61.sh` + `lib/` |
| `list` 补丁选择与排序 | ✅ | 与 Python 版 28 项 ID 序列逐行一致 |
| `status` 卷列举（role / 加密 / 已用） | ✅ | 纯 bash 解析 NXSB/omap/APSB |
| `ramdisk` 引导 + SSH | ✅ | irecovery 链 + iproxy + sshpass |
| `extract-im4m` | ✅ | dd NOR 4MB + img4 -i/-m |
| `volumes` 建卷（含 -P 加密 + SEP） | ✅ | newfs_apfs 经 ramdisk |
| `rootfs` 流式写入 s4 | ✅ | hdiutil -owners + tar 流 |
| 改 role（Fletcher-64） | ✅ | 与 Python 逐位一致，写前备份、写后读回 |
| `patch-rootfs`（overlay + finish + set_roles） | ✅ Phase B | 15 个 overlay 全部接通 |
| `build`：iBSS / iBEC | ✅ Phase C | 与 Python 产物逐字节相同 |
| `build`：DeviceTree | ✅ Phase C | JSON 手术产物作为版本锁定资产，运行期 repack |
| `build`：TrustCache（完整） | ✅ Phase C | 原版 TC ∪ 本次新增 cdhash，重排重写 |
| `build`：KernelCache | ✅ Phase C | 基底 + 8 个变换 + complzss/watchtower/签名 |
| `install` | ✅ | volumes + rootfs + patch-rootfs |
| `all` | ✅ | ramdisk → extract-im4m → install → build |

`build` 已经是纯 bash（唯一的外部依赖是 Xcode 命令行工具的 `cc`，用来编译仓库自带的
`mkcomplzss.c`；以及 Python 工具链一次性派生的 Health 库产物，见下文）。

## 用法

```sh
./n61.sh list                     # 选挂的补丁
./n61.sh ramdisk                  # DFU → 12.5.8 SSH ramdisk
sudo ./n61.sh volumes             # 建 s4/s5（加密需要 SEP）
sudo ./n61.sh rootfs              # 写入 13.7 rootfs（~25 分钟）
sudo ./n61.sh patch-rootfs        # overlay + 收尾 + 改 role
./n61.sh build                    # 构建五个启动组件（boot_*.img4）
./n61.sh status                   # 卷 role / 加密 / 已用
./n61.sh boot                     # 发送已构建的启动链
```

选项与 Python 版一致：`--target --features --patches --exclude --bootargs
--data-protection --workdir --fresh --dry-run --no-identity-check`。
默认工作目录 `build/<target>-latest`，跨阶段复用产物。

## 结构

```text
n61.sh                 入口：参数解析 + 阶段分发
lib/log.sh             输出
lib/target.sh          目标清单加载、IPSW/派生输入/工作目录
lib/tools.sh           工具解析：仓库 tools/ → $LIOS_BIN → PATH
lib/ssh.sh             iproxy + sshpass + 挂卷 + tar 落盘
lib/mounts.sh          donor rootfs 只读挂载（owners 模式 + build 校验）
lib/apfs.sh            原始块读写 / Fletcher-64 / 卷表 / 建卷 / 改 role
lib/overlay.sh         overlay 引擎（copy/delete/bytes-patch + UI/机型清单）
lib/mrm.sh             mrm.plist 重建 + 重签
lib/systembag.sh       systembag 注入
lib/checkra1n.sh       checkra1n 引导 + cydia 安装
lib/patch.sh           补丁选择（awk，等价 core/patch.py）
lib/device.sh          irecovery 链：DFU / pwn / 启动链发送
lib/stage.sh           各阶段实现
lib/bin.sh             二进制原语（perl 辅助的读写/查找/替换）
lib/macho.sh           Mach-O / kernelcache 段表与地址换算
lib/kc.sh              内核缓存补丁链（基底 + 8 个变换 + 打包签名）
lib/kcplist.pl         预链接 plist 段改写（base64 KASLR 表 + 定点插入）
lib/kchash.pl          hashstore 索引解析（645 条）
lib/watchtower.pl      从原 IM4P 取 watchtower 尾部追加到新载荷
lib/dt.sh              DeviceTree（资产 + devicetree-repack + 签 rdtr）
lib/tc.sh              TrustCache 组装（cdhash 收集 + 合并排序）
lib/trustcache.pl      TC v1 读写/合并/排序
targets/n61_ios13.sh   目标清单（纯 shell 变量）
patches/registry.tsv   补丁注册表（Python 版导出的静态数据）
patches/overlays/*.conf overlay 清单（同上，Phase B 消费）
patches/lists/*.paths  UI 资源固定路径表（按 donor 实况展开 @3x/@2x）
patches/blobs.tsv + patches/blobs/*.conf  二进制补丁（偏移 + before/after）
patches/kcdata/        内核阶段改写表与 plist 增量（Phase C 消费）
patches/tcdata/        TrustCache 的 cdhash 清单与 dyld cache 字节补丁
patches/dtdata/        目标板设备树资产（JSONC + 元数据）
```

`patches/registry.tsv`、`patches/overlays/*.conf`、`patches/lists/*.paths`、
`patches/blobs.tsv`、`patches/kcdata/`、`patches/tcdata/`、`patches/dtdata/`
都是**静态数据**，运行时不依赖 Python；改动 Python 补丁定义后需重新导出：

```sh
python3 tools/export_registry.py                 # 注册表 / overlay / 列表 / blobs
python3 tools/export_kcdata.py --chain <黄金链>   # 内核改写表 + TrustCache 数据（带回放校验）
python3 tools/export_dtdata.py                   # 设备树资产（带回放校验）
```

## Phase C 的做法

内核缓存不逐行重写 Mach-O 手术，而是「Python 版跑一次黄金链 → 导出静态数据 →
bash 运行期只贴字节」，每个阶段都带输入/输出 sha256，跑完自校验：

| 阶段 | bash 怎么复现 |
| --- | --- |
| `kc.j96_clean` | `img4 -i` → `KPlooshFinder` → `Kernel64Patcher -b13 -n` → 还原 `0xaa6577`（可选接 checkra1n 合并 + kerninfo） |
| `kc.pmu_d2186` | 真实算法：xref 定位 + 9 步改写 + 每步唯一性/后置校验 |
| `kc.sn2400` / `chestnut_kext` / `vibration` | 改写表 + plist「base64 重写 + 定点插入」 |
| `kc.audio` | 改写表 + plist 整段 gzip blob（Python 侧用 ElementTree 重排过） |
| `kc.mt_n56` | 真实算法：anchor/end 定位 + 模式唯一替换 |
| `kc.wifi` | 真实算法：解析 645 条 hashstore → 写摘要块 → 重定向指针 → 追加 KASLR 槽 |
| `kc.legacy_sep` | 地址表驱动 |
| 打包 | `cc` 编 `mkcomplzss` → `watchtower.pl` 追加尾部 → `img4 -R rkrn` → roundtrip `cmp` |

DeviceTree 的 JSON 手术（节点移植、phandle 重编号）留在 Python 版；产物 JSONC 作为
版本锁定资产（`patches/dtdata/`），运行期用仓库自带的 `devicetree-repack` 打回二进制，
输入/输出都校验 sha256。TrustCache 的 Health 库来自 Python 工具链（`health_toolchain`）
一次性派生的缓存，可用 `N56_HEALTH_LIBS=/path` 指定；缺失时只警告并跳过这几条 cdhash。

## 已验证

- `list`：与 `python3 n56patcher.py list` 的 28 项 ID 序列完全一致（含依赖拓扑顺序）。
- Fletcher-64：5 组随机 4K 块的 `(hi, lo)` 与 `core/apfs.py` 逐位相同；bash 封装的块
  Python 也能通过校验。
- 卷枚举：对 hdiutil 造的裸 APFS 镜像，bash 与 Python 解析到同一卷、同一 block、同一 role。
- 改 role：在镜像上把 role 0→1，写后读回一致，Python 复核 `role=0x1` 且校验和有效。
- 无设备时 `status` 立即报错退出（不空等 SSH 超时）。
- phone_ui 四份清单（设置资源 / 设置二进制 / 启动 UI / App 图标）：合成 fixture 上
  与 Python 版逐行一致，覆盖 Mach-O 判定、`_CodeSignature` 剔除、符号链接剔除、
  目标缺失、同内容跳过、`@3x`/`@2x` 退化与图标命名规则、j96 缺失 App 等边界。
- mrm.plist：与 Python 版语义相等（顶层键、LaunchDaemons、AppExtensions 全部一致）。
- installd / backupd 补丁产物 sha256 与 Python 版相同。
- `build`（Phase C）：
  - `boot_iBSS.img4` / `boot_iBEC.img4` / `boot_DT.img4` 与 Python 黄金产物**逐字节相同**；
  - `boot_KernelCache.img4` 与 Python 参考产物逐字节相同（`2b5e0ba3…`，17,028,728 字节），
    内核链路 9 个阶段全部带 in/out sha256 自校验，checkra1n KPF 合并 8 处一致；
  - `boot_TC.img4` 两次独立构建逐字节相同（确定性）；原版 TC 1830 条 → 2238 条
    （+289 清单 / +2 固定 / +6 profile / +mrm·dyld·installd·backupd·checkra1n·health·N66 界面与设置）。
  - 打包链 roundtrip 校验：`img4 -R rkrn` 后再解出，与输入 raw 内核 `cmp` 相同。

## 约束

- macOS 自带 bash 3.2：不能用关联数组、`${var,,}`、`declare -A`。
  字符串里 `$var` 后紧跟全角标点会被算进变量名，必须写 `${var}`。
- APFS 块读取走 `dd`，缓存放进程级临时目录（`$TMPDIR/n61-apfs.$$`），
  避免跨运行读到过期块；`set_roles` 的原始块备份落在工作目录 `apfs-role-backup/`。
- 绝不挂载 s2（iOS12 加密 Data）：ramdisk 下连只读挂载都会锁死容器。
- `build` 需要 Xcode 命令行工具（`cc` 编译仓库自带的 `mkcomplzss.c`）与
  `hdiutil -owners on`（j96/n66 rootfs 只读挂载；本机实测非 root 也可挂，但要求无残留挂载）。
- bash 里**函数用 `echo` 返回路径 + 函数内 `die`** 是陷阱：`$( )` 里的 `die` 只杀子 shell，
  错误会被上层吞掉，接着拿空路径继续跑。所以 `kc_base` / `dt_build_bin` / `tc_stock` /
  `tc_dyld_cache` 一律用全局变量（`KC_ART` / `DT_BIN` / `TC_STOCK` / `TC_DYLD`）传产物。
- 批量判 Mach-O 用 `bin_macho_list`（一次 `File::Find`），逐文件起 perl 在
  `PrivateFrameworks` 这种上万文件的树上要跑几分钟。
