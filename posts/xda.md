<!-- XDA 论坛风格。发帖时标题用第一行，正文从 Disclaimer 开始。
     XDA 支持 BBCode 和部分 Markdown；下面的表格如果显示不正常，可改成 [CODE] 块。 -->

# [GUIDE][ROOT] Debian 13 in a real VM on Galaxy S25 Ultra (Snapdragon, locked bootloader) — where Android's "Linux Terminal" fails and how to get around it

**TL;DR** — Android 16's built-in Linux Terminal cannot work on Snapdragon phones: it asks
for a *non-protected* VM and the Gunyah firmware refuses. But the *protected* VM path is
open, and `crosvm --protected-vm-without-firmware` uses it while skipping pvmfw's signature
check. Result: Debian 13 with its own kernel, systemd and a root shell — on a **carrier-locked,
never-unlockable SM-S938U**.

![Debian 13 booting on a Galaxy S25 Ultra](https://raw.githubusercontent.com/roobtx/s25u-native-linux/main/screenshots/debian-boot.jpg)

*Debian 13 finishing boot on a carrier-locked SM-S938U. Termux's extra key rows are visible at the bottom — this is running on the phone itself.*

---

## Disclaimer

Standard stuff: this needs root, it runs a VM with root privileges, and it writes to a disk
image. I'm not responsible for your data, your warranty or your device. Nothing here touches
any partition — no flashing, no bootloader unlock, SELinux stays **Enforcing** throughout —
but read what you're running before you run it.

---

## What this is / isn't

**Is:**
- A real virtual machine. Own kernel (6.12.63), own init, own userspace.
- Debian 13 (trixie), full apt, systemd, root shell.
- No chroot, no proot, no ptrace overhead.

**Isn't (yet):**
- No networking. No GPU/display. Serial console only.
- Not persistent across reboots — because temp root isn't.
- Not the official Linux Terminal app. That app **cannot** be made to work on this SoC
  (explained below); this bypasses it entirely.

---

## Tested on

| | |
|---|---|
| Device | SM-S938U (Galaxy S25 Ultra, US) |
| SoC | Snapdragon 8 Elite |
| ROM | Android 16 / One UI 8.0, Jan 2026 patch |
| Bootloader | **Locked**, no OEM-unlock toggle (US model — it will never unlock) |
| Root | KernelSU 3.2.5 (temporary) |
| Hypervisor | Gunyah (`/sys/hypervisor/type` = gunyah) |
| Terminal | Termux |

Should apply to any Snapdragon 8 Elite device with Gunyah + the `com.android.virt` APEX.
Reported working on Lenovo Legion Y700 gen4 by the author of the guide I credit below.

---

## Requirements

1. **Root.** Any method. On US Samsung models the bootloader can't be unlocked, so you're
   looking at temporary/exploit-based root (KernelSU, APatch, etc.).
2. **Termux** (or any root shell).
3. **~2 GB free storage** for the disk image (it's sparse; apparent size is much larger).
4. The **ferrochrome Debian image**. Two ways to get it — see step 1.

---

## Instructions

### Step 1 — Get the disk image

The stock Linux Terminal app can't *boot* a VM, but its **downloader works fine**. Easiest
route is to let it fetch the image (~525 MB download):

```bash
su -c 'pm enable com.android.virtualization.terminal'
su -c 'settings put global linux_terminal_available 1'
su -c 'am start -n com.android.virtualization.terminal/.MainActivity'
```

Tap **Install** on the phone and wait. The image lands in
`/data/user/0/com.android.virtualization.terminal/files/linux/`.

> Note: Samsung removed the "Linux development environment" toggle from developer options in
> the One UI 8 release build, which is why you have to enable the package manually.

Alternatively, download it yourself:

```bash
curl -LO https://dl.google.com/android/ferrochrome/3500000/aarch64/images.tar.gz
tar xf images.tar.gz     # gives you root_part and vmlinuz
```

### Step 2 — Install

```bash
git clone https://github.com/roobtx/s25u-native-linux
cd s25u-native-linux
bash setup.sh
```

This copies the image to `/data/local/tmp/linuxvm` (preserving sparseness — about 1.6 GB
actual) and installs the `linuxvm` launcher.

### Step 3 — Boot

```bash
linuxvm
```

You land at a root prompt. Type `poweroff` inside the VM to shut down cleanly.

```
linuxvm: booting Debian 13  (2048 MiB, 2 vCPU) — 'poweroff' to exit
[    0.000000] Booting Linux on physical CPU 0x0000000000
[    0.000000] Linux version 6.12.63-android16-6
[    0.783142] systemd[1]: systemd 257.9-1~deb13u1 running in system mode
[  OK  ] Reached target multi-user.target - Multi-User System.

root@localhost:/# cat /etc/os-release | head -2
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME="Debian GNU/Linux"
root@localhost:/# uname -r
6.12.63-android16-6-g8ee72b352c6a-ab14789739-4k
```

---

## The actual command (if you'd rather not use my script)

```bash
su
ulimit -l unlimited
/apex/com.android.virt/bin/crosvm --log-level warn run \
  --disable-sandbox --no-balloon \
  --protected-vm-without-firmware --swiotlb 64 \
  --serial type=stdout,hardware=serial,num=1,console=true,stdin=true,earlycon=true \
  --params 'root=/dev/vda rw console=ttyS0 8250.nr_uarts=4 systemd.debug_shell=ttyS0 systemd.mask=serial-getty@ttyS0.service' \
  --mem 2048 --cpus 2 \
  --rwdisk /data/local/tmp/linuxvm/root_part \
  /data/local/tmp/linuxvm/vmlinuz
```

**Four things in there are load-bearing. Remove any one and it breaks differently:**

| Flag / param | Remove it and you get |
|---|---|
| `--protected-vm-without-firmware` | Firmware refuses the VM (`Failed to start VM: -19`) |
| `ulimit -l unlimited` | `Out of memory (os error 12)`, `Failed to allocate parcel for DTB: -12` |
| `8250.nr_uarts=4` | `/dev/ttyS0` never appears → `Failed to set up standard input` |
| `systemd.mask=serial-getty@ttyS0.service` | getty fights the debug shell over the tty |

And one thing that isn't a flag but matters more than any of them — **defragment host memory
before launching**:

```bash
sync; echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory
```

plus crosvm's `--hugepages`. Skip it and you get `unknown gh exit reason: 3` at the end of
boot roughly every time; my measured rate was **0/5 without it, 5/5 with it**. A protected VM
needs large contiguous host pages and a phone that's been up for hours has none
(`/proc/buddyinfo` shows zeros from order 6 up). `linuxvm` does this for you.

---

## Why the official Linux Terminal can't work on Snapdragon

Worth understanding, because the error message is misleading and the "fix" the app suggests
(wipe and retry) just makes you re-download several GB.

There are three layers:

**Layer 1 — Android framework gate.** The visible crash:

```
java.lang.UnsupportedOperationException: Non-protected VMs are not supported on this device.
    at VirtualMachineConfig$Builder.setProtectedVm(VirtualMachineConfig.java:1322)
```

This only reads the sysprop `ro.boot.hypervisor.vm.supported`. With root you can set it and
the crash disappears — the app really does go on to launch a VM.

**Layer 2 — crosvm/Gunyah IRQ collision.** With the app's full device set:

```
failed to register irq fd: File exists (os error 17)
```

Gunyah rejects two irqfds on one GSI where KVM allows it. Fewer devices, no problem.

**Layer 3 — TrustZone. This one is final.**

```
gunyah_rsc_mgr: RM rejected message 56000004. Error: 2
misc gunyah:    Failed to start VM: -19
```

`0x56000004` is the Gunyah Resource Manager's `VM_START` RPC; `Error: 2` is `NORESOURCE`.
Every preceding ioctl — create VM, map memory, add vCPU, set DTB, set boot context —
succeeds. Only the start is refused, by signed firmware. Root cannot reach it.

**But protected VMs work.** Control experiment:

```
$ vm run-microdroid --protected --debug full
payload is ready
[   89.89] reboot: Power down
```

Boots, runs, powers off, zero errors. So the whole stack is healthy — the firmware simply
doesn't provision *unprotected* VMs. Qualcomm said in Oct 2025 they'd add support "if there's
market demand."

That's the insight this guide is built on: **use the door that's open.**

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Out of memory (os error 12)` | You forgot `ulimit -l unlimited` (kernel caps locked memory at 64 KB) |
| `Failed to start VM: -19` | You're on the non-protected path — add `--protected-vm-without-firmware` |
| `Failed to verify the payload: Invalid metadata` | pvmfw is checking AVB. Use `--protected-vm-**without**-firmware`, not `--with-` |
| `Label u:object_r:privapp_data_file:s0 is not allowed` | Kernel file is in an app's private dir. Move it to `/data/local/tmp` |
| `debug-shell.service: Failed to set up standard input` | Missing `8250.nr_uarts=4` — no `/dev/ttyS0` exists |
| `unknown gh exit reason: 3` + `vcpu hit unknown error` | getty vs debug-shell fighting over ttyS0. Add `systemd.mask=serial-getty@ttyS0.service`. **This is not a memory problem** even though it looks like one |
| `Attempted to kill init! exitcode=0x00000000` | You used `init=/bin/sh`; the kernel can't open a console. Boot normally with `systemd.debug_shell=ttyS0` instead |
| VM dies when you switch apps | Samsung background management. Keep Termux foregrounded / exempt it from battery optimisation |

---

## Things that DON'T work (so you don't repeat them)

- **Enabling non-protected VMs by any means.** The refusal is in signed TrustZone firmware.
  Tested and ruled out: memory size (256–2048 MiB all identical), vCPU count, device count,
  a six-months-newer disk image, and a third-party crosvm build.
- **`libpenguin.so: dlopen failed`** — pure red herring. It comes from `BufferQueueProducer`
  (graphics), the Settings app throws the identical error, and the string doesn't appear in
  `VmTerminalApp.apk` at all.
- **`adb pair` from Termux.** Broken: `Handshake failed in SSL_accept/SSL_connect
  [invalid library (0)]`. adbwifi pairing needs BoringSSL; Termux's android-tools is built
  against OpenSSL. Every port fails the same way. Use **Shizuku** + `rish` instead.
- **Loop-mounting `root_part` on Android** to edit the rootfs — `I/O error ... unable to read
  superblock` on a large sparse file on f2fs. Use kernel params (`systemd.mask=` etc.) instead.
- **`idle=poll`** to stop the crash — doesn't help; the crash was the getty conflict.
- **Unlocking the bootloader on a US Samsung.** `sys.oem_unlock_allowed` is empty, there is
  no toggle, and changing CSC with smfwtool doesn't help — hypervisor capability is compiled
  into firmware, not a regional config.
- **`/dev/kvm`** — `CONFIG_KVM=y` but Gunyah owns EL2, so KVM never initialises. Gunyah only.

Full details with raw logs in the repo's `docs/dead-ends.md`.

---

## Known limitations

- Root is temporary; a reboot ends the party until you re-root.
- `--mem 2048 --cpus 2` is the verified-stable config **when combined with the memory
  compaction above**. 4096 MiB still crashes even with compaction (2/2 here), so 2048 is the
  current ceiling. The guide author runs 4096/4 on a Y700, so this may be device/firmware
  dependent — try it and report back.
- Serial console only. Networking needs a tap device; display needs virtio-gpu plumbing.
  Both are crosvm work, not firmware restrictions.
- `--rwdisk` writes to the image. Back up `root_part` if you want a pristine copy.

---

## Credits

- **@polygraphene** — [gunyah-on-sd-guide](https://github.com/polygraphene/gunyah-on-sd-guide),
  which demonstrated `--protected-vm-without-firmware` + `ulimit -l unlimited` on Snapdragon
  8 Elite. That repo is why I looked at the protected path at all.
- Google's AVF/ferrochrome team — the image and crosvm both ship in `com.android.virt`.

Repo (scripts, full write-up, dead ends with logs):
**https://github.com/roobtx/s25u-native-linux**

---

## Changelog

- **v1.0** — Initial release. Debian 13 boots, root shell on serial, 125 s soak with zero
  crashes.

---

*If you get networking or a display working, please post — I'd like to fold it in.*
