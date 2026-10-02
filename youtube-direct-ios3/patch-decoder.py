#!/usr/bin/env python3
"""Enable FFmpeg 2.8's CABAC assembly on ARM11 without ARMv6T2 opcodes.

The original LGPL-2.1-or-later routine and copyright header remain in place.
ARM-mode conditional instructions replace Thumb IT blocks; a two-instruction
constant replaces MOVW. Byte loads also support odd bytestream addresses on ARM11.
"""
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) / "libavcodec/arm/cabac.h"
original = path.read_text()
if "YT_ARM11_CABAC" in original:
    sys.exit(0)
assert "#if HAVE_ARMV6T2_INLINE" in original
text = original.replace("#if HAVE_ARMV6T2_INLINE", "// YT_ARM11_CABAC: A32 code uses only ARMv6 instructions.\n#if HAVE_ARMV6_INLINE && !defined(__thumb__)")
# The C decoder keeps the MPS range when low is exactly the boundary too.
text = text.replace("movgt", "movcs")
lines = []
for line in text.splitlines(keepends=True):
    if any(f'"{op} ' in line for op in ("it", "itt")):
        continue
    if '"ldr        %[r_b]        , [%[c], %[end]]' in line:
        continue
    if '"ldrh ' in line:
        # r_b is needed as the end pointer only in the checked reader; reload
        # it immediately before the compare, after using it as byte scratch.
        lines.extend([
            '        "ldrb       %[tmp]        , [%[r_c]]                    \\n\\t"\n',
            '        "ldrb       %[r_b]        , [%[r_c], #1]                \\n\\t"\n',
            '        "orr        %[tmp]        , %[tmp], %[r_b], lsl #8     \\n\\t"\n',
        ])
        continue
    if '"cmp        %[r_c]        , %[r_b]' in line:
        lines.append('        "ldr        %[r_b]        , [%[c], %[end]]              \\n\\t"\n')
    if '"movw ' in line:
        lines.extend([
            '        "mvn        %[r_b]        , #0                          \\n\\t"\n',
            '        "lsr        %[r_b]        , %[r_b], #16                \\n\\t"\n',
        ])
        continue
    lines.append(line)
path.write_text("".join(lines))
