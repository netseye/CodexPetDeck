#!/bin/sh

# qt_app1 copies this file from /mnt/SDCARD/lunch.sh to /data/lunch.sh,
# chmods it, and runs it before KeyboardDevice starts.
# Arm the stock recovery script before touching the kernel module or UDC. If
# this boot crashes at any later point, the next power cycle executes recovery
# instead of retrying the risky operation forever.
RECOVERY_SCRIPT=/mnt/SDCARD/mk20-recover-lunch.sh
STABLE_SCRIPT=/mnt/SDCARD/mk20-codex-stable.sh
if [ -f "$RECOVERY_SCRIPT" ]; then
    cp "$RECOVERY_SCRIPT" /mnt/SDCARD/lunch.sh
    sync
fi

if [ -f /mnt/SDCARD/codex-micro-bridge ]; then
    cp /mnt/SDCARD/codex-micro-bridge /data/codex-micro-bridge
    chmod 755 /data/codex-micro-bridge
fi
if [ -f /mnt/SDCARD/usb_f_codexhid.ko ]; then
    cp /mnt/SDCARD/usb_f_codexhid.ko /data/usb_f_codexhid.ko
    chmod 644 /data/usb_f_codexhid.ko
fi

# qt_app1 normally marks these files executable only after the TF-card
# lunch.sh returns. This launcher deliberately stays in the foreground. Wait
# for the runtime payload to be mounted/populated, then make the prerequisites
# executable before the bridge starts appLunch.sh through /bin/sh. Without
# this preflight the guarded startup can race /data and fall back to CDC.
APP_FILE_CHECKS=0
while [ "$APP_FILE_CHECKS" -lt 30 ]; do
    if [ -f /data/appLunch.sh ] && \
       [ -f /data/qt_env.sh ] && \
       [ -f /data/KeyboardDevice ]; then
        break
    fi
    sleep 1
    APP_FILE_CHECKS=$((APP_FILE_CHECKS + 1))
done
if [ ! -f /data/appLunch.sh ] || \
   [ ! -f /data/qt_env.sh ] || \
   [ ! -f /data/KeyboardDevice ]; then
    # restore_serial_gadget is declared below; defer the actual fallback until
    # configure_codex_gadget runs so the stock CDC setup remains centralized.
    APP_PREREQUISITES_READY=0
else
    chmod 755 /data/appLunch.sh /data/KeyboardDevice
    APP_PREREQUISITES_READY=1
fi

LOG=/mnt/SDCARD/codex-micro.log
G=/sys/kernel/config/usb_gadget/g1
APP_RESTART=0

    restore_serial_gadget() {
        FAILURE_STAGE="${1:-unknown}"
        # Always unbind before changing functions/descriptors.  Removing a HID
        # link from a live gadget can leave macOS with neither ACM nor HID.
        killall codex-micro-bridge 2>/dev/null || true
        killall KeyboardDevice 2>/dev/null || true
        rm -f /tmp/codex-hid-pty-ready /tmp/codex-v2-live
        echo "" > "$G/UDC" 2>/dev/null || true
        rm -f "$G/configs/c.1/codexhid.codex"
        rm -f "$G/configs/c.1/hid.codex"
        rm -f "$G/configs/c.1/gser.usb0"
        rmdir "$G/functions/codexhid.codex" 2>/dev/null || true
        rmdir "$G/functions/gser.usb0" 2>/dev/null || true
        rmmod usb_f_codexhid 2>/dev/null || true
        [ -L /dev/ttyGS0 ] && rm -f /dev/ttyGS0
        mkdir -p "$G/functions/acm.usb0"
        [ -e "$G/configs/c.1/acm.usb0" ] || \
            ln -s "$G/functions/acm.usb0" "$G/configs/c.1/acm.usb0"
        echo 0x1d6b > "$G/idVendor"
        echo 0x0104 > "$G/idProduct"
        echo 0x00 > "$G/bDeviceClass"
        echo 0x00 > "$G/bDeviceSubClass"
        echo 0x00 > "$G/bDeviceProtocol"
        echo "0123456789ABCDEF" > "$G/strings/0x409/serialnumber"
        echo "Allwinner Technology Inc." > "$G/strings/0x409/manufacturer"
        # Expose the exact failing operation to the macOS USB registry.  The
        # normal CDC transport remains usable, so the next installer can fix
        # the gadget without an ADB/recovery detour.
        echo "Serial CodexFail-${FAILURE_STAGE}" > "$G/strings/0x409/product"
        echo "$UDC" > "$G/UDC"
        echo "codex-micro: ${FAILURE_STAGE} failed; restored CDC" >> "$LOG"
        if [ "$APP_RESTART" = "1" ]; then
            # Keep the diagnostic USB product visible long enough for the host
            # to capture it. KeyboardDevice may restore the generic "Serial"
            # product string as soon as it starts.
            sleep 45
            /data/appLunch.sh >> "$LOG" 2>&1 &
            APP_RESTART=0
        fi
    }

    configure_codex_gadget() {
        if [ "$APP_PREREQUISITES_READY" != "1" ]; then
            restore_serial_gadget "app-prerequisites"
            return 1
        fi
        if [ ! -d /sys/kernel/config/usb_gadget ]; then
            mount -t configfs none /sys/kernel/config || {
                restore_serial_gadget "configfs"
                return 1
            }
        fi
        mkdir -p "$G/strings/0x409" "$G/configs/c.1" || {
            restore_serial_gadget "gadget-dirs"
            return 1
        }
        if [ ! -d /sys/module/usb_f_codexhid ]; then
            insmod /data/usb_f_codexhid.ko || {
                restore_serial_gadget "module-load"
                return 1
            }
        fi
        mkdir -p "$G/functions/codexhid.codex" || {
            restore_serial_gadget "codexhid-function"
            return 1
        }

        # codexhid has the exact report descriptor built in and allocates only
        # interrupt IN. Host output reports arrive through EP0 SET_REPORT.
        rm -f "$G/configs/c.1/codexhid.codex" "$G/configs/c.1/hid.codex"

        # Stop the stock V2 process before releasing its ACM function.  The
        # bridge below gives it a local PTY named /dev/ttyGS0 and multiplexes
        # that byte stream over HID channel 3, so the USB gadget needs only the
        # custom module's single interrupt IN endpoint.
        killall KeyboardDevice 2>/dev/null || true
        killall codex-micro-bridge 2>/dev/null || true
        APP_RESTART=1
        EXIT_CHECKS=0
        while pidof KeyboardDevice >/dev/null 2>&1 && [ "$EXIT_CHECKS" -lt 10 ]; do
            sleep 1
            EXIT_CHECKS=$((EXIT_CHECKS + 1))
        done
        if pidof KeyboardDevice >/dev/null 2>&1; then
            killall -9 KeyboardDevice 2>/dev/null || true
            sleep 1
        fi

        echo "" > "$G/UDC" || {
            restore_serial_gadget "unbind"
            return 1
        }
        rm -f "$G/configs/c.1/codexhid.codex" \
              "$G/configs/c.1/hid.codex" \
              "$G/configs/c.1/acm.usb0" \
              "$G/configs/c.1/gser.usb0"
        rmdir "$G/functions/hid.codex" 2>/dev/null || true
        rmdir "$G/functions/gser.usb0" 2>/dev/null || true
        if [ -d "$G/functions/acm.usb0" ]; then
            rmdir "$G/functions/acm.usb0" 2>/dev/null || {
                restore_serial_gadget "acm-release"
                return 1
            }
        fi
        [ -L /dev/ttyGS0 ] && rm -f /dev/ttyGS0

        echo 0x303a > "$G/idVendor"
        echo 0x8360 > "$G/idProduct"
        echo 0x0100 > "$G/bcdDevice"
        echo 0x0200 > "$G/bcdUSB"
        echo 0x00 > "$G/bDeviceClass"
        echo 0x00 > "$G/bDeviceSubClass"
        echo 0x00 > "$G/bDeviceProtocol"
        echo "MK20-CODEX-001" > "$G/strings/0x409/serialnumber"
        echo "Work Louder" > "$G/strings/0x409/manufacturer"
        echo "kbd-1.0-codex-micro" > "$G/strings/0x409/product"
        ln -s "$G/functions/codexhid.codex" \
              "$G/configs/c.1/codexhid.codex" || {
            restore_serial_gadget "codexhid-link"
            return 1
        }
        echo "$UDC" > "$G/UDC" || {
            restore_serial_gadget "codexhid-bind"
            return 1
        }

        CHECKS=0
        while [ "$CHECKS" -lt 10 ]; do
            [ -c /dev/codexhidg0 ] && break
            sleep 1
            CHECKS=$((CHECKS + 1))
        done
        if [ ! -c /dev/codexhidg0 ]; then
            restore_serial_gadget "codexhid-node"
            return 1
        fi

        # Start the bridge while the recovery decision can still be made. The
        # ready marker proves PTY creation worked; a live KeyboardDevice proves
        # the original V2 process accepted that PTY. Do not require V2 bytes
        # here: KeyboardDevice only emits them after a macOS host handshake, so
        # making boot success depend on host traffic creates a circular health
        # check and incorrectly restores CDC when the companion is not running.
        rm -f /tmp/codex-hid-pty-ready /tmp/codex-v2-live
        /data/codex-micro-bridge >> "$LOG" 2>&1 &
        BRIDGE_PID=$!
        READY_CHECKS=0
        while [ ! -f /tmp/codex-hid-pty-ready ] && [ "$READY_CHECKS" -lt 10 ]; do
            kill -0 "$BRIDGE_PID" 2>/dev/null || break
            sleep 1
            READY_CHECKS=$((READY_CHECKS + 1))
        done
        if [ ! -f /tmp/codex-hid-pty-ready ]; then
            restore_serial_gadget "pty-bridge"
            return 1
        fi

        APP_CHECKS=0
        while ! pidof KeyboardDevice >/dev/null 2>&1 && [ "$APP_CHECKS" -lt 20 ]; do
            kill -0 "$BRIDGE_PID" 2>/dev/null || break
            sleep 1
            APP_CHECKS=$((APP_CHECKS + 1))
        done
        if ! kill -0 "$BRIDGE_PID" 2>/dev/null || \
           ! pidof KeyboardDevice >/dev/null 2>&1; then
            restore_serial_gadget "keyboarddevice-start"
            return 1
        fi

        # /etc/init.d/qt_app1 executes the TF-card lunch.sh synchronously and,
        # only after it returns, invokes the factory usb_device trigger. Keep
        # this launcher in the foreground so that stock step can never replace
        # our PTY-backed HID gadget with ACM. KeyboardDevice itself does not own
        # the factory USB trigger; five seconds of process/descriptor health is
        # therefore sufficient before persisting this launcher for next boot.
        HEALTH_CHECKS=0
        while [ "$HEALTH_CHECKS" -lt 5 ]; do
            if ! kill -0 "$BRIDGE_PID" 2>/dev/null || \
               ! pidof KeyboardDevice >/dev/null 2>&1 || \
               [ "$(cat "$G/idVendor" 2>/dev/null)" != "0x303a" ] || \
               [ "$(cat "$G/idProduct" 2>/dev/null)" != "0x8360" ] || \
               [ "$(cat "$G/strings/0x409/product" 2>/dev/null)" != "kbd-1.0-codex-micro" ]; then
                restore_serial_gadget "foreground-health"
                return 1
            fi
            sleep 1
            HEALTH_CHECKS=$((HEALTH_CHECKS + 1))
        done
        APP_RESTART=0
        # Reinstall the stable launcher only after HID, PTY and KeyboardDevice
        # have all survived together. The launcher arms recovery again before
        # every future attempt.
        if [ -f "$STABLE_SCRIPT" ]; then
            cp "$STABLE_SCRIPT" /mnt/SDCARD/lunch.sh
            sync
        fi
        echo "codex-micro: foreground owner keeps 303A:8360 HID + PTY stable; V2 awaits host" >> "$LOG"
        return 0
    }

# Wait for the controller, not for qt_app1's stock usb_device trigger. This
# script intentionally never returns while the custom bridge is healthy.
UDC_CHECKS=0
while [ "$UDC_CHECKS" -lt 10 ]; do
    UDC=$(ls /sys/class/udc 2>/dev/null | head -n 1)
    [ -n "$UDC" ] && break
    sleep 1
    UDC_CHECKS=$((UDC_CHECKS + 1))
done
    if [ -z "$UDC" ]; then
        echo "codex-micro: no UDC" >> "$LOG"
        exit 1
    fi

    if ! configure_codex_gadget; then
        # Never retry gadget reconfiguration in a loop: repeated UDC binds make
        # the working CDC port disappear and re-enumerate every few seconds.
        exit 1
    fi
    while [ -c /dev/codexhidg0 ]; do
        wait "$BRIDGE_PID" 2>/dev/null || true
        [ -c /dev/codexhidg0 ] || break
        killall KeyboardDevice 2>/dev/null || true
        rm -f /tmp/codex-hid-pty-ready /tmp/codex-v2-live
        /data/codex-micro-bridge >> "$LOG" 2>&1 &
        BRIDGE_PID=$!
        sleep 2
    done

# Let qt_app1 continue to its factory USB fallback if the character device or
# bridge supervision loop ever ends unexpectedly.
exit 1
