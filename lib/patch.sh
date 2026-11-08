# shellcheck shell=bash
# 补丁选择：读 patches/registry.tsv（由 Python 注册表导出的静态数据）。
#
# 规则与 Python 版 core/patch.py 一致：
#   - base 由目标清单 bases 的 id 指定，每层唯一
#   - kc 层若给了 --patches，则只按 --patches 选 transform
#   - 其余按 feature ∈ features 或 id ∈ patches 选
#   - 选中项自动补齐 requires 依赖
#   - 排序：role 顺序（base<transform<stream<overlay<finalize）+ 同层依赖拓扑

REGISTRY="$REPO/patches/registry.tsv"

select_patches() {   # feats picks exclude base_dt base_kc → "layer\trole\tid\tfeature"
    awk -F'\t' -v feats="$1" -v picks="$2" -v excl="$3" \
        -v base_dt="$4" -v base_kc="$5" '
    function roleorder(r) {
        return r == "base" ? 0 : (r == "transform" ? 1 : (r == "stream" ? 2 : (r == "overlay" ? 3 : 4)))
    }
    # DFS 拓扑：依赖先出，与 Python 版 _topo 一致（只认同层的边）
    function visit(i, arr, k, j, d, di) {
        if (i in SEEN) return
        if (i in TEMP) { print "依赖成环: " ID[i] > "/dev/stderr"; exit 3 }
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
        ORDER[1] = "dt"; ORDER[2] = "kc"; ORDER[3] = "rootfs"
    }
    {
        n++
        L[n] = $1; R[n] = $2; ID[n] = $3; FE[n] = $4; RQ[n] = $6; AF[n] = $7
        IDX[$3] = n
    }
    END {
        for (i = 1; i <= n; i++) {
            if (ID[i] in EXC) continue
            if (R[i] == "base") {
                if ((L[i] == "dt" && ID[i] == base_dt) || (L[i] == "kc" && ID[i] == base_kc)) SEL[i] = 1
                continue
            }
            if (L[i] == "kc" && picks != "") { if (ID[i] in PICK) SEL[i] = 1; continue }
            if ((FE[i] in FEAT) || (ID[i] in PICK)) SEL[i] = 1
        }
        changed = 1
        while (changed) {
            changed = 0
            for (i = 1; i <= n; i++) {
                if (!(i in SEL)) continue
                k = split(RQ[i], Q, ",")
                for (j = 1; j <= k; j++) {
                    d = Q[j]; if (d == "") continue
                    if (!(d in IDX)) { print "未知依赖: " d > "/dev/stderr"; exit 2 }
                    if (!(IDX[d] in SEL)) { SEL[IDX[d]] = 1; changed = 1 }
                }
            }
        }
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
    select_patches "$OPT_FEATURES" "$OPT_PATCHES" "$OPT_EXCLUDE" "$T_BASE_DT" "$T_BASE_KC" |
        awk -F'\t' -v l="$1" -v r="$2" '$1 == l && $2 == r { print $3 }'
}
