#!/usr/bin/env bash
# Automated macOS USB-C Tethering (CDC-ECM) Fix for Sonim Spot H500 / H500V 5G
# Pulls /sbin/usb/compositions/1D9C_A011 from the connected device, backs up original
# files, restores the missing `mkdir -p configs/c.2/strings/0x409` for CDC-ECM, and
# installs a persistent read-only bind-mount hook in /data/usb-fix/.
#
# Usage:
#   ./scripts/install-macos-usb-fix.sh             # Install & activate live
#   ./scripts/install-macos-usb-fix.sh --uninstall # Revert to factory state

set -euo pipefail

export ADB_LIBUSB=1
ADB_BIN="${ADB_BIN:-$(command -v adb || true)}"
if [[ -z "$ADB_BIN" ]]; then
  echo "[!] Error: 'adb' not found. Install on macOS via: brew install android-platform-tools" >&2
  exit 1
fi

echo "[*] Restarting ADB server with ADB_LIBUSB=1 (required on macOS for composite SUA mode)..."
"$ADB_BIN" kill-server >/dev/null 2>&1 || true
"$ADB_BIN" start-server >/dev/null 2>&1

DEV_SERIAL=$("$ADB_BIN" devices | awk 'NR>1 && $2=="device" {print $1; exit}')
if [[ -z "$DEV_SERIAL" ]]; then
  echo "[!] No Sonim H500 detected in ADB mode." >&2
  echo "    1. Connect the H500 to your Mac via a USB 3.0+ Type-C data cable." >&2
  echo "    2. On the H500 touchscreen prompt ('USB Connection Options'), select:" >&2
  echo "       'Software Update Assistant (SUA)' and tap OK." >&2
  echo "    3. Re-run this script." >&2
  exit 1
fi

echo "[+] Connected to H500 via ADB"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

if [[ "${1:-}" == "--uninstall" ]]; then
  echo "[*] Preparing uninstall / rollback..."
  "$ADB_BIN" -s "$DEV_SERIAL" pull /etc/udev/scripts/ipacm_udev.sh "$WORKDIR/ipacm_udev.sh" >/dev/null
  grep -v "usb-fix" "$WORKDIR/ipacm_udev.sh" > "$WORKDIR/ipacm_udev.sh.clean"
  "$ADB_BIN" -s "$DEV_SERIAL" push "$WORKDIR/ipacm_udev.sh.clean" /tmp/ipacm_udev.sh.clean >/dev/null
  "$ADB_BIN" -s "$DEV_SERIAL" shell '
    cp -f /tmp/ipacm_udev.sh.clean /etc/udev/scripts/ipacm_udev.sh
    chmod 777 /etc/udev/scripts/ipacm_udev.sh
    rm -f /tmp/ipacm_udev.sh.clean
  ' < /dev/null
  echo "[+] Hook removed from /etc/udev/scripts/ipacm_udev.sh."
  echo "    Reboot the H500 hotspot to complete rollback to factory state."
  exit 0
fi

echo "[*] Pulling factory /sbin/usb/compositions/1D9C_A011 and /etc/udev/scripts/ipacm_udev.sh..."
"$ADB_BIN" -s "$DEV_SERIAL" pull /sbin/usb/compositions/1D9C_A011 "$WORKDIR/1D9C_A011.orig" >/dev/null
"$ADB_BIN" -s "$DEV_SERIAL" pull /etc/udev/scripts/ipacm_udev.sh "$WORKDIR/ipacm_udev.sh.orig" >/dev/null

python3 - "$WORKDIR/1D9C_A011.orig" "$WORKDIR/1D9C_A011.patched" << 'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src, "r", encoding="utf-8").read()

if "mkdir -p configs/c.2/strings/0x409" in text:
    print("[*] 1D9C_A011 already contains the CDC-ECM c.2 directory fix.")
    open(dst, "w", encoding="utf-8").write(text)
    sys.exit(0)

old_top = "\tcd /sys/kernel/config/usb_gadget/g1\n\trm os_desc/c* 2> /dev/null"
new_top = "\tcd /sys/kernel/config/usb_gadget/g1\n\techo \"\" > UDC 2> /dev/null\n\trm os_desc/c* 2> /dev/null"

old_else = '\telse\n\t    echo "RNDIS" > configs/c.1/strings/0x409/configuration'
new_else = '\telse\n\t    mkdir -p configs/c.2/strings/0x409\n\t    echo "RNDIS" > configs/c.1/strings/0x409/configuration'

if old_else not in text:
    raise SystemExit("[!] Unexpected 1D9C_A011 format; aborting cleanly.")

text = text.replace(old_top, new_top, 1).replace(old_else, new_else, 1)
open(dst, "w", encoding="utf-8").write(text)
print("[+] Patched 1D9C_A011: restored configs/c.2/strings/0x409 for CDC-ECM.")
PY

python3 - "$WORKDIR/ipacm_udev.sh.orig" "$WORKDIR/ipacm_udev.sh.patched" << 'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
lines = open(src, "r", encoding="utf-8").splitlines(True)

hook_marker = "# === usb-fix: restore CDC-ECM c.2 on 1D9C_A011 for macOS ==="
hook_block = """# === usb-fix: restore CDC-ECM c.2 on 1D9C_A011 for macOS ===
[ -x /data/usb-fix/sh ] || { mkdir -p /data/usb-fix 2>/dev/null; cp -f /bin/busybox.nosuid /data/usb-fix/sh 2>/dev/null; chmod 6755 /data/usb-fix/sh 2>/dev/null; }
if [ -f /tmp/usb_fix_install.tar ]; then
  mkdir -p /data/usb-fix 2>/dev/null
  tar -xf /tmp/usb_fix_install.tar -C /data/usb-fix 2>/dev/null
  chmod 755 /data/usb-fix/1D9C_A011 2>/dev/null
  rm -f /tmp/usb_fix_install.tar
fi
if [ -x /data/usb-fix/1D9C_A011 ] && ! grep -qs "/sbin/usb/compositions/1D9C_A011" /proc/mounts; then
  mount -o bind /data/usb-fix/1D9C_A011 /sbin/usb/compositions/1D9C_A011 2>/dev/null
  [ ! -d /sys/kernel/config/usb_gadget/g1/configs/c.2 ] && [ ! -f /usrdata/data/usr/usb_sua ] && [ ! -f /data/usb_sua ] && [ "$(cat /etc/usb/boot_hsusb_comp 2>/dev/null)" = "1D9C_A011" ] && /sbin/usb/compositions/1D9C_A011 >/dev/null 2>&1 &
fi
if [ -d /sys/class/net/ecm0 ] && [ ! -d /sys/class/net/ecm0/brport ]; then
  ip link set ecm0 up 2>/dev/null
  brctl addif bridge0 ecm0 2>/dev/null
fi
if [ -f /data/usb-fix/switch_internet ]; then
  rm -f /data/usb-fix/switch_internet /usrdata/data/usr/usb_sua /data/usb_sua
  echo 3 > /usrdata/mode.cfg
  /sbin/usb/compositions/1D9C_A011 >/dev/null 2>&1 &
fi
# === end usb-fix ===
"""

clean_lines = []
skip = False
for line in lines:
    if "# === usb-fix:" in line:
        skip = True
        continue
    if "# === end usb-fix ===" in line:
        skip = False
        continue
    if not skip:
        clean_lines.append(line)

out = [clean_lines[0], hook_block] + clean_lines[1:]
open(dst, "w", encoding="utf-8").writelines(out)
print("[+] Prepared udev bind-mount hook.")
PY

cp "$WORKDIR/1D9C_A011.patched" "$WORKDIR/1D9C_A011"
chmod 755 "$WORKDIR/1D9C_A011"
tar -cf "$WORKDIR/usb_fix_install.tar" -C "$WORKDIR" 1D9C_A011 1D9C_A011.orig ipacm_udev.sh.orig

echo "[*] Pushing payload and installing hook..."
"$ADB_BIN" -s "$DEV_SERIAL" push "$WORKDIR/usb_fix_install.tar" /tmp/usb_fix_install.tar >/dev/null
"$ADB_BIN" -s "$DEV_SERIAL" push "$WORKDIR/ipacm_udev.sh.patched" /tmp/ipacm_udev.sh.patched >/dev/null
"$ADB_BIN" -s "$DEV_SERIAL" shell '
  cp -f /tmp/ipacm_udev.sh.patched /etc/udev/scripts/ipacm_udev.sh
  chmod 777 /etc/udev/scripts/ipacm_udev.sh
  rm -f /tmp/ipacm_udev.sh.patched
  grep -q "ecm0" /etc/udev/rules.d/ipacm.rules 2>/dev/null || echo '\''SUBSYSTEM=="net", KERNEL=="ecm0|rndis0|rmnet_data0", RUN+="/etc/udev/scripts/ipacm_udev.sh net"'\'' >> /etc/udev/rules.d/ipacm.rules
' < /dev/null

echo "[+] Hook installed."
echo "     If this is the first run, reboot the H500 once (or toggle Mobile Data in Web UI http://192.168.1.1)"
echo "    and select 'Access Internet' on the H500 screen."
