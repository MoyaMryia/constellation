#!/usr/bin/env python3
"""与 QEMU 的串口 unix socket 对话：等待、按需发送若干行、再收取输出。

用法：
    qemu-serial.py <socket> [--wait N] [--send LINE]... [--tail N] [--timeout N]

--wait  ：连接后先静默收集 N 秒（默认 45，等启动到 login）。
--send  ：依次发送的行（每个参数一行，自动补 \\n），发送间隔 1 秒。
--tail  ：发送完全部行后继续收集 N 秒（默认 5）。
--timeout：单次 recv 的等待上限（默认 1.0 秒，用于判定"暂时没数据了"）。
输出：把整段串口数据原样写到 stdout。

这是开发/验收工具（内存下限扫描脚本也用它），不进入目标系统 rootfs。
"""
import argparse
import socket
import sys
import time


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("socket")
    ap.add_argument("--wait", type=float, default=45.0)
    ap.add_argument("--send", action="append", default=[])
    ap.add_argument("--tail", type=float, default=5.0)
    ap.add_argument("--timeout", type=float, default=1.0)
    ap.add_argument("--quiet", action="store_true", help="只输出，不做任何判定")
    args = ap.parse_args()

    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(args.timeout)
    s.connect(args.socket)
    out = bytearray()

    def pump(seconds: float) -> None:
        end = time.time() + seconds
        while time.time() < end:
            try:
                chunk = s.recv(8192)
            except socket.timeout:
                continue
            except OSError:
                break
            if not chunk:
                break
            out.extend(chunk)

    pump(args.wait)
    for line in args.send:
        try:
            s.sendall(line.encode() + b"\n")
        except OSError:
            break
        pump(1.0)
    pump(args.tail)

    sys.stdout.buffer.write(bytes(out))
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
