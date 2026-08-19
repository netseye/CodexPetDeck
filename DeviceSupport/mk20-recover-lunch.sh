#!/bin/sh

# Emergency recovery: leave USB gadget ownership to the stock KeyboardDevice.
# qt_app1 invokes this before KeyboardDevice, so doing nothing here restores
# the stable 1d6b:0104 CDC serial gadget on every subsequent boot.
killall codex-micro-bridge 2>/dev/null || true
rm -f /data/codex-micro-bridge
rm -f /data/usb_f_codexhid.ko
exit 0
