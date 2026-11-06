"""Local firmware inputs and per-build outputs shared by implementation scripts.

设备相关路径按 N56_BOARD / N56_MODEL（由 core/impl.py 从目标清单的 device.model 注入）展开，
因此同一套 impl 脚本可以服务 n56ap 与 n61ap 两个目标。
"""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DONORS = Path(os.environ.get('N56_DONORS', ROOT / 'donors'))
DERIVED = Path(os.environ.get('N56_DERIVED', ROOT / 'ipsw/cache/derived'))
WORK = Path(os.environ.get('N56_WORK', ROOT / 'build'))
INPUT = Path(os.environ['N56_INPUT']) if 'N56_INPUT' in os.environ else WORK / 'kc.mt.raw'
OUTPUT = Path(os.environ.get('N56_OUTPUT', WORK))

# 板号 n56ap（iPhone 6 Plus）/ n61ap（iPhone 6）；MODEL 为短名 n56 / n61
BOARD = os.environ.get('N56_BOARD', 'n56ap')
MODEL = os.environ.get('N56_MODEL', BOARD.replace('ap', ''))

# iOS 12.5.8（设备本机）派生输入
KERNEL12 = DERIVED / f'extracted/{BOARD}_ios12/kernelcache.release.iphone7.decompressed'
DT12 = DERIVED / f'extracted/{BOARD}_ios12/DeviceTree.{BOARD}.jsonc'
# iOS 13.7 donor
N66 = DERIVED / 'extracted/n66ap_ios13/kernelcache.release.n66.decompressed'

# 旧名字，保持既有脚本可用
N56 = KERNEL12
