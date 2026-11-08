# shellcheck shell=bash
# 工具解析：仓库 tools/ → ${LIOS_BIN}（Legacy-iOS-Kit bin/macos）→ PATH。

tool() {
    local name="$1" var val cand
    var="T_TOOL_$(printf '%s' "$name" | tr '.-' '__')"
    eval "val=\${$var:-}"
    if [ -n "$val" ]; then
        for cand in $val; do
            if [ -x "$REPO/$cand" ]; then
                printf '%s\n' "$REPO/$cand"
                return 0
            fi
        done
    fi
    if [ -n "${LIOS_BIN:-}" ] && [ -x "$LIOS_BIN/$name" ]; then
        printf '%s\n' "$LIOS_BIN/$name"
        return 0
    fi
    cand="$(command -v "$name" 2>/dev/null || true)"
    if [ -n "$cand" ]; then
        printf '%s\n' "$cand"
        return 0
    fi
    die "缺少工具: ${name}（可设 LIOS_BIN=/path/to/Legacy-iOS-Kit/bin/macos）"
}

have_tool() {
    local name="$1"
    tool "$name" >/dev/null 2>&1
}
