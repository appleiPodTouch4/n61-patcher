# shellcheck shell=bash
# ramdisk SSH 会话：iproxy + sshpass + 挂卷 + tar 落盘。
#
# 约束（沿用 Python 版踩过的坑）：
#   - 端口 2222→22（iproxy），密码 alpine。
#   - 挂载点：s1→/mnt1(只读)、s4→/mnt6、s5→/mnt7。
#   - 绝不挂载 s2（iOS12 加密 Data）：连只读挂载都会锁死容器。
#   - 远端 tar 后不接 | head（SIGPIPE 会杀 tar）；解包一律 --numeric-owner。

SSH_PORT="${T_RAMDISK_PORT:-2222}"
SSH_PW="${T_RAMDISK_PASSWORD:-alpine}"
IPROXY_PID=""

ssh_argv() {
    printf '%s\0' "$(tool sshpass)" -p "$SSH_PW" ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 -p "$SSH_PORT" root@localhost
}

proxy_start() {
    pgrep -x iproxy >/dev/null 2>&1 && return 0
    "$(tool iproxy)" "$SSH_PORT" 22 >/dev/null 2>&1 &
    IPROXY_PID=$!
    # disown：不让 bash 把 iproxy 当作业管理，退出清理时不会打印 "Terminated" 噪音
    disown 2>/dev/null || true
    sleep 2
}

# 重启 iproxy：处理上一次运行残留 / 端口被陈旧进程占用
proxy_restart() {
    if [ -n "${IPROXY_PID:-}" ]; then
        kill "$IPROXY_PID" 2>/dev/null || true
        wait "$IPROXY_PID" 2>/dev/null || true
    fi
    pkill -x iproxy 2>/dev/null || true
    sleep 1
    IPROXY_PID=""
    proxy_start
}

# 带看门狗的命令执行：secs<=0 表示不超时；超时返回 124（避免远端命令卡死整个流程）
run_timeout() {   # secs cmd...
    local secs="$1"; shift
    local pid wd rc=0
    if [ "$secs" -le 0 ]; then
        "$@"
        return $?
    fi
    "$@" &
    pid=$!
    ( sleep "$secs"; kill "$pid" 2>/dev/null; sleep 5; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    wd=$!
    wait "$pid" 2>/dev/null || rc=$?
    kill "$wd" 2>/dev/null || true
    wait "$wd" 2>/dev/null || true
    [ "$rc" -eq 143 ] && return 124
    return "$rc"
}

# ssh_run <cmd>   （stdin/stdout 直通，二进制安全）
ssh_run() {
    "$(tool sshpass)" -p "$SSH_PW" ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 \
        -p "$SSH_PORT" root@localhost "$@"
}

# 带超时的远端命令（stdin/stdout/stderr 直通，适合 dd/加载固件这类可能卡住的命令）
ssh_run_timeout() {   # secs cmd
    local secs="$1"; shift
    run_timeout "$secs" "$(tool sshpass)" -p "$SSH_PW" ssh -n \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 \
        -p "$SSH_PORT" root@localhost "$@"
}

ssh_alive() {
    # 探测用短超时：iproxy 在但没有 ramdisk 时，长超时会让等待变得很慢
    "$(tool sshpass)" -p "$SSH_PW" ssh -n \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=3 \
        -p "$SSH_PORT" root@localhost true >/dev/null 2>&1
}

# ssh_wait [tries] [boot]
#   刚发完 ramdisk 启动链时用 boot=1：设备会短暂仍被 irecovery 看到，不能据此判定失败；
#   之后若 irecovery 还看得到设备，说明启动链没成功。
#   其他情况（status/volumes 等）boot=0：一开始就看到设备停在 DFU/recovery 时立即报错。
ssh_wait() {
    local tries="${1:-120}" boot="${2:-0}" i=0 last=""
    proxy_start
    if ssh_alive; then
        ok "ramdisk SSH 已连通。"
        return 0
    fi
    if [ "$boot" -eq 0 ] && device_in_recovery; then
        die "设备还在 DFU/recovery，尚未进入 ramdisk：先跑 ./n61.sh ramdisk（或确认 ramdisk 已启动）"
    fi
    log "等待 ramdisk SSH…（最多 ${tries}s）"
    while [ "$i" -lt "$tries" ]; do
        if ssh_alive; then
            ok "ramdisk SSH 已连通。"
            return 0
        fi
        i=$(( i + 1 ))
        if [ "$boot" -eq 1 ] && [ "$i" -eq 40 ] && device_in_recovery; then
            die "发送 ramdisk 后 40s 设备仍停在 DFU/recovery：启动链可能没成功，重跑 ./n61.sh ramdisk"
        fi
        if [ "$i" -eq 60 ]; then
            warn "SSH 60s 未通，重启 iproxy 后继续等待…"
            proxy_restart
        fi
        if [ $(( i % 10 )) -eq 0 ]; then
            log "  仍在等待 SSH…（${i}s）"
        fi
        sleep 1
    done
    last="$(ssh_run true 2>&1 | tail -3 || true)"
    die "ramdisk SSH 不通（${tries}s）。
  确认设备屏幕已进入 SSHRD ramdisk、USB 连接正常、没有别的程序占用端口 ${SSH_PORT}。
  最近 SSH 错误: ${last:-无输出}"
}

ssh_ensure() {
    proxy_start
    ssh_alive || ssh_wait
}

# 远端命令，失败即中止；stdout 透传。secs>0 时超时返回 124。
rsh_timeout() {   # secs cmd
    local secs="$1" cmd="$2" out rc=0
    out="$(ssh_run_timeout "$secs" "$cmd" 2>"$WORK/.ssh-err")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 124 ]; then
            die "远端命令超时（${secs}s）: ${cmd}
$(cat "$WORK/.ssh-err" 2>/dev/null)
  若这是 newfs_apfs，容器可能已被锁住：请重启设备进 DFU 后重试。"
        fi
        die "远端命令失败($rc): $cmd
$(cat "$WORK/.ssh-err" 2>/dev/null)"
    fi
    printf '%s' "$out"
}

rsh() { rsh_timeout 0 "$1"; }

rsh_ok() { ssh_run "$1" >/dev/null 2>&1; }

slices() { rsh "ls /dev/disk0s1s*" | tr '\n' ' '; }

mount_vol() {   # n mnt [ro]
    local n="$1" mnt="$2" ro="${3:-}"
    local opt=""
    [ "$ro" = "ro" ] && opt="-o ro "
    rsh "/sbin/mount | /usr/bin/grep -q \"disk0s1s$n on $mnt\" || /sbin/mount_apfs ${opt}/dev/disk0s1s$n $mnt"
}

umount_vols() {
    local m
    for m in "$@"; do
        ssh_run "/sbin/umount $m" >/dev/null 2>&1 || true
    done
}

sync_dev() { ssh_run sync >/dev/null 2>&1 || true; }

# SEP 是否可用：seputil 失败时可能打印 "ping failed" / "Failed to connect to sep" /
# "No SEP present on this device" 等，任一出现或退出码非 0 都算不可用。
# 注意：不能只 grep "ping failed"（实测别的失败文案会被误判成"SEP 就绪"，随后 -P 卡死）。
sep_ping_ok() {
    local out rc=0
    out="$(ssh_run '/usr/libexec/seputil --ping 2>&1' 2>/dev/null)" || rc=$?
    log "  SEP ping: rc=${rc}${out:+ → $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)}"
    [ "$rc" -eq 0 ] || return 1
    case "$out" in
        *"ping failed"*|*"Failed to connect"*|*"No SEP present"*|*"ERROR"*|*"error"*) return 1 ;;
    esac
    return 0
}

# SEP：ramdisk 启动时未加载，加密建卷与 systembag 依赖它（需已只读挂载 /mnt1）
ensure_sep() {
    local fw="/usr/standalone/firmware/sep-firmware.img4"
    if sep_ping_ok; then
        return 0
    fi
    log "加载原生 SEP 固件…"
    ssh_run "test -f \"/mnt1${fw}\"" >/dev/null 2>&1 ||
        die "缺少 /mnt1${fw}：iOS12 SystemA 是否已只读挂载到 /mnt1？"
    ssh_run_timeout 90 "/usr/libexec/seputil --load \"/mnt1${fw}\"" >/dev/null 2>&1 || true
    if sep_ping_ok; then
        log "SEP 已就绪。"
        return 0
    fi
    die "SEP 仍不可用（seputil --ping 失败）。
  此时执行 newfs_apfs -P 会卡死并锁死容器，已中止。
  处理：重启设备 → 重新进 DFU → 重跑 ./n61.sh ramdisk；
  不想用加密 DataB 可改 --data-protection none（需要 state/keybags.tar）。"
}

# 本地文件/目录 → 设备（流式 tar，不生成中间包；目录可指定属主）
deploy_path() {
    local src="$1" dest="$2" uid="${3:-}" gid="${4:-}" rc=0
    src="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"
    if [ -d "$src" ]; then
        rsh "mkdir -p \"$dest\""
        COPYFILE_DISABLE=1 /usr/bin/tar --no-xattrs ${uid:+--uid "$uid"} ${gid:+--gid "$gid"} \
            -cpf - -C "$src" . \
            | ssh_run "/usr/bin/tar --numeric-owner -xpf - -C \"$dest\"" || rc=$?
        [ "$rc" -eq 0 ] || die "部署目录失败（tar 退出码 ${rc}）: $src → $dest"
        ssh_run "test -d \"$dest\"" || die "部署目录失败（目标不存在）: $dest"
    else
        deploy_file "$src" "$dest"
    fi
}

# 本地文件 → 设备指定路径（目标文件名可与源不同，如 mrm.plist.sig）
deploy_file() {
    local src="$1" dest="$2"
    rsh "mkdir -p \"$(dirname "$dest")\""
    ssh_run "cat > \"$dest\"" <"$src" || die "部署文件失败: $src → $dest"
    ssh_run "test -s \"$dest\"" || die "部署文件后为空: $dest"
}

# 按相对路径清单从本地 root 流式部署（tar -T，避免 argv 过长）
deploy_relative_paths() {   # root dest listfile
    local root="$1" dest="$2" list="$3"
    [ -s "$list" ] || { log "  （清单为空，跳过）"; return 0; }
    root="$(cd "$root" && pwd)"
    rsh "mkdir -p \"$dest\""
    COPYFILE_DISABLE=1 /usr/bin/tar --no-xattrs -cpf - -C "$root" -T "$list" \
        | ssh_run "/usr/bin/tar --numeric-owner -xpf - -C \"$dest\"" ||
        die "文件集流式写入失败: $(wc -l <"$list" | tr -d ' ') 项 → $dest"
}

# 设备 → 本地
pull_file() {   # remote local
    mkdir -p "$(dirname "$2")"
    ssh_run "cat \"$1\"" >"$2" || die "读取设备文件失败: $1"
    [ -s "$2" ] || die "读取设备文件为空: $1"
}

# 设备文件区间读成十六进制串（od 在本地做，避免二进制过 shell 变量丢 NUL）
read_hex() {   # remote offset len
    ssh_run "dd if=\"$1\" bs=1 skip=$2 count=$3 2>/dev/null" | od -An -v -tx1 | tr -d ' \n'
}

# 十六进制串写回设备文件区间（printf %b 解释 \xNN，二进制安全）
write_hex() {   # remote offset hex
    local esc="" i=0 hex="$3"
    while [ "$i" -lt "${#hex}" ]; do
        esc="$esc\\x${hex:$i:2}"
        i=$(( i + 2 ))
    done
    printf '%b' "$esc" | ssh_run "dd of=\"$1\" bs=1 seek=$2 conv=notrunc 2>/dev/null"
}

