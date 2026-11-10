# shellcheck shell=bash
# 设备链：irecovery 查询 / DFU 等待 / pwn / 发送启动链。

irec() { "$(tool irecovery)" "$@"; }

device_query() { irec -q 2>/dev/null || true; }

device_in_dfu() { device_query | grep -q "MODE: DFU"; }

devices_present() { device_query | grep -q "CPID"; }
device_in_recovery() { device_query | grep -qE "MODE: (DFU|Recovery)"; }

wait_dfu() {
    local timeout="${N61_DFU_TIMEOUT:-900}" waited=0
    have_tool irecovery || die "缺少工具: irecovery（先跑 tools/setup.py 或设 LIOS_BIN）"
    if [ "$timeout" -gt 0 ]; then
        log "等待设备进入 DFU（关机后按住 Home+电源，最长 ${timeout}s）…"
    else
        log "等待设备进入 DFU（关机后按住 Home+电源）…"
    fi
    while :; do
        device_in_dfu && return 0
        if [ "$timeout" -gt 0 ] && [ "$waited" -ge "$timeout" ]; then
            die "等待 DFU 超时（${timeout}s）：确认设备已连接并进入 DFU；可用 N61_DFU_TIMEOUT=秒数 调整（0 = 无限等待）"
        fi
        sleep 1
        waited=$(( waited + 1 ))
        if [ $(( waited % 30 )) -eq 0 ]; then
            log "仍在等待 DFU…（${waited}s）"
        fi
    done
}

need_dfu() {
    device_in_dfu && return 0
    wait_dfu
}

pwn_device() {
    local q g
    q="$(device_query)"
    if ! printf '%s' "$q" | grep -q "PWND"; then
        log "gaster pwn…"
        "$(tool gaster)" pwn || die "gaster pwn 失败"
    fi
    log "gaster reset…"
    "$(tool gaster)" reset >/dev/null 2>&1 || true
    sleep 1
}

# 发送 iOS12.5.8 SSH ramdisk 启动链
send_ramdisk_chain() {
    local dir img name i n
    dir="$REPO/$T_RAMDISK_DIR"
    img() { printf '%s\n' "$dir/$1.img4"; }
    for name in iBSS iBEC ramdisk devicetree trustcache kernelcache; do
        [ -f "$(img "$name")" ] || die "缺少 ramdisk 组件: $dir/$name.img4"
    done

    need_dfu
    pwn_device
    step 1 6 "发送 iBSS";             irec -f "$(img iBSS)" >/dev/null; sleep 2
    step 2 6 "发送 iBEC";             irec -f "$(img iBEC)" >/dev/null; sleep 3
    if [ -f "$(img logo)" ]; then
        irec -f "$(img logo)" >/dev/null 2>&1 || true
        irec -c "setpicture 0x1" >/dev/null 2>&1 || true
    fi
    step 3 6 "发送 Ramdisk";          irec -f "$(img ramdisk)" >/dev/null; irec -c ramdisk >/dev/null; sleep 1
    step 4 6 "发送 DeviceTree";       irec -f "$(img devicetree)" >/dev/null; irec -c devicetree >/dev/null; sleep 1
    step 5 6 "发送 TrustCache";       irec -f "$(img trustcache)" >/dev/null; irec -c firmware >/dev/null; sleep 1
    step 6 6 "发送 KernelCache + bootx"
    irec -f "$(img kernelcache)" >/dev/null
    irec -c bootx >/dev/null
    log "ramdisk 启动链已发送，等待 SSH 就绪…"
    ssh_wait 180 1
}

# 设备身份校验（boot 前）
identity_guard() {
    local q short
    [ "${OPT_NO_IDENTITY:-0}" -eq 1 ] && return 0
    q="$(device_query)"
    printf '%s' "$q" | grep -qi "$T_MODEL" || \
        die "连接的设备不是 ${T_MODEL}（irecovery -q 未匹配）。加 --no-identity-check 跳过。"
    short="$(printf '%s' "$T_ECID" | tr 'A-Z' 'a-z' | sed 's/^0x//; s/^0*//')"
    if [ -n "$short" ]; then
        printf '%s' "$q" | tr 'A-Z' 'a-z' | grep -q "$short" || \
            warn "ECID 未匹配清单 ${T_ECID}；请确认是目标 ${T_MODEL}。"
    fi
}

# 发送已构建的 iOS13 启动链（iBSS→iBEC→DT→TC→KC→bootx）
send_boot_chain() {
    local iBSS iBEC DT TC KC
    iBSS="$(wk boot_iBSS.img4)"; iBEC="$(wk boot_iBEC.img4)"
    DT="$(wk boot_DT.img4)";     TC="$(wk boot_TC.img4)"; KC="$(wk boot_KC.img4)"
    for f in "$iBSS" "$iBEC" "$DT" "$TC" "$KC"; do
        [ -f "$f" ] || die "缺少 $(basename "$f")：先在 $WK 构建（./n61.sh build）"
    done
    need_dfu
    identity_guard

    step 1 7 "准备 DFU（gaster pwn/reset）"
    pwn_device
    step 2 7 "发送 iBSS";      irec -f "$iBSS" >/dev/null; sleep 3
    step 3 7 "发送 iBEC";      irec -f "$iBEC" >/dev/null; sleep 3
    step 4 7 "发送 DeviceTree"; irec -f "$DT" >/dev/null; irec -c devicetree >/dev/null; sleep 1
    step 5 7 "发送 TrustCache"; irec -f "$TC" >/dev/null; irec -c firmware >/dev/null; sleep 1
    step 6 7 "发送 KernelCache"; irec -f "$KC" >/dev/null
    step 7 7 "启动 iOS13（bootx）"; irec -c bootx >/dev/null
    ok "启动链已全部发送，观察设备屏幕。"
}
