The three kinds of modem on the 770ED
=====================================

1. MWave 3780i (built-in software modem, 56K/x2)
   - Kernel module `mwave` (shipped), but the DSP resources must have been
     assigned once by the BIOS-side ThinkPad configuration utility (installing
     the Windows driver once counts as "assigned").
   - Resource parameters: see /etc/modprobe.d/mwave.conf; afterwards the device
     is /dev/modems/mwave.
   - User space: the kernel tree has only the driver, not IBM's old `mwavem`
     daemon. Without it you can open the device but cannot actually dial. This
     is a known gap of this image.

2. PCMCIA serial modem (16-bit)
   - Plugging the card loads `serial_cs`, /dev/ttyS1 appears and pppd works:
       vi /etc/ppp/peers/modem      # device and speed
       vi /etc/ppp/pap-secrets      # login and password
       pppd call modem

3. USB 3G modem / serial adapter
   - `usb-serial` + `option` modules are shipped; /dev/ttyUSB0 appears, then the
     same procedure applies with a different device name.
