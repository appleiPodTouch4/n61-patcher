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

ssh_argv() {
    printf '%s\0' "$(tool sshpass)" -p "$SSH_PW" ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 -p "$SSH_PORT" root@localhost
}

proxy_start() {
    pgrep -x iproxy >/dev/null 2>&1 && return 0
    "$(tool iproxy)" "$SSH_PORT" 22 >/dev/null 2>&1 &
    sleep 2
}

# ssh_run <cmd>   （stdin/stdout 直通，二进制安全）
ssh_run() {
    "$(tool sshpass)" -p "$SSH_PW" ssh \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 \
        -p "$SSH_PORT" root@localhost "$@"
}

ssh_alive() { ssh_run true >/dev/null 2>&1; }

ssh_wait() {
    local tries="${1:-120}" i=0
    proxy_start
    if ssh_alive; then
        ok "ramdisk SSH 已连通。"
        return 0
    fi
    # 设备完全不在（既不是 DFU 也不是 ramdisk）时立刻报错，不要白等两分钟
    if ! devices_present; then
        die "未检测到设备：请确认已连接；status/volumes/patch-rootfs 需要先进入 ramdisk（./n61.sh ramdisk）"
    fi
    while [ "$i" -lt "$tries" ]; do
        if ssh_alive; then
            ok "ramdisk SSH 已连通。"
            return 0
        fi
        i=$(( i + 1 ))
        sleep 1
    done
    die "ramdisk SSH 不通（ramdisk 可能未起来，先执行 ./n61.sh ramdisk）"
}

ssh_ensure() {
    proxy_start
    ssh_alive || ssh_wait
}

# 远端命令，失败即中止；stdout 透传
rsh() {
    local cmd="$1" out rc=0
    out="$(ssh_run "$cmd" 2>"$WORK/.ssh-err")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        die "远端命令失败($rc): $cmd
$(cat "$WORK/.ssh-err" 2>/dev/null)"
    fi
    printf '%s' "$out"
}

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

# SEP：ramdisk 启动时未加载，加密建卷与 systembag 依赖它（需已只读挂载 /mnt1）
ensure_sep() {
    local ping='/usr/libexec/seputil --ping 2>&1'
    ssh_run "$ping" 2>/dev/null | grep -q "ping failed" || return 0
    log "加载原生 SEP 固件…"
    ssh_run "/usr/libexec/seputil --load \"/mnt1/usr/standalone/firmware/sep-firmware.img4\"" >/dev/null 2>&1 || true
    if ssh_run "$ping" 2>/dev/null | grep -q "ping failed"; then
        warn "SEP 加载后仍无响应，后续加密操作可能卡住。"
    fi
}

# 本地文件/目录 → 设备（流式 tar，不生成中间包；目录可指定属主）
deploy_path() {
    local src="$1" dest="$2" uid="${3:-}" gid="${4:-}" rc_producer rc_consumer
    src="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"
    if [ -d "$src" ]; then
        rsh "mkdir -p \"$dest\""
        COPYFILE_DISABLE=1 /usr/bin/tar --no-xattrs ${uid:+--uid "$uid"} ${gid:+--gid "$gid"} \
            -cpf - -C "$src" . \
            | ssh_run "/usr/bin/tar --numeric-owner -xpf - -C \"$dest\""
        ssh_run "test -d \"$dest\"" || die "部署目录失败: $dest"
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

