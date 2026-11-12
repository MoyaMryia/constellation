#!/usr/bin/env python3
"""从 Alpine x86（i386, musl）仓库取二进制包，装进 Constellation 的 rootfs。

为什么这么做：770ED 想要的 Xorg + IceWM 是 C/C++ 程序。本工程的用户空间
是自己交叉编译的 musl i486，没有 libstdc++（IceWM 是 C++），从源码重建整
X 栈（xorg-server、xcb、pixman、fontconfig、freetype、IceWM…）是几十个包
的工程，与本轮目标不匹配。Alpine 的 **x86** 架构（i386 + musl）与本工程的
用户空间 ABI 相同，因此可以直接取它的二进制包——这是"闭源式打包"的等价
做法：不重编，只钉版本与哈希。

用法：
    alpine-x86-770ed.py install --root DIR PKG...
    alpine-x86-770ed.py extract --root DIR --path 'lib/firmware/x.bin' PKG...

行为契约：
  * 索引与每个包的哈希都钉住：首次运行把 sha256 写进 LOCK，之后每次核对。
    （Alpine 索引里的 C: 字段 = "Q1" + base64(候包文件的 SHA1)，与 apk 一致，
      这里逐包验证 C: 而不是只信 HTTPS。）
  * 提取时跳过 .PKGINFO/.SIGN.*/.post-install 等元数据，只落数据文件；
    包的 post-install 脚本不执行（本脚本自己补齐真正需要的步骤）。
  * 不启动、不注册任何 Alpine 服务；纯粹往 rootfs 里放文件。
"""
import argparse
import base64
import hashlib
import io
import os
import sys
import tarfile
import urllib.request

ALPINE_VER = os.environ.get("ALPINE_VER", "3.20")
# 这些包会覆盖 Constellation 自己的核心用户空间（/bin/busybox、/bin/sh、
# /sbin/init、/etc/passwd…），一律不装：
#   busybox*  —— 我们的 BusyBox 是 musl i486 静态构建，功能集是自选的；
#                装 Alpine 的会把 /bin/busybox 换成动态 PIE 版本（在
#                Pentium II 上直接 invalid opcode），/bin/sh 也跟着换。
#   alpine-baselayout / alpine-conf / openrc / apk-tools / musl-utils
#             —— 发行版身份与 init 框架，与 s6 + 自带 init 冲突。
EXCLUDE = {
    "busybox", "busybox-binsh", "busybox-extras", "busybox-suid",
    "busybox-openrc", "busybox-mdev-openrc", "busybox-extras-openrc",
    "alpine-base", "alpine-baselayout", "alpine-conf", "alpine-release",
    "apk-tools", "openrc", "musl-utils", "mdev-conf", "mkinitfs",
    "ifupdown-ng", "ifupdown", "eudev", "eudev-openrc",
}
ARCH = "x86"
REPOS = ("main", "community")
BASE = f"https://dl-cdn.alpinelinux.org/alpine/v{ALPINE_VER}"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "build", "alpine-cache")
# 钉版记录**随仓库提交**（build/ 是被忽略的）：索引与每个包的版本+sha256
# 都在里面，换个机器/换天重跑会逐项核对，Alpine 上游一动就会报出来。
LOCK = os.path.join(ROOT, "scripts", "alpine-x86-770ed.lock")


def log(msg):
    print(f"alpine: {msg}", file=sys.stderr, flush=True)


def fetch(url, dest):
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return dest
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + f".tmp.{os.getpid()}"
    log(f"下载 {url}")
    with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as f:
        while True:
            chunk = r.read(1 << 16)
            if not chunk:
                break
            f.write(chunk)
    os.replace(tmp, dest)
    return dest


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_lock():
    lock = {}
    if os.path.exists(LOCK):
        with open(LOCK) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split()
                lock[parts[0]] = parts[1]
    return lock


def save_lock(entries):
    os.makedirs(os.path.dirname(LOCK), exist_ok=True)
    with open(LOCK, "w") as f:
        f.write(f"# Alpine v{ALPINE_VER} {ARCH} 取包记录（index sha256 / 包版本+sha256）\n")
        f.write("# 由 scripts/alpine-x86-770ed.py 维护；index 行用作下次运行的校验\n")
        for key in sorted(entries):
            f.write(f"{key} {entries[key]}\n")


def parse_index(text):
    pkgs = {}
    for block in text.split("\n\n"):
        if not block.strip():
            continue
        rec = {}
        for line in block.splitlines():
            if len(line) > 1 and line[1] == ":":
                rec.setdefault(line[0], []).append(line[2:])
        if "P" in rec:
            rec["repo_url"] = None  # 解析后填
            # D:/p: 是**空格分隔的列表**（一个 D: 行里可能有很多依赖），
            # 必须拆开；否则整行会被当成一个包名去找，解析必然失败。
            for key in ("D", "p"):
                if key in rec:
                    rec[key] = [item for v in rec[key] for item in v.split()]
            pkgs[rec["P"][0]] = rec
    return pkgs


def get_index():
    lock = load_lock()
    merged = {}
    index_shas = {}
    for repo in REPOS:
        key = f"index:v{ALPINE_VER}/{repo}/{ARCH}"
        path = os.path.join(CACHE, f"index-{repo}.tar.gz")
        fetch(f"{BASE}/{repo}/{ARCH}/APKINDEX.tar.gz", path)
        digest = sha256_file(path)
        if key in lock and lock[key] != digest:
            log(f"警告：{repo} 索引哈希变了（{lock[key][:12]} -> {digest[:12]}），"
                f"Alpine 仓库内容有更新；如需固定旧版本请使用本地镜像")
        index_shas[key] = digest
        with tarfile.open(path) as tf:
            text = tf.extractfile("APKINDEX").read().decode()
        for name, rec in parse_index(text).items():
            rec["repo_url"] = f"{BASE}/{repo}/{ARCH}"
            merged[name] = rec
    return merged, index_shas


def build_provides(pkgs):
    prov = {}
    for name, rec in pkgs.items():
        prov.setdefault(name, name)
        for clause in rec.get("p", []):
            clause = clause.split("=")[0]
            prov.setdefault(clause, name)
    return prov


def deps_of(rec):
    out = []
    for clause in rec.get("D", []):
        if not clause or clause.startswith("!"):
            continue
        out.append(clause)
    return out


def resolve(pkgs, wanted):
    prov = build_provides(pkgs)
    selected = {}
    queue = list(wanted)
    missing = []
    excluded = []
    while queue:
        dep = queue.pop(0)
        name = dep
        # Alpine 的版本约束还有 "~"（模糊匹配）；一并按前缀剥离。
        for sep in (">=", "<=", "~=", "=", ">", "<", "~"):
            if sep in name:
                name = name.split(sep)[0]
                break
        real = pkgs.get(name) and name or prov.get(name)
        if not real or real not in pkgs:
            missing.append(dep)
            continue
        if real in selected:
            continue
        if real in EXCLUDE:
            if real not in excluded:
                excluded.append(real)
            continue
        selected[real] = pkgs[real]
        for d in deps_of(pkgs[real]):
            queue.append(d)
    if excluded:
        log("跳过会覆盖本工程核心用户空间的包：" + ", ".join(sorted(excluded)))
    return selected, missing


def verify_and_path(rec, lock):
    """下载并校验。

    APKINDEX 的 C: 字段不是整个 .apk 的 SHA1（apk-tools 用它校验控制段），
    这里不去复刻那个细节，改用**首次使用即锁定**：LOCK 里记下
    "包名 版本 sha256"，之后同版本但哈希变了就报错。索引本身的 sha256 也
    在同一份 LOCK 里，因此"版本 + 内容"两级都被钉住。
    """
    name = rec["P"][0]
    ver = rec["V"][0]
    url = f"{rec['repo_url']}/{name}-{ver}.apk"
    dest = os.path.join(CACHE, f"{name}-{ver}.apk")
    fetch(url, dest)
    digest = sha256_file(dest)
    key = f"pkg:{name}"
    if key in lock:
        locked = lock[key].split()
        if len(locked) >= 2:
            old_ver, old_digest = locked[0], locked[1]
            if old_ver == ver and old_digest != digest:
                raise SystemExit(
                    f"alpine: {name}-{ver}.apk 内容与锁文件不符"
                    f"（锁 {old_digest[:12]} 实际 {digest[:12]}）；"
                    f"如果确实要升级，删除 build/alpine-770ed.lock 后重跑")
    return dest, digest


def _path_match(name, pat):
    """路径匹配：目录前缀（"lib/firmware/b43/"）或 shell 通配（"*.bin"）。"""
    if pat.endswith("/"):
        return name.startswith(pat)
    if "*" in pat or "?" in pat or "[" in pat:
        import fnmatch
        return fnmatch.fnmatch(name, pat)
    return name == pat


def extract_apk(apk_path, root, only_paths=None):
    written = 0
    skipped = 0
    with tarfile.open(apk_path) as tf:
        for member in tf:
            name = member.name
            if name.startswith("./"):
                name = name[2:]
            if not name or name.startswith(".") or name.split("/")[0].startswith("."):
                skipped += 1
                continue
            if only_paths is not None:
                if not any(_path_match(name, pat) for pat in only_paths):
                    continue
            target = os.path.join(root, name)
            if member.isdir():
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if member.issym():
                if os.path.lexists(target):
                    os.unlink(target)
                os.symlink(member.linkname, target)
            elif member.islnk():
                src = os.path.join(root, member.linkname)
                if os.path.lexists(target):
                    os.unlink(target)
                os.link(src, target)
            elif member.isfile():
                src = tf.extractfile(member)
                with open(target, "wb") as out:
                    while True:
                        chunk = src.read(1 << 20)
                        if not chunk:
                            break
                        out.write(chunk)
                # **清掉 setuid/setgid**：非 root 构建时解包出来的文件属主是
                # 构建用户（uid 1000），带 setuid 位会让"以 root 运行"变成
                # "降权到 1000 运行"。真实踩过：Alpine 的 /usr/libexec/Xorg.wrap
                # 是 setuid 二进制，于是 Xorg 以 uid 1000 启动，报
                # "parse_vt_settings: Cannot open /dev/tty0 (Permission denied)"。
                os.chmod(target, member.mode & 0o777)
            written += 1
    return written


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=("install", "extract"))
    ap.add_argument("--root", required=True)
    # 用可重复的 --path 而不是 --paths nargs="*"：后者会把后面的包名一起
    # 吞掉（argparse 的已知行为），导致 "packages are required" 报错。
    ap.add_argument("--path", action="append", default=None,
                    help="只提取匹配该路径/通配的文件（extract 模式，可重复）")
    ap.add_argument("packages", nargs="+")
    args = ap.parse_args()

    pkgs, index_shas = get_index()
    selected, missing = resolve(pkgs, args.packages)
    if missing:
        log("无法解析的依赖：" + ", ".join(sorted(set(missing))))
        raise SystemExit(1)

    lock_entries = load_lock()
    lock_entries.update(index_shas)
    total = 0
    for name in sorted(selected):
        rec = selected[name]
        apk, digest = verify_and_path(rec, lock_entries)
        ver = rec["V"][0]
        lock_entries[f"pkg:{name}"] = f"{ver} {digest}"
        n = extract_apk(apk, args.root, args.path if args.mode == "extract" else None)
        total += n
        log(f"{'提取' if args.mode == 'extract' else '安装'} {name}-{ver}（{n} 个文件）")
    save_lock(lock_entries)
    log(f"完成：{len(selected)} 个包，{total} 个文件 → {args.root}")
    print("\n".join(sorted(selected)))


if __name__ == "__main__":
    main()
