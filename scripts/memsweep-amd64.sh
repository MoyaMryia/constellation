#!/bin/sh
# 内存下限扫描：在不同 -m 下引导同一个镜像，按验收检查点判定通过情况。
#
# 这是"内存压到离谱"这一命题的实测入口 —— 不预设目标值，从宽到紧逐档
# 试出下限。检查点按依赖顺序递进：
#   kernel  : 内核解压并进入用户空间（日志出现 "Run /sbin/init"）
#   init    : Constellation PID 1 跑起来（"starting s6-svscan"）
#   login   : getty 给出登录提示符（"constellation login"）
#   net     : e1000e 拿到 DHCP 租约（"lease of"）
#   full    : zram swap 建立 + login + net 全绿（"all" 档）
#
# 用法：
#   scripts/memsweep-amd64.sh [尺寸列表，默认 "256 128 96 64 48 32 24 20 16 12 10 8"]
# 环境变量：
#   IMAGE     被测镜像，默认 build/amd64/constellation-x61.img
#   SETTLE    单档最长等待秒数（默认 30）
#   OUTDIR    日志目录（默认 build/amd64/memsweep）
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
IMAGE=${IMAGE:-$ROOT/build/amd64/constellation-x61.img}
SETTLE=${SETTLE:-30}
OUTDIR=${OUTDIR:-$ROOT/build/amd64/memsweep}
SIZES=${*:-"256 128 96 64 48 32 24 20 16 12 10 8"}

[ -f "$IMAGE" ] || { echo "memsweep: 找不到镜像 $IMAGE" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "memsweep: 需要 qemu-system-x86_64" >&2; exit 1; }
mkdir -p "$OUTDIR"

# 只杀我们自己的 qemu（按 /proc/<pid>/cmdline 里的镜像路径匹配）。
# 注意不能用 `pgrep -x qemu-system-x86_64`：内核把 comm 截断到 15 字符
# （实际是 qemu-system-x86），该模式匹配不到任何进程，会导致上一档的
# QEMU 仍占着镜像写锁，下一档报 "Failed to get write lock"。
kill_ours () {
  for d in /proc/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    grep -qa 'qemu-system-x86' "$d/cmdline" 2>/dev/null || continue
    grep -qa "$IMAGE" "$d/cmdline" 2>/dev/null && kill "${d#/proc/}" 2>/dev/null || true
  done
}

run_one () {
  m=$1
  log=$OUTDIR/serial-$m.log
  rm -f "$log"
  kill_ours; sleep 0.5
  setsid qemu-system-x86_64 -enable-kvm -m "$m" \
    -machine q35 -cpu core2duo \
    -drive file="$IMAGE",format=raw,if=none,id=d0 \
    -device ich9-ahci,id=ahci -device ide-hd,drive=d0,bus=ahci.0 \
    -netdev user,id=n0 -device e1000e,netdev=n0 \
    -display none -serial "file:$log" -no-reboot \
    >"$OUTDIR/qemu-$m.log" 2>&1 < /dev/null &
  # 轮询等待"全绿"或超时
  waited=0
  while [ "$waited" -lt "$SETTLE" ]; do
    sleep 1
    waited=$((waited + 1))
    if grep -qa 'lease of' "$log" 2>/dev/null && grep -qa 'constellation login' "$log" 2>/dev/null; then
      break
    fi
  done
  kill_ours
}

printf '| -m (MiB) | kernel | init | login | net | zram | 可用内存 |\n'
printf '|---|---|---|---|---|---|---|\n'
for m in $SIZES; do
  run_one "$m"
  log=$OUTDIR/serial-$m.log
  k=no; i=no; l=no; n=no; z=no
  grep -qa 'Run /sbin/init' "$log" 2>/dev/null && k=yes
  grep -qa 'starting s6-svscan' "$log" 2>/dev/null && i=yes
  grep -qa 'constellation login' "$log" 2>/dev/null && l=yes
  grep -qa 'lease of' "$log" 2>/dev/null && n=yes
  grep -qa 'zram0 swap on' "$log" 2>/dev/null && z=yes
  mem=$(grep -aoE 'Memory: [0-9]+K/[0-9]+K available' "$log" 2>/dev/null | head -1 | sed 's/Memory: //;s/ available//')
  printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$m" "$k" "$i" "$l" "$n" "$z" "${mem:-—}"
done
echo
echo "日志：$OUTDIR/serial-<size>.log"
