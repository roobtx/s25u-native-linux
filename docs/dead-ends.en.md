# Dead ends, with evidence

*[中文版 / Chinese version](dead-ends.md)*

Everything I tried on the SM-S938U that **didn't** work, and the exact reason each one
failed. The point of this document is so you don't have to repeat any of it. Raw error text
is included throughout so it's searchable.

Ordered by *how convincingly wrong it is* — the most misleading traps first.

---

## 1. ❌ The stock "Linux Terminal" app (non-protected VM) — the genuine dead end

### What you see on screen

> **Unrecoverable error**
> Failed to recover from an error. You may try restarting the terminal, or try one of the
> recovery options. If everything fails, wipe all data by toggling Linux terminal in
> Developer options.
>
> Error code:
> ```
> java.lang.UnsupportedOperationException: Non-protected VMs are not supported on this device.
>     at android.system.virtualmachine.VirtualMachineConfig$Builder.setProtectedVm(VirtualMachineConfig.java:1322)
>     at com.android.virtualization.terminal.ConfigJson.toConfigBuilder(ConfigJson.kt:88)
>     at com.android.virtualization.terminal.VmLauncherService.doStart(VmLauncherService.kt:208)
> ```

⚠️ The advice in that dialog — "wipe all data by toggling Linux terminal in Developer
options" — **is useless here**: the One UI 8 release build removed that toggle. Worse, if you
do trigger a wipe you'll delete several GB of image and have to download it again. **Don't sit
there hammering the "Recover" button.**

### This layer *is* bypassable

That exception does nothing but read a system property,
`ro.boot.hypervisor.vm.supported`. With root:

```bash
/data/adb/ksu/bin/resetprop ro.boot.hypervisor.vm.supported true
```

The crash disappears immediately, and `vm info` changes its mind:

```
$ vm info
Both protected and non-protected VMs are supported.
```

The app then genuinely proceeds to launch a VM — virtmgr, virtualizationservice and crosvm
all start:

```
virtmgr : Non-protected virtual machine "debian" (owner: u0_a494, cid: 2048) created
virtmgr : Non-protected virtual machine "debian" (owner: u0_a494, cid: 2048) started
crosvm  : creating hypervisor: Gunyah { device: Some("/dev/gunyah") }
```

### And then TrustZone stops you

Trim the device list so you get past the IRQ collision, and you arrive here:

```
$ dmesg
gunyah_rsc_mgr hypervisor:qcom,resource-manager-rpc@...: RM rejected message 56000004. Error: 2
misc gunyah: Failed to start VM: -19
```

- `0x56000004` = the Gunyah Resource Manager's **`VM_START`** RPC
- `Error: 2` = **`GUNYAH_RM_ERROR_NORESOURCE`** (note: not DENIED, not UNIMPLEMENTED)
- the driver maps it to `-ENODEV` (19), which surfaces in crosvm as
  `failed to initialize virtual machine No such device (os error 19)`

**The full ioctl sequence, from strace** — proving every piece of configuration is accepted
and only the *start* is refused:

```
ioctl(7, _IOC(_IOC_NONE,  0x47, 0x0, 0))     = 9   GUNYAH_CREATE_VM         → ok
ioctl(9, _IOC(_IOC_WRITE, 0x47, 0x1, 0x20))  = 0   SET_USER_MEM_REGION      → ok
ioctl(9, _IOC(_IOC_WRITE, 0x47, 0x4, 0x10))  = 3   ADD_FUNCTION (vCPU)      → ok
ioctl(9, _IOC(_IOC_WRITE, 0x47, 0x2, 0x10))  = 0   SET_DTB_CONFIG           → ok
ioctl(9, _IOC(_IOC_WRITE, 0x47, 0xa, 0x10))  = 0   SET_BOOT_CONTEXT         → ok
ioctl(9, GSMIOC_DISABLE_NET, 0)              = -1 ENODEV   ← actually GUNYAH_VM_START
```

> 🪤 **strace will lie to you here.** It renders `_IO('G', 3)` = `0x4703` as
> `GSMIOC_DISABLE_NET`, a tty ioctl. Gunyah's `GUNYAH_VM_START` is *also* `_IO('G', 0x3)`.
> Same number, entirely different subsystem. Don't go hunting for a serial-driver bug.

### Conclusion

**Unfixable.** The refusal comes from signed TrustZone firmware; root cannot reach that
layer. Consistent with Qualcomm's public statement (October 2025) that unprotected VM support
would come "if there is market demand."

### Things I ruled out along the way

| Theory | How I tested it | Result |
|---|---|---|
| Not enough memory | 256 / 512 / 1024 / 2048 MiB | **Identical** failure at all four |
| Too many devices | `one_cpu`, no GPU/network/shared dirs | Still refused at VM_START |
| Corrupt or stale image | Re-downloaded a build six months newer | Same failure |
| The VM stack is broken | `vm run-microdroid --protected` | **Booted completely** — see below |

---

## 2. ✅ Control experiment: protected VMs are fine (this is the breakthrough)

```bash
vm run-microdroid --protected --debug full
```

```
microdroid_manager: payload pid = 86
payload is ready
vm_payload: Notified host payload ready successfully
[   89.757350][    T1] init: ####Reboot start, reason: shutdown
[   89.893508][    T1] reboot: Power down
```

Full boot, payload executed, clean shutdown, and `dmesg` shows zero Gunyah errors.

**So crosvm, the Gunyah driver and the TrustZone RM are all healthy — only the *unprotected*
VM type is refused.** That inverts the problem: stop trying to open the locked door, work out
how to get Debian through the open one.

---

## 3. ❌ Protected VM + pvmfw + a stock Debian kernel

With `"protected": true` and pvmfw in the picture, pvmfw genuinely **runs** — and then
rejects an unsigned kernel:

```
[INFO]  pvmfw config version: 1.0
[INFO]  pVM firmware
[ERROR] avb_footer.c: Footer magic is incorrect.
[ERROR] avb_vbmeta_image.c: Magic is incorrect.
[ERROR] avb_slot_verify.c: Error verifying vbmeta image: invalid vbmeta header
[ERROR] Failed to verify the payload: Invalid metadata
```

The trusted public key lives in signed firmware, so **self-signing gets you nowhere.**

👉 The answer is `--protected-vm-without-firmware`: protected VM path, pvmfw never loaded,
nothing to verify.

### Side trap: kernel files can't live in an app's private directory

```
Error: Failed to create VM
Caused by: '-1: kernel file invalid
  Caused by: Label u:object_r:privapp_data_file:s0:c238,... is not allowed'
```

virtualizationservice enforces an SELinux label allowlist on the kernel file. Move it to
`/data/local/tmp/` (`shell_data_file`) and it's happy.

---

## 4. ❌ The missing `libpenguin.so` — a red herring, don't chase it

logcat shows:

```
E BufferQueueProducer: Unable to open libpenguin.so: dlopen failed: library "libpenguin.so" not found.
E zation.terminal: Unable to open libpenguin.so: dlopen failed: library "libpenguin.so" not found.
```

The library genuinely doesn't exist anywhere on the device, which makes it look exactly like
a missing-file failure. **It has nothing to do with the VM:**

- the error originates in `BufferQueueProducer` — the graphics stack, not virtualization
- **the Settings app produces the identical error.** Launch any app and check
- the string `penguin` appears **zero** times in `VmTerminalApp.apk`

It's an optional Samsung graphics library that every drawing app probes for. Harmless.

---

## 5. ⚠️ The image changed a lot between builds (but neither version helps)

After the app re-downloaded, the image was a different generation entirely:

| | old `hourly-1825` (2025-07-14) | new `hourly-6572` (2026-01-28) |
|---|---|---|
| vmlinuz | 13 MB | **43 MB** |
| initrd.img | 1 MB | **36 MB** |
| root_part | 467 GB sparse | 3.1 GB |
| cidata.iso | absent | **present** (cloud-init) |
| kernel_extras_part | present | absent |
| kernel params | basic | adds `arm64.nompam 8250.nr_uarts=4` |

The newer image is clearly better (it's the one this guide uses), but **it does not make a
non-protected VM start** — tested, same refusal.

---

## 6. ❌ `adb pair` from Termux (to enable the app)

`adb` in Termux — and in a proot Alpine — **cannot do wireless pairing**:

```
$ adb pair 192.168.1.70:38501 <code>
error: protocol fault (couldn't read status message): Success

# from the adb server log:
tls_connection.cpp: [client]: Handshake failed in SSL_accept/SSL_connect [invalid library (0)]
pairing_connection.cpp: Failed to handshake with the peer fd=11
```

adbwifi pairing requires BoringSSL; Termux's android-tools is built against OpenSSL.
**Every port fails this way — it isn't you.**

👉 Use **Shizuku** (which has a working pairing implementation) and its exported `rish`:

```bash
RISH_APPLICATION_ID=com.termux bash ~/.rish/rish -c 'pm enable com.android.virtualization.terminal'
```

⚠️ Apps that declare `sharedUserId` — Termux:API, and Shizuku's companion pieces — **must be
signed with the same key as your Termux build** (F-Droid Termux → F-Droid Termux:API).
Android flatly refuses the install otherwise.

---

## 7. ❌ Loop-mounting `root_part` on Android to edit the rootfs

```
$ losetup /dev/block/loop54 root_part && mount -t ext4 /dev/block/loop54 /mnt/vmroot
mount: '/dev/block/loop54'->'/mnt/vmroot': I/O error

$ dmesg
I/O error, dev loop54, sector 0 op 0x0:(READ)
EXT4-fs (loop54): unable to read superblock
```

The file itself is fine — `dd` reads it, and the ext4 magic `53 ef` is present at offset
0x438. The loop device just can't handle a large sparse file on f2fs.

👉 Modify the rootfs from inside the VM, or sidestep it entirely with kernel parameters
(`systemd.mask=` and friends), which is what this guide does.

---

## 8. ❌ `init=/bin/sh` for single-user mode

```
[    0.692318][    T1] Warning: unable to open an initial console.
[    0.757011][    T1] Run /bin/sh as init process
[    0.765174][    T1] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000000
```

The kernel can't open `/dev/console` — **the root cause is the missing `8250.nr_uarts=4`** —
so `/bin/sh` gets no stdin, reads EOF immediately, exits, and taking init down panics the
kernel.

👉 Boot systemd normally with `systemd.debug_shell=ttyS0`; systemd sets the console up properly.

---

## 9. ❌ `idle=poll` to stop the crash

I assumed the crash came from the guest entering WFI idle and added `idle=poll`.
**No help — it actually crashed sooner.**

The real cause was getty fighting the debug shell over ttyS0. See the main README.

---

## 10. ❌ "Is Android's low-memory killer doing this?"

A reasonable suspicion on a Samsung device, but **the evidence says no**:

- grepping logcat for `lowmemorykiller|lmkd|kill.*crosvm` → **zero hits**
- the crash is crosvm's own vCPU thread reporting an internal error
  (`vcpu hit unknown error: Invalid argument (os error 22)`), not a signal
- it reproduces **deterministically** at the same boot stage (just after `graphical.target`),
  which is not how OOM killing behaves
- after fixing the getty conflict, the same memory footprint ran 125 seconds with zero crashes

---

## 11. ❌ Third-party crosvm builds (not needed)

[gunyah-on-sd-guide](https://github.com/polygraphene/gunyah-on-sd-guide) v0.0.2 ships
`crosvm-a16` plus `libbinder.so` / `libbinder_ndk.so`. I downloaded and tested it:

**it crashes identically while the getty conflict is unresolved.** Once that's fixed, the
stock `/apex/com.android.virt/bin/crosvm` is entirely sufficient. No third-party binary needed.

---

## 12. ❌ Unlocking the bootloader / getting permanent root (US models)

```
ro.product.model        = SM-S938U
ro.boot.flash.locked    = 1
ro.boot.carrierid       = XAA
sys.oem_unlock_allowed  = (empty)
ro.oem_unlock_supported = (empty)
```

US Samsung devices (U / U1) have a **permanently locked bootloader** — the "OEM unlocking"
entry never even appears in developer options. No modified boot image can be flashed, so the
normal Magisk/KernelSU install paths are out; temporary root is the only option.

Tools like `smfwtool` **don't help either**: changing CSC / region only alters customisation
config. Hypervisor capability is compiled into the firmware binaries, which every CSC of a
given model shares. Cross-flashing another model (e.g. the international SM-S938B) is
rejected by a locked bootloader.

---

## 13. ℹ️ Why there's no `/dev/kvm` on this device

```
$ zcat /proc/config.gz | grep -E '^CONFIG_(KVM|GUNYAH)'
CONFIG_KVM=y
CONFIG_GUNYAH=y
$ ls /dev/kvm
ls: /dev/kvm: No such file or directory
$ cat /sys/hypervisor/type
gunyah
```

KVM is compiled in, but **Gunyah occupies EL2**, so the kernel runs at EL1 and KVM can never
initialise. Gunyah is the only game in town here.
