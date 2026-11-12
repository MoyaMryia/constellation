770ED 的三种猫
==============

1. MWave 3780i（内置软猫，56K/x2）
   - 内核模块 mwave（镜像已带），但 DSP 资源必须先由 BIOS 侧的 ThinkPad
     配置工具分配过（出厂时装过一次 Windows 驱动即算分配过）。
   - 资源参数见 /etc/modprobe.d/mwave.conf，加载后 /dev/modems/mwave。
   - 用户态：内核树内只有驱动，没有 IBM 当年的 mwavem 守护进程；
     缺它就只能到"设备可打开"这一步，不能真正拨号。这是本镜像的已知缺口。

2. PCMCIA 串口猫（16 位）
   - 插卡后 serial_cs 自动加载，出现 /dev/ttyS1，pppd 直接可用：
       vi /etc/ppp/peers/modem      # 设备与速率
       vi /etc/ppp/pap-secrets      # 账号密码
       pppd call modem

3. USB 3G 猫 / 串口适配器
   - usb-serial + option 模块已带；出现 /dev/ttyUSB0 后同上，只是设备名不同。
