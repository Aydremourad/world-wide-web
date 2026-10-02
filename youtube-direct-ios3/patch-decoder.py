#!/usr/bin/env python3
"""Enable FFmpeg 2.8's CABAC assembly on ARM11 without ARMv6T2 opcodes.

The original LGPL-2.1-or-later routine and copyright header remain in place.
ARM-mode conditional instructions replace Thumb IT blocks; a two-instruction
constant replaces MOVW. Byte loads also support odd bytestream addresses on ARM11.
"""
import pathlib
import sys
import shutil

path = pathlib.Path(sys.argv[1]) / "libavcodec/arm/cabac.h"
original = path.read_text()
if "YT_ARM11_CABAC" not in original:
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


# Install independently of the CABAC marker so cached sources can be upgraded.
arm = pathlib.Path(sys.argv[1]) / "libavcodec/arm"
for name in ("decoder-arm11-motion.h", "decoder-arm11-idct.h"):
    shutil.copyfile(pathlib.Path(__file__).parent / name, arm / name)
for name, header, call, anchor in (
    ("h264qpel_init_arm.c", "decoder-arm11-motion.h",
     "    if (have_armv6(cpu_flags) && !high_bit_depth) yt_h264qpel_arm11_init(c);\n",
     "    if (have_neon(cpu_flags) && !high_bit_depth) {"),
    ("h264chroma_init_arm.c", "decoder-arm11-motion.h",
     "    if (have_armv6(cpu_flags) && !high_bit_depth) yt_h264chroma_arm11_init(c);\n",
     "    if (have_neon(cpu_flags) && !high_bit_depth) {"),
    ("h264dsp_init_arm.c", "decoder-arm11-idct.h",
     "    if (have_armv6(cpu_flags) && bit_depth == 8) yt_h264idct_arm11_init(c, chroma_format_idc);\n",
     "    if (have_neon(cpu_flags))"),
):
    target = arm / name
    source = target.read_text()
    if "YT_ARM11_MOTION" in source:
        continue
    assert anchor in source, (name, "missing init anchor")
    source = source.replace('#include <stdint.h>', '#include <stdint.h>\n#include "' + header + '"')
    source = source.replace(anchor, '    // YT_ARM11_MOTION: exact ARMv6 DSP, before optional NEON overrides.\n' + call + '\n' + anchor, 1)
    target.write_text(source)
