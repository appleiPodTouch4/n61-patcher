# -*- coding: utf-8 -*-
"""把 J96 触摸 personality 改成目标板（N56 / N61）的匹配名、fll-mval 与合并参数。"""
from core.patch import Patch
from core.impl import transform


class KcMtN56(Patch):
    id = "kc.mt_n56"
    layer = "kc"
    role = "transform"
    feature = "touch"
    scope = "device"
    # 板级数值取自本机 12.5.8 内核：N61 = multi-touch,n61 / 0x17d3 / C1F59,1
    requires = ('kc.pmu_d2186', 'kc.chestnut_kext')
    note = "触摸 personality J96 → 目标板（n56 / n61）"

    def apply(self, ctx, art):
        return transform(ctx, "kc/mt_n56.py", art, "mt")
