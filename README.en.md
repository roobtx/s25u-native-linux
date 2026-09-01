# Native Linux on the Galaxy S25 Ultra

*[中文版 / Chinese version](README.md)*

Debian 13 (trixie) running as a **real virtual machine** — its own kernel, its own systemd,
a root shell — on a **carrier-locked Galaxy S25 Ultra (SM-S938U, Snapdragon 8 Elite)** whose
bootloader can never be unlocked. Not a chroot. Not proot.

![Debian 13 booting on a Galaxy S25 Ultra](screenshots/debian-boot.jpg)

*Debian 13 finishing boot on an SM-S938U — systemd all green, `multi-user.target` reached, root shell at the bottom.*

```
linuxvm: booting Debian 13  (2048 MiB, 2 vCPU) — 'poweroff' to exit
...
root@localhost:/# cat /etc/os-release | head -2
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME="Debian GNU/Linux"
root@localhost:/# uname -r
6.12.63-android16-6-g8ee72b352c6a-ab14789739-4k
```

> **The idea in one sentence:** Android's built-in "Linux Terminal" asks for a
> **non-protected** VM, which this device's TrustZone firmware refuses outright. But the
> **protected** VM path *is* provisioned — so `crosvm --protected-vm-without-firmware` takes
> that path while skipping pvmfw's signature check, and any kernel boots.

---

## Contents

- [Environment and prerequisites](#environment-and-prerequisites)
- [Quick start](#quick-start)
- [The four load-bearing flags](#the-four-load-bearing-flags)
- [Why the stock Linux Terminal can never work here](#why-the-stock-linux-terminal-can-never-work-here)
- [Dead ends, with evidence](docs/dead-ends.en.md)
- [Raw logs](docs/evidence.en.md)
- [Known limitations](#known-limitations)
- [Credits](#credits)

---

## Compatibility: this is not Samsung-specific

Nothing here is device-specific — what matters is **the hypervisor baked into the SoC**. The
disk image is generic (`ferrochrome/aarch64/...`, no device name anywhere) and the Terminal
app ships in a mainline APEX, identical on every phone.

| SoC | Status |
|---|---|
| **Snapdragon 8 Elite** | ✅ This method applies. Confirmed on: Galaxy S25 Ultra (this repo), Lenovo Legion Y700 gen4 ([original guide](https://github.com/polygraphene/gunyah-on-sd-guide)), OnePlus 13T (same errors reported). **The Xiaomi 15 series uses the same chip — those phones ship the stock Terminal app too, and it doesn't work for them either** ([appendix](docs/dead-ends.en.md)). |
| Snapdragon 8 Gen 2 / Gen 3 | ⚠️ `--protected-vm-without-firmware` does not work there; you need the pvmfw route — see [PVMFW.md](https://github.com/polygraphene/gunyah-on-sd-guide/blob/main/PVMFW.md) |
| Dimensity 9400+ / Exynos / Pixel (Tensor) | You don't need any of this — those are KVM/pKVM, where the stock Terminal app just works |

**Devices with an unlockable bootloader (Xiaomi and friends) have it easier than this one:**
they can run Magisk/KernelSU for *permanent* root, whereas a US Samsung is limited to
temporary root that dies on reboot.

Three requirements: a Snapdragon 8 Elite, root, and `/dev/gunyah` plus the
`com.android.virt` APEX (present on Android 15/16).

---

## Environment and prerequisites

Verified in September 2026 on:

| | |
|---|---|
| Device | SM-S938U (Galaxy S25 Ultra, US model) |
| SoC | Snapdragon 8 Elite |
| ROM | Android 16 / One UI 8.0, January 2026 security patch |
| Bootloader | **Locked** (`ro.boot.flash.locked=1`, no OEM-unlock toggle at all) |
| Root | KernelSU 3.2.5 (temporary root, SELinux domain `u:r:ksu:s0`) |
| Hypervisor | Gunyah (`/sys/hypervisor/type` = `gunyah`, api 1 / variant 81) |
| Shell | Termux |

**Root is mandatory.** US Samsung models have a permanently locked bootloader — there isn't
even an OEM-unlock switch — so you need a temporary/exploit-based root (KernelSU, APatch,
etc.). **When root goes away on reboot, so does this.**

You do *not* need to unlock the bootloader, flash any partition, or disable SELinux
(it stays **Enforcing** throughout).

---

## Quick start

### 1. Get the disk image

The image is Google's ferrochrome build — the same one the stock Linux Terminal app
downloads (~525 MB download, a few GB unpacked).

**Option A — let the Terminal app fetch it** (recommended; it pulls the newest build).

The app **cannot boot a VM** on this SoC, but its downloader works perfectly:

```bash
# Samsung removed the developer-options toggle in the One UI 8 release build,
# so enable the package manually:
su -c 'pm enable com.android.virtualization.terminal'
su -c 'settings put global linux_terminal_available 1'
su -c 'am start -n com.android.virtualization.terminal/.MainActivity'
# Tap "Install" on the phone and wait for the download to finish.
```

The image lands in `/data/user/0/com.android.virtualization.terminal/files/linux/`.

**Option B — download it yourself**

```bash
curl -LO https://dl.google.com/android/ferrochrome/3500000/aarch64/images.tar.gz
tar xf images.tar.gz     # yields root_part, vmlinuz, ...
```

### 2. Install

```bash
git clone https://github.com/roobtx/s25u-native-linux
cd s25u-native-linux
bash setup.sh
```

`setup.sh` copies the image to `/data/local/tmp/linuxvm` (preserving sparseness — about
1.6 GB actual) and installs the `linuxvm` launcher.

### 3. Boot

```bash
linuxvm
```

You land straight at a root shell. Type `poweroff` inside the VM to shut down cleanly.

```bash
LINUXVM_MEM=2048 LINUXVM_CPUS=2 linuxvm    # tunable — but see Known limitations
```

---

## The four load-bearing flags

These four make the whole thing work. Remove any one and it fails in a completely different
way. **Each one cost me time to find.**

### 1. `--protected-vm-without-firmware`

**This is the key.** It takes the protected-VM path (the one the firmware actually
provisions) while skipping pvmfw's AVB verification entirely.

Leave it out → you get a non-protected VM → TrustZone refuses it (see [dead ends](docs/dead-ends.en.md)).
Use `--protected-vm-with-firmware` instead → pvmfw loads and demands an AVB-signed kernel,
which Debian's isn't → `Failed to verify the payload: Invalid metadata`.

### 2. `ulimit -l unlimited`

The kernel's `account_locked_vm` caps locked memory at 64 KB by default, and crosvm needs to
pin the entire guest.

Without it:
```
failed to initialize virtual machine Out of memory (os error 12)
dmesg: Failed to allocate parcel for DTB: -12
```

### 3. `8250.nr_uarts=4` (kernel param)

The ferrochrome kernel **doesn't instantiate `/dev/ttyS*` nodes** by default
(`CONFIG_SERIAL_8250_RUNTIME_UARTS=0`). Kernel printk still reaches your terminal, so
everything *looks* healthy — but userspace can't open the console:

```
debug-shell.service: Failed to set up standard input: No such file or directory
debug-shell.service: Failed at step STDIN spawning /usr/bin/bash: No such file or directory
```

### 4. `systemd.mask=serial-getty@ttyS0.service` (kernel param)

**This is what makes it stable, and it's the thing that stumped me longest.**

Without it, `serial-getty` and `systemd.debug_shell` both grab ttyS0. The log fills with
terminal-size probes (`[6n`, `[32766;32766H`) and then crosvm dies:

```
WARN  hypervisor::gunyah] unknown gh exit reason: 3
ERROR crosvm::sys::linux::vcpu] vcpu hit unknown error: Invalid argument (os error 22)
```

`gh exit reason 3` is `GUNYAH_VCPU_EXIT_PAGE_FAULT`, an exit crosvm's Gunyah backend doesn't
implement.

**This crash is deeply misleading** — it looks exactly like running out of memory. Masking
the getty helps a lot, but **it is not the whole story**. See item 5.

### 5. Defragment host memory before booting (the most important one, and the least obvious)

**Without this the failure rate is close to 100%.** I originally shipped only the first four
items, got one 125-second crash-free run, and called it stable. Repeating the test gave
**0 out of 5**.

The real cause is **host memory fragmentation**. A protected VM needs large contiguous
physical pages, and after a phone has been up for hours the high-order blocks are gone:

```
before /proc/buddyinfo:  45304 29391 13255  2394   219    45     0    0   0  0   0
                                                                 ^ nothing at order 6+
after:                   80388 41397 20945  9304  2924  1738   694  273  61  0  74
```

So before launching:

```bash
sync
echo 3 > /proc/sys/vm/drop_caches
echo 1 > /proc/sys/vm/compact_memory
```

plus crosvm's `--hugepages`. With this step: **0/5 → 5/5**, including the run with a NIC
attached. `linuxvm` does it for you.

> This is almost certainly why someone on a OnePlus 13T (also Snapdragon 8 Elite) hit the
> identical error and
> [gave up](https://github.com/lfdevs/run-linux-on-android-guide/discussions/1) — they
> suspected memory too, but never tried compaction.

---

## Why the stock Linux Terminal can never work here

On this device AVF is three nested walls:

| Layer | Symptom | Can root fix it? |
|---|---|---|
| ① Android framework gate | `UnsupportedOperationException: Non-protected VMs are not supported on this device` | ✅ Yes (`resetprop ro.boot.hypervisor.vm.supported true`) |
| ② crosvm IRQ registration | `failed to register irq fd: File exists` | ⚠️ Yes, by using fewer devices |
| ③ TrustZone firmware | `RM rejected message 56000004. Error: 2` → `Failed to start VM: -19` | ❌ **No** |

Layer ③ is signed TrustZone firmware making the call: `0x56000004` is the Gunyah Resource
Manager's `VM_START` RPC and `Error: 2` is `GUNYAH_RM_ERROR_NORESOURCE`. **This device's
firmware does not provision non-protected VMs.**

The Terminal app hardcodes `"protected": false`, so it always hits layer ③.

**But protected VMs work perfectly.** The control experiment:
`vm run-microdroid --protected` boots completely, runs its payload and powers off cleanly,
with zero Gunyah errors. The entire crosvm / Gunyah driver / TrustZone RM chain is healthy.

Which points at the answer: **take the protected path, but don't let pvmfw inspect the payload.**

---

## Known limitations

- **Root is a prerequisite** and it dies on reboot. Re-root to use this again.
- **`--mem 2048 --cpus 2` is the verified-stable configuration**, provided you do the memory
  compaction from item 5. 4096 MiB still crashes even with compaction (2/2 failed here), so
  2048 is the current ceiling. The author of the
  [original guide](https://github.com/polygraphene/gunyah-on-sd-guide) runs 4096/4 on a
  Lenovo Y700 gen4, so this may be device- or firmware-dependent.
- **Serial console only.** No networking, no display. Networking needs a tap device (AVF uses
  `vmnic`); a display needs virtio-gpu plumbing. Both are crosvm work, not firmware
  restrictions.
- **Samsung's background management** may freeze the process when you switch away from
  Termux. Keep Termux in the foreground, or exempt it from battery optimisation. (Note: the
  crashes described above were **not** Android's low-memory killer — there are zero `lmkd`
  entries in logcat. See dead ends.)
- **`--rwdisk` writes to the image.** Back up `root_part` first if you want a pristine copy.

---

## Repository layout

| File | Purpose |
|---|---|
| `linuxvm` | The launcher; installs to `~/.local/bin/` |
| `setup.sh` | Prepares the image and installs the launcher |
| `docs/dead-ends.en.md` | **Everything that doesn't work**, with full error output |
| `docs/evidence.en.md` | Raw logs, strace output, platform info |
| `posts/hackaday.md` | Hackaday.io-style project write-up |
| `posts/xda.md` | XDA-forum-style guide |

---

## Credits

- [polygraphene/gunyah-on-sd-guide](https://github.com/polygraphene/gunyah-on-sd-guide) —
  demonstrated `--protected-vm-without-firmware` plus `ulimit -l unlimited` on Snapdragon
  8 Elite. I would not have thought to try the protected path without that repo.
- Google's AVF / ferrochrome team — both the image and crosvm ship inside the
  `com.android.virt` APEX.

## License

MIT for the scripts and documentation. The disk image and crosvm belong to their respective
owners; this repository does not redistribute them.
