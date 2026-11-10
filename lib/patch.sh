# shellcheck shell=bash
# 补丁选择：读 patches/registry.tsv（由 Python 注册表导出的静态数据）。
#
# 规则与 Python 版 core/patch.py 一致：
#   - base 由目标清单 bases 的 id 指定，每层唯一
#   - kc 层若给了 --patches（含空串），则只按 --patches 选 transform（空串 = 只留 base）
#   - 其余按 feature ∈ features / id ∈ 清单 patches / id ∈ --patches 选
#   - 选中项自动补齐 requires 依赖；依赖被 exclude 排除或与 bases 冲突时报错
#   - 未知 patch / 未知 feature 直接报错（不再静默忽略）
#   - 排序：role 顺序（base<transform<stream<overlay<finalize）+ 同层依赖拓扑
#
# registry.tsv 列：layer role id feature scope requires after manual note

REGISTRY="$REPO/patches/registry.tsv"

select_patches() {   # feats picks exclude base_dt base_kc [picks_set] [want_ids]
    local feats="$1" picks="$2" excl="$3" base_dt="$4" base_kc="$5"
    local picks_set="${6:-0}" want="${7:-}"
    [ -f "$REGISTRY" ] || die "缺少补丁注册表: $REGISTRY"
    awk -F'\t' -v feats="$feats" -v picks="$picks" -v excl="$excl" \
        -v base_dt="$base_dt" -v base_kc="$base_kc" \
        -v picks_set="$picks_set" -v want="$want" '
    function fail(msg) { print "补丁选择: " msg > "/dev/stderr"; exit 4 }
    function roleorder(r) {
        return r == "base" ? 0 : (r == "transform" ? 1 : (r == "stream" ? 2 : (r == "overlay" ? 3 : 4)))
    }
    # DFS 拓扑：依赖先出，与 Python 版 _topo 一致（只认同层的边）
    function visit(i, arr, k, j, d, di) {
        if (i in SEEN) return
        if (i in TEMP) fail("依赖成环: " ID[i])
        TEMP[i] = 1
        k = split(RQ[i] "," AF[i], arr, ",")
        for (j = 1; j <= k; j++) {
            d = arr[j]; if (d == "") continue
            if (!(d in IDX)) continue
            di = IDX[d]
            if (L[di] != CURLAYER || !(di in SEL)) continue
            visit(di)
        }
        delete TEMP[i]
        SEEN[i] = 1
        OUT[++ON] = i
    }
    BEGIN {
        nf = split(feats, F, " "); for (i = 1; i <= nf; i++) if (F[i] != "") FEAT[F[i]] = 1
        np = split(picks, P, " "); for (i = 1; i <= np; i++) if (P[i] != "") PICK[P[i]] = 1
        ne = split(excl, E, " ");  for (i = 1; i <= ne; i++) if (E[i] != "") EXC[E[i]] = 1
        nw = split(want, W, " ");  for (i = 1; i <= nw; i++) if (W[i] != "") WANT[W[i]] = 1
        ORDER[1] = "dt"; ORDER[2] = "kc"; ORDER[3] = "rootfs"
    }
    {
        n++
        L[n] = $1; R[n] = $2; ID[n] = $3; FE[n] = $4
        RQ[n] = $6; AF[n] = $7; MAN[n] = $8
        IDX[$3] = n
        KNOWN_FEAT[$4] = 1
    }
    END {
        # ---- 配置校验：与 core/patch.py 的 die 行为对齐 ----
        for (x in PICK) if (!(x in IDX)) fail("未知 patch（--patches）: " x)
        for (x in WANT) if (!(x in IDX)) fail("未知 patch（清单 patches）: " x)
        for (x in EXC)  if (!(x in IDX)) fail("未知 patch（--exclude）: " x)
        for (f in FEAT) if (!(f in KNOWN_FEAT)) fail("未知 feature: " f)
        for (x in PICK) {
            i = IDX[x]
            if (L[i] != "kc" || R[i] == "base") fail("--patches 只接受 KC transform: " x)
        }
        if (!(base_dt in IDX)) fail("清单 bases 里的 dt base 不存在: " base_dt)
        if (!(base_kc in IDX)) fail("清单 bases 里的 kc base 不存在: " base_kc)

        # ---- 初选 ----
        for (i = 1; i <= n; i++) {
            if (ID[i] in EXC) continue
            if (R[i] == "base") {
                if ((L[i] == "dt" && ID[i] == base_dt) || (L[i] == "kc" && ID[i] == base_kc)) SEL[i] = 1
                continue
            }
            # --patches 一旦给出（含空串）就完全接管 KC transform 选择
            if (L[i] == "kc" && picks_set == "1") { if (ID[i] in PICK) SEL[i] = 1; continue }
            if ((FE[i] in FEAT) || (ID[i] in PICK) || (ID[i] in WANT)) SEL[i] = 1
        }

        # ---- requires 闭包：依赖必须存在、不能与 exclude/bases 冲突 ----
        changed = 1
        while (changed) {
            changed = 0
            for (i = 1; i <= n; i++) {
                if (!(i in SEL)) continue
                k = split(RQ[i], Q, ",")
                for (j = 1; j <= k; j++) {
                    d = Q[j]; if (d == "") continue
                    if (!(d in IDX)) fail("未知依赖: " d "（" ID[i] " 需要）")
                    di = IDX[d]
                    if (R[di] == "base" &&
                        ((L[di] == "dt" && ID[di] != base_dt) || (L[di] == "kc" && ID[di] != base_kc)))
                        fail(ID[i] " 需要基底 " d "，与清单 bases 冲突")
                    if (d in EXC)
                        fail(ID[i] " 需要 " d "（被 exclude 排除），请调整 exclude")
                    if (!(di in SEL)) { SEL[di] = 1; changed = 1 }
                }
            }
        }
        if (!(IDX[base_dt] in SEL)) fail("dt base 被 exclude 排除: " base_dt)
        if (!(IDX[base_kc] in SEL)) fail("kc base 被 exclude 排除: " base_kc)

        # ---- 输出（顺序与 Python 版一致）----
        for (o = 1; o <= 3; o++) {
            layer = ORDER[o]; CURLAYER = layer; m = 0
            for (i = 1; i <= n; i++) if ((i in SEL) && L[i] == layer) { m++; C[m] = i }
            # 先按 role 稳定排序（与 Python 的 group.sort 一致）
            for (a = 2; a <= m; a++) {
                v = C[a]; b = a - 1
                while (b >= 1 && roleorder(R[C[b]]) > roleorder(R[v])) { C[b + 1] = C[b]; b-- }
                C[b + 1] = v
            }
            # DFS 拓扑
            split("", SEEN); split("", OUT); ON = 0
            for (a = 1; a <= m; a++) visit(C[a])
            # 再按 role 稳定排序（保留拓扑结果内的相对顺序）
            for (a = 2; a <= ON; a++) {
                v = OUT[a]; b = a - 1
                while (b >= 1 && roleorder(R[OUT[b]]) > roleorder(R[v])) { OUT[b + 1] = OUT[b]; b-- }
                OUT[b + 1] = v
            }
            for (a = 1; a <= ON; a++) printf "%s\t%s\t%s\t%s\n", L[OUT[a]], R[OUT[a]], ID[OUT[a]], FE[OUT[a]]
        }
    }' "$REGISTRY"
}

# 某层某 role 的补丁 id 列表
patches_of() {   # layer role
    select_patches "$OPT_FEATURES" "$OPT_PATCHES" "$OPT_EXCLUDE" "$T_BASE_DT" "$T_BASE_KC" \
        "${OPT_PATCHES_SET:-0}" "${T_PATCHES:-}" |
        awk -F'\t' -v l="$1" -v r="$2" '$1 == l && $2 == r { print $3 }'
}

# 补丁说明（registry.tsv 第 9 列）
patch_note() {
    awk -F'\t' -v id="$1" '$3 == id { print $9; exit }' "$REGISTRY"
}

# 是否标记为 manual（第 8 列；1 = 需要 --allow-manual）
patch_manual() {
    awk -F'\t' -v id="$1" '$3 == id { print ($8 == "1") ? 1 : 0; exit }' "$REGISTRY"
}
