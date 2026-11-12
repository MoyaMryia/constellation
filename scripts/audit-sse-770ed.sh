#!/bin/sh
# 审计 Constellation 770ED 镜像：有没有编译进 Pentium II 不支持的指令。
#
# 770ED 的 CPU 是 Mobile Pentium II（Deschutes）：
#   有：FPU、TSC、MSR、PAE、MCE、CX8(cmpchg8b)、SEP、MTRR、PGE、MCA、CMOV、
#       PSE36、MMX、FXSR、CPUID
#   没有：SSE / SSE2 / SSE3 / SSSE3 / SSE4 / AVX / AVX-512 / 3DNow!（那是 AMD）
#
# 因此本脚本按"指令族"分类统计，而不是只找 movaps：
#   xmm  → SSE 家族（PII 上必崩）
#   ymm/zmm/vvvv → AVX / AVX-512（必崩）
#   pf* / femms / prefetchw → 3DNow!（AMD 专用，Intel 上 #UD）
#   mm0-7 → MMX（PII 支持，仅作统计）
#
# 扫描范围：rootfs 里**所有** ELF（生效的和暂时没人用的都算，避免"以后被
# 误用"）、内核模块（.ko）、以及 vmlinux。
#
# 用法：scripts/audit-sse-770ed.sh [rootfs-dir]
# 退出码：0 = 没有 PII 不支持的指令；1 = 有
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEST=$(CDPATH= cd -- "${1:-${ROOT}/build/rootfs-770ed}" && pwd)
KVER=${KVER:-6.6.162}
MODROOT=${MODROOT:-$ROOT/build/modroot-770ed}
VMLINUX=${VMLINUX:-$ROOT/kernel/src/linux-$KVER/vmlinux}

python3 - "$DEST" "$MODROOT" "$VMLINUX" <<'PY'
import os, re, subprocess, sys, collections

root, modroot, vmlinux = sys.argv[1], sys.argv[2], sys.argv[3]

SSE = re.compile(r'%xmm')
AVX = re.compile(r'%ymm|%zmm|vzeroupper|vp?broadcast')
MMX = re.compile(r'%mm[0-7]\b')
NOW = re.compile(r'\b(pf(add|sub|mul|rcp|rsqrt|max|min|cmpge|cmpgt|cmpneq)|femms|pf2i(d|w)|pi2f(d|w)|pavgusb|pmulhrw|prefetchw)\b')

def is_elf(p):
    try:
        with open(p, 'rb') as f:
            return f.read(4) == b'\x7fELF'
    except OSError:
        return False

def scan(path):
    try:
        out = subprocess.run(['objdump', '-d', '--no-show-raw-insn', path],
                             capture_output=True, timeout=300).stdout.decode('latin1')
    except Exception:
        return None
    c = collections.Counter()
    for line in out.splitlines():
        # 只统计指令行（objdump 反汇编行形如 "  1234:\tmnemonic ..."）
        if '\t' not in line:
            continue
        mnem = line.split('\t', 1)[1]
        if SSE.search(mnem): c['sse'] += 1
        if AVX.search(mnem): c['avx'] += 1
        if MMX.search(mnem): c['mmx'] += 1
        if NOW.search(mnem): c['3dnow'] += 1
    return c

files = []
for base, dirs, names in os.walk(root):
    for n in names:
        p = os.path.join(base, n)
        if os.path.islink(p):
            continue
        # rootfs 里的 /lib/modules 是内核模块，按内核处理（见下面的 ko 分支）
        if is_elf(p) and '/lib/modules/' not in p:
            files.append(p)
ko = []
for base, dirs, names in os.walk(root):
    if '/lib/modules/' in base:
        ko.extend(os.path.join(base, n) for n in names if n.endswith('.ko'))
if os.path.isdir(modroot):
    for base, dirs, names in os.walk(modroot):
        for n in names:
            if n.endswith('.ko'):
                ko.append(os.path.join(base, n))

print(f"用户空间 ELF: {len(files)}   内核模块: {len(ko)}   vmlinux: {'有' if os.path.isfile(vmlinux) else '无'}")

bad = []
kernel_hits = []
mmx_hits = 0
for p in files:
    c = scan(p)
    if not c:
        continue
    if c['sse'] or c['avx'] or c['3dnow']:
        bad.append((p, c))
    mmx_hits += c['mmx']
for p in ko + ([vmlinux] if os.path.isfile(vmlinux) else []):
    c = scan(p)
    if c and (c['sse'] or c['avx'] or c['3dnow']):
        kernel_hits.append((p, c))

# 内核侧的命中单独说明：x86 内核用 ALTERNATIVE/静态键按 CPU 能力打补丁，
# 这些指令（prefetchw/rdtscp/popcnt/stac…）在缺特性的 CPU 上会被换成 nop，
# 不会真的执行；内核本身用 -mno-sse 编译，热路径不可能出现 SSE。
if kernel_hits:
    print("  ℹ️ 内核侧命中（ALTERNATIVE 段，启动时按 CPU 能力替换成 nop，安全）：")
    for p, c in kernel_hits:
        tags = ' '.join(f"{k}={v}" for k, v in c.items() if v and k != 'mmx')
        print(f"    {os.path.basename(p)}   {tags}")

if mmx_hits:
    print(f"  MMX 指令共 {mmx_hits} 条（PII 支持 MMX，不算问题）")

if not bad:
    print("  ✅ 没有 SSE / AVX / 3DNow 指令：PII 可以安全执行全部二进制")
    sys.exit(0)

print("  ❌ 以下文件含 PII 不支持的指令：")
for p, c in sorted(bad, key=lambda x: -(x[1]['sse'] + x[1]['avx'] + x[1]['3dnow'])):
    tags = ' '.join(f"{k}={v}" for k, v in c.items() if v and k != 'mmx')
    try:
        rel = os.path.relpath(p, root)
        if rel.startswith('..'):
            rel = p
    except ValueError:
        rel = p
    print(f"    {rel}   {tags}")
print("\n修法：加进 scripts/build-xlibs-770ed.sh 用 -mno-sse -mno-sse2 -mno-mmx -mno-3dnow 自编，")
print("     或在 scripts/build-rootfs-770ed.sh 的 PURGE 列表里删掉。")
sys.exit(1)
PY
