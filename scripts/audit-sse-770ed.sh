#!/bin/sh
# 检查 770ED 镜像里有没有"用了 SSE/SSE2 的二进制"。
#
# 背景：Pentium II 没有 SSE（PIII 才加入），而 Alpine 的 x86 归档是 PIII(SSE)
# 基线。凡是执行到 xmm 指令的进程都会立刻 SIGILL。这个脚本把 rootfs 里所有
# ELF 按"当前实际生效的库（解析 soname 软链后的实体文件）"分组，统计真正
# 含 %xmm/%ymm 操作数的指令数。
#
# 用法：
#   scripts/audit-sse-770ed.sh [rootfs-dir]
#   退出码 0 = 生效的运行时集合里没有 SSE；1 = 有（会列出来）
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEST=$(CDPATH= cd -- "${1:-${ROOT}/build/rootfs-770ed}" && pwd)

python3 - "$DEST" <<'PY'
import os, subprocess, sys, collections
root = sys.argv[1]

def is_elf(p):
    try:
        with open(p, 'rb') as f:
            return f.read(4) == b'\x7fELF'
    except OSError:
        return False

# 1) 找出"生效的库"：/usr/lib、/lib 下每个 soname 软链解析后的实体文件
active = {}          # 实体路径 -> 被哪些 soname 引用
for libdir in ('usr/lib', 'lib', 'usr/lib/xorg/modules', 'usr/lib/xorg/modules/drivers',
               'usr/lib/xorg/modules/input', 'usr/lib/xorg/modules/extensions'):
    d = os.path.join(root, libdir)
    if not os.path.isdir(d):
        continue
    for name in os.listdir(d):
        p = os.path.join(d, name)
        if os.path.islink(p) and '.so' in name:
            real = os.path.realpath(p)
            active.setdefault(real, []).append(name)

# 2) 可执行文件也算"生效"（bin/sbin/libexec）
execs = []
for base in ('bin', 'sbin', 'usr/bin', 'usr/sbin', 'usr/libexec'):
    d = os.path.join(root, base)
    if not os.path.isdir(d):
        continue
    for name in os.listdir(d):
        p = os.path.join(d, name)
        if os.path.isfile(p) and not os.path.islink(p) and is_elf(p):
            execs.append(p)

def count_sse(p):
    try:
        out = subprocess.run(['objdump', '-d', '--no-show-raw-insn', p],
                             capture_output=True, timeout=240).stdout
    except Exception:
        return -1
    return sum(1 for line in out.split(b'\n')
               if b'%xmm' in line or b'%ymm' in line or b'%zmm' in line)

print(f"检查 {root}")
print(f"  生效的共享库: {len(active)}   可执行文件: {len(execs)}")

bad = []
for p in sorted(active) + sorted(execs):
    n = count_sse(p)
    if n > 0:
        bad.append((n, os.path.relpath(p, root),
                    ','.join(sorted(set(active.get(p, []))))))

if not bad:
    print("  ✅ 生效集合里没有 xmm/ymm 指令（PII 可安全执行）")
    sys.exit(0)

print("  ❌ 以下文件含 SSE 指令，PII 上执行到就会 SIGILL：")
for n, rel, sonames in sorted(bad, reverse=True):
    extra = f"  (soname: {sonames})" if sonames else ""
    print(f"    {n:6d}  {rel}{extra}")
print("\n处理办法：把它加进 scripts/build-xlibs-770ed.sh 自编，")
print("或在 scripts/build-rootfs-770ed.sh 的 PURGE 列表里删掉（若本就不需要）。")
sys.exit(1)
PY
