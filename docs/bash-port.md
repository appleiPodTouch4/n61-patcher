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
| `patch-rootfs`（overlay + finish） | ⬜ Phase B | 13 个 overlay 清单已导出到 `patches/overlays/` |
| `build`（iBSS/iBEC/DT/TC/KC） | ⬜ Phase C | KC/DT 的二进制变换尚未移植 |
| `install` / `all` | ⚠ | 依赖上两行 |

Phase B/C 完成前，用 Python 版跑这两段，产物与 bash 版共用工作目录即可衔接。

## 用法

```sh
./n61.sh list                     # 选挂的补丁
./n61.sh ramdisk                  # DFU → 12.5.8 SSH ramdisk
sudo ./n61.sh volumes             # 建 s4/s5（加密需要 SEP）
sudo ./n61.sh rootfs              # 写入 13.7 rootfs（~25 分钟）
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
lib/apfs.sh            原始块读写 / Fletcher-64 / 卷表 / 建卷 / 改 role
lib/patch.sh           补丁选择（awk，等价 core/patch.py）
lib/device.sh          irecovery 链：DFU / pwn / 启动链发送
lib/stage.sh           各阶段实现
targets/n61_ios13.sh   目标清单（纯 shell 变量）
patches/registry.tsv   补丁注册表（Python 版导出的静态数据）
patches/overlays/*.conf overlay 清单（同上，Phase B 消费）
```

`patches/registry.tsv` 与 `patches/overlays/*.conf` 是**静态数据**，运行时不依赖
Python；改动 Python 补丁定义后需重新导出（见 `tools/export_registry.py`）。

## 已验证

- `list`：与 `python3 n56patcher.py list` 的 28 项 ID 序列完全一致（含依赖拓扑顺序）。
- Fletcher-64：5 组随机 4K 块的 `(hi, lo)` 与 `core/apfs.py` 逐位相同；bash 封装的块
  Python 也能通过校验。
- 卷枚举：对 hdiutil 造的裸 APFS 镜像，bash 与 Python 解析到同一卷、同一 block、同一 role。
- 改 role：在镜像上把 role 0→1，写后读回一致，Python 复核 `role=0x1` 且校验和有效。
- 无设备时 `status` 立即报错退出（不空等 SSH 超时）。

## 约束

- macOS 自带 bash 3.2：不能用关联数组、`${var,,}`、`declare -A`。
  字符串里 `$var` 后紧跟全角标点会被算进变量名，必须写 `${var}`。
- APFS 块读取走 `dd`，缓存放进程级临时目录（`$TMPDIR/n61-apfs.$$`），
  避免跨运行读到过期块；`set_roles` 的原始块备份落在工作目录 `apfs-role-backup/`。
- 绝不挂载 s2（iOS12 加密 Data）：ramdisk 下连只读挂载都会锁死容器。
