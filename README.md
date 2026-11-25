# Sonim Spot™ H500 / H500V 5G — macOS USB-C Tethering (`CDC-ECM`) Bug Analysis & Fix

> **TL;DR:** Connecting a **Sonim Spot™ H500 / H500V 5G Mobile Hotspot** (`VID 0x1D9C`, `PID 0xA011`) to a Mac via USB-C and selecting **Access Internet** fails to create a network interface on macOS/iPadOS/iOS—even with **USB Tethering** enabled in the Web UI.
>
> **Root Cause:** In firmware `H50.1-05-5.4.0-15.17.00` (Qualcomm SDX65 QTI Linux `LE.UM.6.2.3`), `/sbin/usb/compositions/1D9C_A011` is designed as a dual-configuration USB gadget (`c.1 = RNDIS` for Windows, `c.2 = CDC-ECM` for macOS). However, the ODM commented out `#mkdir configs/c.2` and `#mkdir configs/c.2/strings/0x409` after `rmdir configs/c.2`, causing the `else` branch that configures `functions/gsi.ecm` (`CDC-ECM`) to fail silently with `No such file or directory`.
>
> Restoring `mkdir -p configs/c.2/strings/0x409` inside the `else` branch immediately enables plug-and-play native `CDC-ECM` (`AppleUserECM`) USB-C tethering on macOS while preserving `RNDIS` for Windows.

---

## 1. Symptoms & Official Documentation Comparison

According to the official **Sonim H500 5G Mobile Hotspot User Guide** (*Verizon v3.1 / NAM v1.3*):
- **Page 4 (System Requirements):** *"It is compatible with all major operating systems... Please use the provided USB 3.0 cable for tethering and charging your device."*
- **Page 60 (Web UI > Settings > Device Settings > USB Tethering):** Must be toggled from *Disable* (default) to **Enable** (`/action/websGetDstCtrl` → `{"retcode":0,"usbTecherEnable":1}`).
- **Page 22 & Page 63 (USB Connection Options):** When plugged into a computer via USB-C, the H500 touchscreen displays:
  - *Charge This Hotspot*
  - *Charge The Connected Device*
  - **Access Internet** *(only appears when USB Tethering is enabled in Web UI)*
  - *Software Update Assistant (SUA)*

### What Actually Happens on macOS (Unpatched Firmware)

When selecting **Access Internet**, `ioreg -p IOUSB` on macOS shows `bNumConfigurations = 1`, exposing **only Configuration 1 (`Microsoft RNDIS`, `bInterfaceClass = 0xEF / 239, SubClass = 4, Protocol = 1`)**:

```text
+-o SDXLEMUR-LITE-MTP _SN:XXXXXXXX@02200000  <class IOUSBHostDevice>
  |   "idVendor" = 7580 (0x1D9C - Sonim Technologies)
  |   "idProduct" = 40977 (0xA011)
  |   "bNumConfigurations" = 1
  |   "kUSBCurrentConfiguration" = 1
  +-o RNDIS Communications Control@0  <class IOUSBHostInterface>
  |     "bInterfaceClass" = 239
  |     "bInterfaceSubClass" = 4
  |     "bInterfaceProtocol" = 1
  +-o RNDIS Ethernet Data@1  <class IOUSBHostInterface>
        "bInterfaceClass" = 10
```

Because macOS does not include a built-in driver for proprietary Microsoft RNDIS (macOS natively supports USB `CDC-ECM` and `CDC-NCM`), **no `enX` network interface is created**.

---

## 2. Root Cause in Firmware (`/sbin/usb/compositions/1D9C_A011`)

Qualcomm's reference dual-configuration script (`/sbin/usb/compositions/9057`, `# DESCRIPTION: RNDIS : ECM`) exposes **two USB configurations** on the same PID so both Windows and macOS work without third-party drivers:
- **Configuration 1 (`configs/c.1`):** `functions/gsi.rndis` (selected by Windows)
- **Configuration 2 (`configs/c.2`):** `functions/gsi.ecm` (automatically selected by macOS `AppleUSBCDCCompositeDevice` / `AppleUserECM`)

When the ODM cloned `9057` into `/sbin/usb/compositions/1D9C_A011` to add an `if [ -f /usrdata/data/usr/usb_sua ... ]` branch for **Software Update Assistant (`MS_ADB`)** (which only uses `configs/c.1`), they commented out `#mkdir configs/c.2` at the top of `run_configfs()` so `MS_ADB` wouldn't have an empty `c.2`, **but forgot to move `mkdir -p configs/c.2/strings/0x409` into the `else` branch**:

```sh
run_configfs() {
	pkill adbd
	cd /sys/kernel/config/usb_gadget/g1
	rm os_desc/c* 2> /dev/null
	rm configs/c*/f* 2> /dev/null
	rmdir configs/c.2/strings/* configs/c.3/strings/* 2> /dev/null
	rmdir configs/c.2 configs/c.3 2> /dev/null
	#mkdir configs/c.2                  # <--- Commented out by ODM!
	#mkdir configs/c.2/strings/0x409    # <--- Commented out by ODM!
	echo 0x1D9C > idVendor
	echo 0xA011 > idProduct
	if [ -f /usrdata/data/usr/usb_sua -o -f /data/usb_sua ]; then
		echo "MS_ADB" > configs/c.1/strings/0x409/configuration
		...
	else
	    echo "RNDIS" > configs/c.1/strings/0x409/configuration
	    echo "ECM" > configs/c.2/strings/0x409/configuration   # <--- FAILS (c.2 does not exist!)
	    ln -s functions/gsi.rndis configs/c.1/f1
	    ln -s functions/gsi.ecm configs/c.2/f1                # <--- FAILS (c.2 does not exist!)

	    echo 0xA0 > configs/c.1/bmAttributes
	    echo 0xA0 > configs/c.2/bmAttributes                  # <--- FAILS (c.2 does not exist!)
	fi
```

Additionally, `run_configfs()` did not unbind `UDC` (`echo "" > UDC`) prior to removing active `configs/c*/f*` symlinks when switching modes live while a USB cable is attached.

---

## 3. Minimal Fix (`patches/1D9C_A011.patch`)

See [`patches/1D9C_A011.patch`](patches/1D9C_A011.patch):

```diff
 run_configfs() {
 	pkill adbd
 	cd /sys/kernel/config/usb_gadget/g1
+	echo "" > UDC 2> /dev/null
 	rm os_desc/c* 2> /dev/null
 	rm configs/c*/f* 2> /dev/null
 	rmdir configs/c.2/strings/* configs/c.3/strings/* 2> /dev/null
 	rmdir configs/c.2 configs/c.3 2> /dev/null
-	#mkdir configs/c.2
-	#mkdir configs/c.2/strings/0x409
 	echo 0x1D9C > idVendor
 	echo 0xA011 > idProduct
 	if [ -f /usrdata/data/usr/usb_sua -o -f /data/usb_sua ]; then
@@ -120,6 +119,7 @@
 
 		echo 0xA0 > configs/c.1/bmAttributes
 	else
+	    mkdir -p configs/c.2/strings/0x409
 	    echo "RNDIS" > configs/c.1/strings/0x409/configuration
 	    echo "ECM" > configs/c.2/strings/0x409/configuration
 	    ln -s functions/gsi.rndis configs/c.1/f1
```

### Verification on macOS After Applying the Fix

With `configs/c.2` restored, macOS enumerates `bNumConfigurations = 2`, automatically selects `kUSBCurrentConfiguration = 2` (`CDC Ethernet Control Model (ECM)`), binds `com.apple.DriverKit.AppleUserECM`, and acquires a DHCP lease (`192.168.1.x/24`) over USB 3.2 (`10 Gbps`):

```text
+-o SDXLEMUR-LITE-MTP _SN:XXXXXXXX@02200000  <class IOUSBHostDevice>
  |   "bNumConfigurations" = 2
  |   "idVendor" = 7580
  |   "kUSBCurrentConfiguration" = 2
  |   "idProduct" = 40977
  +-o AppleUSBCDCCompositeDevice
  +-o CDC Ethernet Control Model (ECM)@0  <class IOUSBHostInterface>
  | |   "bInterfaceClass" = 2
  | |   "bInterfaceSubClass" = 6
  | |   "kUSBString" = "CDC Ethernet Control Model (ECM)"
  | |   "bConfigurationValue" = 2
  | +-o AppleUserECM  <class IOUserNetworkEthernet>
  |   +-o IOSkywalkLegacyEthernet
  |     +-o en22  <class IOSkywalkLegacyEthernetInterface>
  +-o IOUSBHostInterface@1
    +-o AppleUserECMData
```

---

## 4. Workarounds & Community Self-Fix on macOS

### Option A: Zero-Modification Workaround (Use the Built-In RJ45 Ethernet Port)
If you do not wish to modify the hotspot:
1. On the H500 touchscreen, go to **Menu > Settings** (swipe to page 2) > enable **Ethernet** (toggle turns green, *User Guide p. 36*).
2. Connect an RJ45 Ethernet cable from the H500 to a USB-C/Thunderbolt Ethernet adapter on your Mac. This works plug-and-play on macOS and leaves the H500's USB-C port free for charging.

### Option B: Persistent Bind-Mount Fix on the H500 (Directly from macOS, No VM Needed)

Because the root filesystem on the H500 is read-only, we store the patched `1D9C_A011` script in `/data/usb-fix/1D9C_A011` and bind-mount it over `/sbin/usb/compositions/1D9C_A011` at boot via `/etc/udev/scripts/ipacm_udev.sh` (which ships world-writable `0777` and is executed as root by `systemd-udevd`). **No NAND/UBI system partition is modified, and the fix is 100% reversible.**

#### Note on Connecting via ADB on macOS (`ADB_LIBUSB=1`)
When you select **Software Update Assistant (SUA)** on the H500 touchscreen, the device exposes a composite USB gadget (`IF0 = Mass Storage CD-ROM`, `IF1 = ADB Interface`). On macOS, default IOKit matching in `adb` ignores `IF1`, **but setting `ADB_LIBUSB=1` allows `adb` on macOS to bind `IF1` directly without needing a Linux VM**:

```bash
brew install android-platform-tools
adb kill-server
ADB_LIBUSB=1 adb devices -l
```

#### Automated Install
1. Enable **Web UI (`http://192.168.1.1`) > Settings > Device Settings > USB Tethering**.
2. Plug the USB-C cable into your Mac and select **Software Update Assistant (SUA)** on the H500 touchscreen.
3. Run:
   ```bash
   ./scripts/install-macos-usb-fix.sh
   ```
4. Reboot the H500 once (or toggle Mobile Data in the Web UI), then select **Access Internet** on the H500 touchscreen. Your Mac will immediately create a `SDXLEMUR-LITE-MTP` USB Ethernet interface (`enX`) and obtain a DHCP IP (`192.168.1.x`).

#### Uninstall / Rollback
Plug in the H500, select **Software Update Assistant (SUA)**, and run:
```bash
./scripts/install-macos-usb-fix.sh --uninstall
```
Then reboot the hotspot.

---

## Tóm tắt Tiếng Việt

1. **Nguyên nhân cắm cáp USB-C từ macOS vào Sonim H500 chọn *Access/Connect Internet* không có mạng:**
   - Trong script `/sbin/usb/compositions/1D9C_A011` (`# DESCRIPTION: RNDIS : ECM`), kỹ sư ODM comment nhầm `#mkdir configs/c.2` sau lệnh `rmdir configs/c.2`.
   - Do đó các lệnh tạo cấu hình 2 (`configs/c.2` — chuẩn `CDC-ECM` cho macOS/iPadOS/iOS) bị lỗi `No such file or directory`, chỉ còn cấu hình 1 (`Microsoft RNDIS` cho Windows, vốn macOS không có driver native).
2. **Cách khắc phục:**
   - **Không chạm hệ thống:** Bật **Menu > Settings > (vuốt trang 2) > Ethernet** trên màn hình H500 và cắm cáp mạng qua cổng RJ45.
   - **Sửa lỗi USB-C Tethering (`CDC-ECM` native trên macOS):** Chuyển màn hình USB của H500 sang **Software Update Assistant (SUA)**, chạy `./scripts/install-macos-usb-fix.sh` ngay trên macOS (dùng `ADB_LIBUSB=1 adb` nhận thẳng không cần VM) để bind-mount bản vá khôi phục `mkdir -p configs/c.2/strings/0x409`.
