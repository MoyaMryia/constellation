#!/bin/sh
# 组装 ThinkPad 770ED 的 rootfs（build/rootfs-770ed）。
#
# 与 scripts/build-rootfs.sh（M2，24 MiB 档）的差别：
#   1) 带上 /lib/modules（本风味有 110 个模块：CardBus/无线/声卡/猫/HID）
#   2) BusyBox applet 软链按 `busybox --list` 自动生成，不手写清单
#   3) 多 mdev/热插拔脚本、modprobe.d 调参、hwcheck 自检
#   4) 三个 s6 服务：console getty / serial getty / udhcpc
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEST=${ROOTFS_DEST:-$ROOT/build/rootfs-770ed}
BB_BIN=$ROOT/busybox/src/busybox-1.38.0/busybox
S6_ROOT=${M2_INSTALL_DIR:-$ROOT/build/m2root}
MODROOT=${MODROOT:-$ROOT/build/modroot-770ed}
TMPL=$ROOT/rootfs-770ed

# 目标机没有 CJK 字体（VGA 文本控制台 + 西文 X 字体），模板里混进中文就是乱码。
# 在动手之前先拦一道，别等打完镜像才发现。中文请写在 scripts/、docs/ 里。
"$ROOT/scripts/check-ascii-770ed.sh" "$TMPL" >/dev/null
PASSWORD=${ROOT_PASSWORD_HASH:-!}
# 额外账号：EXTRA_USERS="name:$6$hash name2:$6$hash2"（空格分隔）。
# 明文口令不要写进仓库；构建时用
#   EXTRA_USERS="moyamryia:$(openssl passwd -6 '…')"
# 传进来即可。
EXTRA_USERS=${EXTRA_USERS:-}

[ -x "$BB_BIN" ] || { echo "build BusyBox first: scripts/build-core-770ed.sh" >&2; exit 1; }
[ -x "$S6_ROOT/usr/bin/s6-svscan" ] || { echo "build s6 first: scripts/build-s6.sh" >&2; exit 1; }
set -- "$MODROOT"/lib/modules/*/
[ -d "$1" ] || { echo "build modules first: scripts/build-core-770ed.sh" >&2; exit 1; }
case "$PASSWORD" in
  *:*) echo "ROOT_PASSWORD_HASH must not contain ':'" >&2; exit 1 ;;
esac

rm -rf "$DEST"
mkdir -p "$DEST/bin" "$DEST/dev" "$DEST/dev/pts" "$DEST/proc" "$DEST/sys" \
         "$DEST/run" "$DEST/tmp" "$DEST/boot" "$DEST/root" "$DEST/sbin" \
  "$DEST/sys" "$DEST/tmp" "$DEST/usr/bin" "$DEST/usr/sbin" \
  "$DEST/etc/s6" "$DEST/etc/modprobe.d" "$DEST/lib/modules" "$DEST/var/log"
chmod 0700 "$DEST/root"
chmod 1777 "$DEST/tmp"

cp "$BB_BIN" "$DEST/bin/busybox"
chmod 0755 "$DEST/bin/busybox"

# applet 软链：以二进制自己报告的 applet 表为准，避免"配了 applet 但
# 名字对不上 → applet not found"这类静默偏差。`[` 不在表里，ash 内建提供。
for applet in $("$BB_BIN" --list); do
  case "$applet" in
    '['|linuxrc) continue ;;
  esac
  ln -sf busybox "$DEST/bin/$applet"
done
# BusyBox 的 applet 按调用名分派，但 init/getty 之类的惯例位置仍是 /sbin。
# 注意：不要给 init 建软链——下面的 cp 会把模板 init 写穿到这个软链上，
# 结果 /bin/busybox 变成 shell 脚本、/bin/sh 递归解析，内核报
# "Run /sbin/init as init process … failed (error -40)"（ELOOP）。
for applet in halt poweroff reboot mkswap swapoff swapon modprobe depmod \
              insmod rmmod lsmod hwclock; do
  ln -sf ../bin/busybox "$DEST/sbin/$applet"
done

cp -a "$S6_ROOT/usr/." "$DEST/usr/"

# OSS 混音器客户端（源码 tools/mixer.c，由 build-core-770ed.sh 编译）
if [ -x "$ROOT/build/mixer" ]; then
  cp "$ROOT/build/mixer" "$DEST/bin/mixer"
  chmod 0755 "$DEST/bin/mixer"
fi
cp -a "$MODROOT"/lib/modules/* "$DEST/lib/modules/"

# 模板（先删掉同名软链：cp 默认跟随软链，会写到 /bin/busybox 上）
rm -f "$DEST/sbin/init" "$DEST/sbin/hotplug"
cp "$TMPL/sbin/init" "$DEST/sbin/init"
cp "$TMPL/sbin/hotplug" "$DEST/sbin/hotplug"
cp "$TMPL/usr/sbin/hwcheck" "$DEST/usr/sbin/hwcheck"
for svc in getty-console getty-serial udhcpc; do
  mkdir -p "$DEST/etc/s6/$svc"
  cp "$TMPL/etc/s6/$svc/run" "$DEST/etc/s6/$svc/run"
done
cp "$TMPL/etc/securetty" "$DEST/etc/securetty"
cp -a "$TMPL/etc/ppp/." "$DEST/etc/ppp/"
cp "$TMPL/etc/mdev.conf" "$DEST/etc/mdev.conf"
cp "$TMPL"/etc/modprobe.d/*.conf "$DEST/etc/modprobe.d/"
cp "$ROOT/rootfs/etc/udhcpc.script" "$DEST/etc/udhcpc.script"

# X11 桌面（可选）：Xorg + IceWM + xterm + ppp + 字体，来自 Alpine x86 仓库
# （i386 + musl，与本工程用户空间同 ABI）。见 scripts/alpine-x86-770ed.py。
ALPINE_VER=${ALPINE_VER:-3.20}
INSTALL_X=${INSTALL_X:-1}
if [ "$INSTALL_X" = 1 ]; then
  ALPINE_VER=$ALPINE_VER python3 "$ROOT/scripts/alpine-x86-770ed.py" install \
    --root "$DEST" \
    xorg-server xf86-video-fbdev xf86-video-vesa xf86-input-evdev \
    xinit xauth xterm twm xkeyboard-config font-misc-misc font-dejavu \
    libxinerama libjpeg-turbo libpng libxpm libxft \
    xrdb xmodmap xsetroot xrandr setxkbmap \
    ppp ppp-chat >/dev/null

  # ---- 清理不需要的 Alpine 组件 ----
  # Alpine 的 x86 包是 Pentium III(SSE) 基线。凡是"镜像里根本用不到"的
  # 组件一律删掉：既省 30 MB，也让 scripts/audit-sse-770ed.sh 的结论干净。
  # 保留的是：我们自编的 X 栈、kbd/mouse 输入、JWM、st、以及基础系统。
  PURGE="
    usr/lib/python3.12 usr/lib/libpython3.12.so.1.0 usr/lib/libpython3.12.so
    usr/bin/python3 usr/bin/python3.12 usr/bin/pydoc3 usr/bin/python3-config
    usr/lib/libsqlite3.so.0.8.6 usr/lib/libsqlite3.so.0 usr/lib/libsqlite3.so
    usr/lib/mesa usr/lib/libGL.so.1.2.0 usr/lib/libGL.so.1 usr/lib/libGLX.so
    usr/lib/libEGL.so.1.0.0 usr/lib/libEGL.so.1 usr/lib/libGLESv2.so
    usr/lib/libgbm.so.1.0.0 usr/lib/libgbm.so.1 usr/lib/libglapi.so.0
    usr/lib/libepoxy.so.0.0.0 usr/lib/libepoxy.so.0
    usr/lib/libdrm.so.2.4.0 usr/lib/libdrm.so.2 usr/lib/libdrm_intel.so.1.0.0
    usr/lib/libdrm_intel.so.1 usr/lib/libdrm_amdgpu.so.1.0.0 usr/lib/libdrm_amdgpu.so.1
    usr/lib/libdrm_radeon.so.1.0.1 usr/lib/libdrm_radeon.so.1 usr/lib/libdrm_nouveau.so.2.0.0
    usr/lib/libdrm_freedreno.so.1.0.0 usr/lib/libdrm_etnaviv.so.1.0.0
    usr/lib/libdrm_exynos.so.1.0.0 usr/lib/libdrm_omap.so.1.0.0
    usr/lib/libdrm_tegra.so.0.0.0 usr/lib/libdrm_tegra.so.0
    usr/lib/xorg/modules/libglamoregl.so usr/lib/xorg/modules/extensions/libglx.so
    usr/lib/libstdc++.so.6.0.32 usr/lib/libstdc++.so.6
    usr/lib/libgcc_s.so.1
    usr/lib/libncursesw.so.6.4 usr/lib/libncursesw.so.6 usr/lib/libncurses.so.6
    usr/lib/libgmp.so.10.5.0 usr/lib/libgmp.so.10
    usr/lib/libnettle.so.8.11 usr/lib/libnettle.so.8 usr/lib/libhogweed.so.6.11
    usr/lib/libhogweed.so.6
    usr/lib/libbz2.so.1.0.8 usr/lib/libbz2.so.1
    usr/lib/liblzma.so.5.8.3 usr/lib/liblzma.so.5
    usr/lib/libreadline.so.8.2 usr/lib/libreadline.so.8
    usr/lib/libpkgconf.so.5.0.0 usr/lib/libpkgconf.so.5 usr/bin/pkgconf usr/bin/pkg-config
    usr/lib/libwayland-server.so.0.22.0 usr/lib/libwayland-server.so.0
    usr/lib/libwayland-client.so.0.22.0 usr/lib/libwayland-client.so.0
    usr/lib/libgdbm.so.6.0.0 usr/lib/libgdbm.so.6 usr/lib/libgdbm_compat.so.4.0.0
    usr/lib/libgdbm_compat.so.4 usr/lib/libmpdec.so.4.0.0 usr/lib/libmpdec.so.4
    usr/lib/libmpdec++.so.4.0.0 usr/lib/libmpdec++.so.4
    usr/lib/libbsd.so.0.12.2 usr/lib/libbsd.so.0 usr/lib/libffi.so.8.1.4 usr/lib/libffi.so.8
    usr/lib/libudev.so.1.6.3 usr/lib/libudev.so.1 usr/lib/libevdev.so.2.3.0 usr/lib/libevdev.so.2
    usr/lib/libmtdev.so.1.0.0 usr/lib/libmtdev.so.1 usr/lib/libeconf.so.0.6.2 usr/lib/libeconf.so.0
    usr/lib/libpcap.so.1.10.4 usr/lib/libpcap.so.1
    usr/lib/libcrypto.so.3 usr/lib/libssl.so.3 usr/lib/libcrypto.so.1.1
    usr/lib/engines-3 usr/lib/ossl-modules
    usr/sbin/pppd usr/sbin/pppstats usr/sbin/pppdump usr/sbin/pppoe-discovery usr/lib/pppd
    usr/bin/pppd
    usr/bin/xterm usr/bin/xrdb usr/bin/xsetroot usr/bin/xrandr usr/bin/setxkbmap
    usr/bin/cvt usr/bin/gtf usr/bin/sxpm usr/bin/bomtool usr/bin/resize
    usr/bin/mkfontscale usr/bin/mkfontdir usr/bin/bdftopcf usr/bin/ucs2any
    usr/bin/xkbprint usr/bin/xkbvleds usr/bin/xkbwatch usr/bin/xkbbell
    usr/libexec/Xorg usr/libexec/Xorg.wrap usr/libexec/Xorg.wrap.real
    usr/lib/xorg/modules/input/evdev_drv.so usr/lib/xorg/modules/input/inputtest_drv.so
    usr/lib/xorg/modules/drivers/vesa_drv.so usr/lib/xorg/modules/drivers/modesetting_drv.so
    usr/lib/xorg/modules/libvgahw.so usr/lib/xorg/modules/libshadow.so
    usr/lib/libXxf86vm.so.1.0.0 usr/lib/libXxf86vm.so.1
    usr/lib/libXrandr.so.2.2.0 usr/lib/libXrandr.so.2
    usr/lib/libXcursor.so.1.0.2 usr/lib/libXcursor.so.1
    usr/lib/libwayland-server.so.0 usr/lib/libdrm.so
    usr/lib/libuuid.so.1.3.0 usr/lib/libblkid.so.1.1.0 usr/lib/libmount.so.1.1.0
    usr/lib/libcom_err.so.2.1 usr/lib/libkeyutils.so.1.10 usr/lib/libkrb5support.so.0.1
    usr/lib/libtirpc.so.3 usr/lib/libgssapi_krb5.so.2 usr/lib/libkrb5.so.3
    usr/lib/libk5crypto.so.3 usr/lib/libkmod.so.2 usr/lib/libcap.so.2
    usr/lib/libacl.so.1 usr/lib/libattr.so.1
    usr/lib/libbrotlienc.so.1.1.0 usr/lib/libbrotlienc.so.1
    usr/lib/libbrotlidec.so.1.1.0 usr/lib/libbrotlidec.so.1
    usr/lib/libbrotlicommon.so.1.1.0 usr/lib/libbrotlicommon.so.1
    usr/lib/libxshmfence.so.1.0.0 usr/lib/libxshmfence.so.1
    lib/libudev.so.1.6.3 lib/libudev.so.1 lib/libuuid.so.1.3.0 lib/libuuid.so.1
    lib/libcrypto.so.3 lib/libcrypto.so lib/libssl.so.3 lib/libssl.so
    lib/libcom_err.so.2.1 lib/libkeyutils.so.1.10 lib/libkrb5support.so.0.1
    usr/lib/libXfixes.so.3.1.0 usr/lib/libXfixes.so.3
    usr/lib/libXinerama.so.1.0.0 usr/lib/libXinerama.so.1
    usr/bin/twm usr/bin/xauth usr/bin/mcookie usr/bin/xinit
    # 下面这些是仍在用 Alpine musl 的遗留工具：运行时用不到，而且 Alpine 的
    # musl 自带 XMM（memcpy 之类）——一起清掉后镜像里只剩我们自己的 i486 musl。
    # 注意：PURGE 是双引号字符串，注释里不能再出现双引号，否则字符串提前闭合
    # （症状：build-rootfs 报 'Alpine: not found'，退出码 127）。
    usr/bin/cxpm usr/bin/xmodmap usr/sbin/chat usr/bin/chat
    usr/bin/fc-cache usr/bin/fc-cat usr/bin/fc-conflist usr/bin/fc-list
    usr/bin/fc-match usr/bin/fc-pattern usr/bin/fc-query usr/bin/fc-scan
    usr/bin/fc-validate usr/lib/libglapi.so.0.0.0 usr/lib/libglapi.so.0
    # Alpine 的 musl 与它的 soname 软链（我们的二进制用 /lib/ld-musl-i486.so.1）
    lib/ld-musl-i386.so.1 lib/libc.musl-x86.so.1
  "
  for f in $PURGE; do
    rm -rf "$DEST/$f"
  done

  # ---- 自编 i486 的 X 栈 ----
  # Alpine 的 x86 归档是 Pentium III(SSE) 基线：Xorg、libz、libX11、libXt …
  # 在 770ED 的 Pentium II 上会 SIGILL。三个脚本分别负责：
  #   build-xlibs：20 个库（含 zlib/pixman/libX11/libXt/libXaw…）
  #   build-xorg ：服务器 + fbdev/kbd/mouse 驱动 + xkbcomp + 动态 musl
  #   build-jwm  ：窗口管理器（IceWM 风格）
  ROOTFS_DEST="$DEST" JOBS="${JOBS:-4}" "$ROOT/scripts/build-xlibs-770ed.sh" >/dev/null
  ROOTFS_DEST="$DEST" JOBS="${JOBS:-4}" "$ROOT/scripts/build-xorg-770ed.sh" >/dev/null
  ROOTFS_DEST="$DEST" JOBS="${JOBS:-4}" "$ROOT/scripts/build-jwm-770ed.sh" >/dev/null

  # 固件：只带能合法取到的那些（见 docs/thinkpad-770ed.md §6）。
  # 144 位无线（orinoco）与 cfg80211 的监管库可用；ath5k/rtl8180 不需要固件。
  ALPINE_VER=$ALPINE_VER python3 "$ROOT/scripts/alpine-x86-770ed.py" extract \
    --root "$DEST" \
    --path 'lib/firmware/agere_sta_fw.bin' --path 'lib/firmware/agere_ap_fw.bin' \
    linux-firmware-other >/dev/null
  ALPINE_VER=$ALPINE_VER python3 "$ROOT/scripts/alpine-x86-770ed.py" extract \
    --root "$DEST" \
    --path 'lib/firmware/regulatory.db' --path 'lib/firmware/regulatory.db.p7s' \
    wireless-regdb >/dev/null

  # b43 固件（Broadcom BCM43xx）：来自 vendor 驱动 wl_apsta.o 经 b43-fwcutter 提取，
  # 源与生成命令见 rootfs-770ed/lib/firmware/b43/SOURCE.txt。
  # BCM4318（Buffalo WLI-CB-AMG54HP 之类）用 ucode5 + pcm5 + b0g0{,bs}initvals5。
  if [ -d "$TMPL/lib/firmware/b43" ]; then
    mkdir -p "$DEST/lib/firmware/b43"
    cp -a "$TMPL/lib/firmware/b43/." "$DEST/lib/firmware/b43/"
  fi

  # 离线可用的开发工具：tcc（C 编译器）+ make + musl 头文件/静态库。
  # 目标机可能没有网络，所以编译能力必须随镜像走。
  if [ "${SKIP_DEVTOOLS:-0}" != 1 ]; then
    ROOTFS_DEST="$DEST" JOBS="${JOBS:-4}" "$ROOT/scripts/build-devtools-770ed.sh" >/dev/null
  fi

  # 额外用户态程序：mpg123（MP3 播放器）、fbset、lspci，以及目标机上的
  # Linux UAPI 头（写 C 程序时 #include <linux/...> 要用）
  if [ "${SKIP_USERSPACE:-0}" != 1 ]; then
    ROOTFS_DEST="$DEST" JOBS="${JOBS:-4}" "$ROOT/scripts/build-userspace-770ed.sh" >/dev/null
  fi

  # 无线工具：iwconfig/iwlist（wireless-tools）+ wpa_supplicant（wext + internal TLS），
  # 都用本工程 i486 musl 工具链编（Alpine 的是 SSE 基线）。
  if [ "${SKIP_WIRELESS:-0}" != 1 ]; then
    ROOTFS_DEST="$DEST" JOBS="${JOBS:-4}" "$ROOT/scripts/build-wireless-770ed.sh" >/dev/null
  fi

  # 核心字体的 fonts.dir：Alpine 的这些包只在 post-install 里生成，
  # 我们不执行 post-install，于是用包里自带的 mkfontscale 在宿主上跑一遍
  # （用 Alpine 自己的 musl 加载器，不需要 root/chroot）。
  for d in "$DEST"/usr/share/fonts/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/fonts.dir" ] && continue
    "$DEST/lib/ld-musl-i386.so.1" --library-path "$DEST/lib:$DEST/usr/lib" \
      "$DEST/usr/bin/mkfontscale" -b -s -l "$d" >/dev/null 2>&1 || true
  done

  # 再放一次 BusyBox 主程序：Alpine 侧已被排除 busybox*，这里只是兜底，
  # 保证 /bin/busybox 一定是本工程 musl i486 静态构建的那一份。
  cp "$BB_BIN" "$DEST/bin/busybox"
  chmod 0755 "$DEST/bin/busybox"
  for applet in $("$BB_BIN" --list); do
    case "$applet" in '['|linuxrc) continue ;; esac
    [ -e "$DEST/bin/$applet" ] || ln -sf busybox "$DEST/bin/$applet"
  done

  cp "$TMPL/usr/bin/x" "$DEST/usr/bin/x"
  cp "$TMPL/etc/X11/xinit/xinitrc" "$DEST/etc/X11/xinit/xinitrc"
  cp "$TMPL/etc/X11/Xresources" "$DEST/etc/X11/Xresources"
  chmod 0755 "$DEST/usr/bin/x" "$DEST/etc/X11/xinit/xinitrc"
  # xinit 用 /etc/X11/xinit/xinitrc；再放一份 root 的 .xinitrc 便于直接 startx
  cp "$TMPL/etc/X11/xinit/xinitrc" "$DEST/root/.xinitrc"
  chmod 0755 "$DEST/root/.xinitrc"
fi
# fetch：Mark（拼色 * 号）+ 系统信息；logo 有真彩与 16 色两版（VGA 控制台只认 16 色）
mkdir -p "$DEST/usr/share/constellation"
cp "$TMPL/usr/bin/fetch" "$DEST/usr/bin/fetch"
cp "$TMPL/usr/bin/mountusb" "$DEST/usr/bin/mountusb"
cp "$TMPL/usr/bin/wifi" "$DEST/usr/bin/wifi"
cp "$TMPL/usr/bin/apm" "$DEST/usr/bin/apm"
cp "$TMPL"/usr/share/constellation/*.txt "$DEST/usr/share/constellation/"
cp "$TMPL/etc/motd" "$DEST/etc/motd"
chmod 0755 "$DEST/usr/bin/fetch" "$DEST/usr/bin/mountusb" \
  "$DEST/usr/bin/wifi" "$DEST/usr/bin/apm"

# ---- 电源管理：覆盖 busybox 的 poweroff/reboot/halt ----
# busybox 的这三个 applet 假设 PID 1 是 busybox init，只给 PID 1 发信号；
# 我们的 PID 1 是 s6-svscan，所以 `poweroff` 看起来毫无反应。换成会走
# s6 关停流程、最后调用 reboot(2)（APM BIOS 断电）的包装脚本。
# 注意：$DEST/sbin/poweroff 此刻是指向 ../bin/busybox 的软链，直接 cp 会
# **透过软链把 busybox 本体覆盖掉**（踩过一次：镜像里 /bin/busybox 变成了
# 一个 shell 脚本）。所以先 rm 掉，再放真文件。
for n in poweroff reboot halt shutdown; do
  rm -f "$DEST/sbin/$n"
done
cp "$TMPL/sbin/poweroff" "$DEST/sbin/poweroff"
cp "$TMPL/sbin/shutdown" "$DEST/sbin/shutdown"
ln -sf poweroff "$DEST/sbin/reboot"
ln -sf poweroff "$DEST/sbin/halt"
for n in poweroff reboot halt shutdown; do
  chmod 0755 "$DEST/sbin/$n"
done
# 自检：busybox 必须还是 ELF（别被上面的 cp 之类误伤）
head -c 4 "$DEST/bin/busybox" | grep -q ELF || {
  echo "build-rootfs: /bin/busybox 被破坏了（不是 ELF）" >&2; exit 1; }
mkdir -p "$DEST/etc/s6/.s6-svscan"
cp "$TMPL/etc/s6/.s6-svscan/finish" "$DEST/etc/s6/.s6-svscan/finish"
chmod 0755 "$DEST/etc/s6/.s6-svscan/finish"

chmod 0755 "$DEST/sbin/init" "$DEST/sbin/hotplug" "$DEST/usr/sbin/hwcheck" \
  "$DEST/etc/s6/"*/run "$DEST/etc/udhcpc.script"

# 账号与文件系统
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$DEST/etc/passwd"
printf 'root:x:0:\n' > "$DEST/etc/group"
printf 'root:%s:19000:0:99999:7:::\n' "$PASSWORD" > "$DEST/etc/shadow"

# 普通账号（可选）：每个都建 /home/<name>，uid 从 1000 起
uid=1000
for entry in $EXTRA_USERS; do
  name=${entry%%:*}
  hash=${entry#*:}
  case "$name" in ''|*[!a-z0-9_-]*) echo "跳过非法用户名：$name" >&2; continue ;; esac
  mkdir -p "$DEST/home/$name"
  chmod 0700 "$DEST/home/$name"
  printf '%s:x:%s:%s:%s:/home/%s:/bin/sh\n' "$name" "$uid" "$uid" "$name" "$name" >> "$DEST/etc/passwd"
  printf '%s:x:%s:\n' "$name" "$uid" >> "$DEST/etc/group"
  printf '%s:%s:19000:0:99999:7:::\n' "$name" "$hash" >> "$DEST/etc/shadow"
  uid=$((uid + 1))
done
chmod 0644 "$DEST/etc/passwd" "$DEST/etc/group" "$DEST/etc/securetty" "$DEST/etc/mdev.conf"
chmod 0600 "$DEST/etc/shadow"
printf 'constellation\n' > "$DEST/etc/hostname"

# ---- 让它像个系统，而不是 rescue shell ----
# /etc/profile（PATH/PS1/别名/登录时打一次 Mark）、/etc/issue（登录横幅）、
# /etc/hosts、/etc/resolv.conf、/etc/profile.d、/root/README
mkdir -p "$DEST/etc/profile.d" "$DEST/root" "$DEST/media" "$DEST/mnt"
cp "$TMPL/etc/profile" "$DEST/etc/profile"
[ -f "$TMPL/etc/issue" ] && cp "$TMPL/etc/issue" "$DEST/etc/issue"
cp "$TMPL/etc/hosts" "$DEST/etc/hosts"
cp "$TMPL/etc/resolv.conf" "$DEST/etc/resolv.conf"
cp "$TMPL"/etc/profile.d/*.sh "$DEST/etc/profile.d/" 2>/dev/null || true
cp "$TMPL/root/README" "$DEST/root/README"
chmod 0644 "$DEST/etc/profile" "$DEST/etc/hosts" "$DEST/etc/resolv.conf" "$DEST/root/README"
chmod 0755 "$DEST/etc/profile.d" 2>/dev/null || true
# fstab 只是给"人"和 mount -a/swapon -a 看的：真正的根是内核命令行
# root= 挂的，swap 由 init 按命令行 cswap= 启用。但内容必须和实际布局一致——
# 之前这里把根写成了 /dev/sda2，而 p2 是 swap 分区（布局 p1=boot / p2=swap /
# p3=root），`mount -a` 会试图把 swap 分区当根挂上。
cat > "$DEST/etc/fstab" <<'FSTAB'
# <device>        <mount>  <type>    <options>                    <dump> <pass>
/dev/sda3         /        ext4      rw,relatime,errors=remount-ro  0      1
/dev/sda2         none     swap      sw                             0      0
/dev/sda1         /boot    vfat      ro,noauto                      0      0
proc              /proc    proc      defaults                       0      0
sysfs             /sys     sysfs     defaults                       0      0
devtmpfs          /dev     devtmpfs  mode=0755,nosuid               0      0
devpts            /dev/pts devpts    gid=5,mode=0620                0      0
tmpfs             /run     tmpfs     mode=0755,nosuid,nodev         0      0
tmpfs             /tmp     tmpfs     mode=1777,nosuid,nodev,size=16M 0      0
FSTAB

# udev 缺席时的惯例：/dev/fd 等由 devtmpfs 提供；/var/log 留空目录。

echo "770ED rootfs written: $DEST"
echo "  modules: $(find "$DEST/lib/modules" -name '*.ko' | wc -l) 个"
echo "  size   : $(du -sh "$DEST" | cut -f1)"
if [ -n "$EXTRA_USERS" ]; then
  echo "extra accounts: $(echo "$EXTRA_USERS" | sed 's/:.*//g')"
fi
if [ "$PASSWORD" = '!' ]; then
  echo "root login is locked; set ROOT_PASSWORD_HASH=\$(openssl passwd -6 'pw') when building to enable login"
fi
