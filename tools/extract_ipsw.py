#!/usr/bin/env python3
"""从 ipsw/ 下的 IPSW 生成构建输入，输出到 ipsw/cache/derived/。

输入文件与产物路径由目标清单（targets/<name>.py）声明：

  source_profiles   每个 profile 一个 IPSW（build 用于校验）
  extract.kernels   [profile, IPSW 内条目, 产物相对路径]  解 IM4P → 裸内核
  extract.devicetrees 同上，再转成 JSONC
  extract.copies    [profile, IPSW 内条目, 产物相对路径]  原样拷贝
  extract.wifi      从某个 profile 的 rootfs DMG 取无线固件目录
  extract.iboot     解密 iBSS/iBEC（需设备在 DFU）

因此 n56 与 n61 共用 ipsw/cache/，产物目录互不覆盖。
需要先运行 tools/setup.py（img4 与 devicetree-parse）。
"""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

REPO = Path(__file__).resolve().parents[1]
IMG4 = REPO / 'tools/img4lib/img4'
DT_PARSE = REPO / 'tools/devicetree-parse/devicetree-parse'
OUT = REPO / 'ipsw/cache/derived'


def run(*cmd):
    subprocess.run([str(c) for c in cmd], check=True)


def outputs(target):
    """目标声明的全部派生产物（相对 ipsw/cache/derived）。"""
    spec = target.get('extract', {})
    result = [rel for _, _, rel in spec.get('kernels', ())]
    result += [rel for _, _, rel in spec.get('devicetrees', ())]
    result += [rel for _, _, rel in spec.get('copies', ())]
    wifi = spec.get('wifi')
    if wifi:
        result += [f"{wifi['dest']}/{name}" for name in wifi['files']]
    return result


def extract_member(ipsw, member, work):
    path = work / Path(member).name
    with zipfile.ZipFile(ipsw) as archive, archive.open(member) as source, open(path, 'wb') as dest:
        shutil.copyfileobj(source, dest, 8 * 1024 * 1024)
    return path


def copy_member(ipsw, member, dest, work):
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(extract_member(ipsw, member, work), dest)


def make_kernel(ipsw, member, dest, work):
    src = extract_member(ipsw, member, work)
    dest.parent.mkdir(parents=True, exist_ok=True)
    run(IMG4, '-i', src, '-o', dest)


def make_devicetree(ipsw, member, dest, work):
    im4p = extract_member(ipsw, member, work)
    binary = work / (im4p.stem + '.bin')
    run(IMG4, '-i', im4p, '-o', binary)
    dest.parent.mkdir(parents=True, exist_ok=True)
    with open(dest, 'wb') as f:
        subprocess.run([str(DT_PARSE), str(binary)], stdout=f, check=True)


def copy_wifi(ipsw, entry, srcdir, dest, files, work):
    dmg = extract_member(ipsw, entry, work)
    mountpoint = work / 'rootfs'
    mountpoint.mkdir()
    run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mountpoint, dmg)
    try:
        source_dir = mountpoint / srcdir
        if not source_dir.is_dir():
            raise SystemExit(f'IPSW rootfs 缺少无线固件目录: {srcdir}')
        dest.mkdir(parents=True, exist_ok=True)
        for name in files:
            source = source_dir / name
            if not source.is_file():
                raise SystemExit(f'{srcdir} 缺少 {name}')
            shutil.copy2(source, dest / name)
    finally:
        run('hdiutil', 'detach', mountpoint)


def generate(target, ipsw_for, out=OUT):
    """按目标清单生成派生输入。ipsw_for(profile) → IPSW 绝对路径。"""
    spec = target.get('extract', {})
    if not spec:
        raise SystemExit(f"{target['name']} 未声明 extract 块")
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        for profile, member, rel in spec.get('devicetrees', ()):
            print(f'  DeviceTree  {profile}: {rel}')
            make_devicetree(ipsw_for(profile), member, out / rel, work)
        for profile, member, rel in spec.get('kernels', ()):
            print(f'  Kernel      {profile}: {rel}')
            make_kernel(ipsw_for(profile), member, out / rel, work)
        for profile, member, rel in spec.get('copies', ()):
            print(f'  Copy        {profile}: {rel}')
            copy_member(ipsw_for(profile), member, out / rel, work)
        wifi = spec.get('wifi')
        if wifi:
            print(f"  Wi-Fi       {wifi['profile']}: {wifi['dest']}")
            copy_wifi(ipsw_for(wifi['profile']), wifi['rootfs_entry'], wifi['srcdir'],
                      out / wifi['dest'], wifi['files'], work)
    return out


def decrypt_iboot(target, ipsw, gaster, patcher, out=OUT):
    """解密 iBSS/iBEC 并给 iBSS 打补丁。设备需处于 DFU（密钥由设备 AES 引擎解开）。"""
    spec = target['extract']['iboot']
    dest = out / spec['out_dir']
    dest.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        ibss = extract_member(ipsw, spec['ibss'], work)
        ibec = extract_member(ipsw, spec['ibec'], work)
        run(gaster, 'pwn')
        run(gaster, 'decrypt', ibss, work / 'iBSS.dec')
        run(gaster, 'decrypt', ibec, dest / spec['ibec_name'])
        patched = dest / spec['ibss_name']
        subprocess.run([str(patcher), str(work / 'iBSS.dec'), str(patched)], check=False)
        if not patched.exists():
            raise SystemExit('iBoot64Patcher 未生成 iBSS')


def load_target(name):
    sys.path.insert(0, str(REPO))
    from core.context import load_target as _load
    return _load(name)


def ipsw_resolver(target, overrides):
    def resolve(profile):
        if profile in overrides:
            return Path(overrides[profile])
        entry = target.get('source_profiles', {}).get(profile)
        if not entry:
            raise SystemExit(f'目标清单未声明 profile: {profile}')
        path = REPO / 'ipsw' / entry['ipsw']
        if not path.is_file():
            raise SystemExit(f'找不到 {profile} IPSW: {path}')
        with zipfile.ZipFile(path) as archive:
            restore = plistlib.loads(archive.read('Restore.plist'))
        build = restore.get('ProductBuildVersion') or \
            restore.get('BuildIdentities', [{}])[0].get('Info', {}).get('BuildNumber')
        if entry.get('build') and build != entry['build']:
            raise SystemExit(f"{profile} IPSW build 为 {build}，目标需要 {entry['build']}")
        return path
    return resolve


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--target', default='n56-ios13', help='目标清单名（targets/<name>.py）')
    parser.add_argument('--ipsw', action='append', default=[],
                        metavar='PROFILE=PATH', help='覆盖某个 profile 的 IPSW 路径')
    parser.add_argument('--out', type=Path, default=OUT)
    args = parser.parse_args()
    overrides = dict(item.split('=', 1) for item in args.ipsw)
    target = load_target(args.target)
    generate(target, ipsw_resolver(target, overrides), args.out)
    print('derived inputs ready:', args.out.resolve())


if __name__ == '__main__':
    main()
