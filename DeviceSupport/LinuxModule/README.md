# MK20 Codex HID kernel module

`usb_f_codexhid.ko` is an out-of-tree USB ConfigFS function for the MK20's
Linux 5.4.61 kernel. The stock 5.4 HID function always allocates interrupt IN
and OUT endpoints; the T113 UDC cannot bind that pair. `codexhid` allocates
only interrupt IN and receives output reports through EP0 `SET_REPORT`.

The function is intentionally fixed to the Codex Micro descriptor (Vendor
Usage Page `0xFF00`, report ID `6`, 63-byte payload) and creates
`/dev/codexhidg0`. ConfigFS instances are named `codexhid.<instance>`.

The checked-in module has this exact vermagic:

```
5.4.61 SMP preempt mod_unload ARMv7 p2v8
```

It was built from the Tina Linux 5.4.61 tree with the kernel config extracted
from the user's `p4-kernel.bin`. The module alone never reconfigures USB; the
boot script owns binding and arms the recovery script before every risky step.
