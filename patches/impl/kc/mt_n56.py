#!/usr/bin/env python3
"""
mtpatch - Retarget the j96 iOS 13 multitouch personality to the target board

The j96 kernelcache only carries the "AppleMultitouchSPI - J96" personality
(codeless kext AppleMultitouchSPIJ96, IOClass AppleMultitouchN1SPI).  Both A8
iPhone boards use the same driver class; per their native iOS 12 kernels only
these values differ:

  key                    J96 (13.7)       N56 (12.5.8)   N61 (12.5.8)
  IONameMatch            multi-touch,j96  multi-touch,n56  multi-touch,n61
  fll-mval               0x17c9           0x17d3           0x17d3
  mt-merge-personality   C1F14,4          C1F5A,1          C1F59,1

fll-mval / register addresses are identical between N56 and N61 (same touch
controller and panel clock); only the match string and the mtprops calibration
key differ.  N61's mtprops top-level key is C1F59,1 (see
usr/share/firmware/multitouch/N61.mtprops).

Only __PRELINK_INFO plist bytes inside the J96 personality are changed, all
replacements are same-length, idempotent and verified afterwards.

Usage: mtpatch in.raw out.raw        (板号由 N56_BOARD 决定，缺省 n56ap)
"""

import os
import sys

ANCHOR = b"<key>AppleMultitouchSPI - J96</key><dict>"

# J96 原值 -> 目标板值（必须等长，就地替换）
PROFILES = {
    "n56ap": [
        (b"<string>multi-touch,j96</string>", b"<string>multi-touch,n56</string>"),
        (b'<key>fll-mval</key><integer size="64">0x17c9</integer>',
         b'<key>fll-mval</key><integer size="64">0x17d3</integer>'),
        (b"<key>mt-merge-personality</key><string>C1F14,4</string>",
         b"<key>mt-merge-personality</key><string>C1F5A,1</string>"),
    ],
    "n61ap": [
        (b"<string>multi-touch,j96</string>", b"<string>multi-touch,n61</string>"),
        (b'<key>fll-mval</key><integer size="64">0x17c9</integer>',
         b'<key>fll-mval</key><integer size="64">0x17d3</integer>'),
        (b"<key>mt-merge-personality</key><string>C1F14,4</string>",
         b"<key>mt-merge-personality</key><string>C1F59,1</string>"),
    ],
}

BOARD = os.environ.get("N56_BOARD", "n56ap")
EDITS = PROFILES[BOARD]


def personality_span(buf):
    start = buf.find(ANCHOR)
    if start < 0 or buf.find(ANCHOR, start + 1) >= 0:
        sys.exit("J96 multitouch personality not found / not unique")
    end = buf.find(b"</dict></dict>", start)
    if end < 0:
        sys.exit("end of J96 multitouch personality not found")
    return start, end


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    buf = bytearray(open(sys.argv[1], "rb").read())
    start, end = personality_span(buf)
    print(f"  board: {BOARD}")
    for old, new in EDITS:
        assert len(old) == len(new), old
        blk = bytes(buf[start:end])
        if blk.count(new) == 1 and blk.count(old) == 0:
            print(f"  already: {new.decode()}")
            continue
        if blk.count(old) != 1:
            sys.exit(f"pattern not unique in personality: {old.decode()}")
        i = start + blk.index(old)
        buf[i:i + len(old)] = new
        print(f"  patched: {new.decode()}")

    blk = bytes(buf[start:end])
    if not all(blk.count(new) == 1 for _, new in EDITS):
        sys.exit("post-check failed")
    open(sys.argv[2], "wb").write(buf)


if __name__ == "__main__":
    main()
