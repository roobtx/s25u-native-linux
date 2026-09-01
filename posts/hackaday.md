<!-- Hackaday.io 风格项目帖。发布时：Summary 填「Elevator pitch」，Details 填正文，
     后面的 Project Logs 分条发成日志。英文，因为 Hackaday 是英文社区。 -->

# Native Linux on a Locked-Bootloader Galaxy S25 Ultra

## Elevator pitch

*Android 16's built-in "Linux Terminal" is dead on arrival on every Snapdragon phone —
the firmware refuses the kind of VM it asks for. I got Debian 13 booting anyway, on a
carrier-locked S25 Ultra, by going through the door that **is** open and taking the lock
off from the inside.*

![Debian 13 booting on a Galaxy S25 Ultra](https://raw.githubusercontent.com/roobtx/s25u-native-linux/main/screenshots/debian-boot.jpg)

*Debian 13 finishing boot on a carrier-locked SM-S938U — systemd all green, `multi-user.target` reached, root shell at the bottom. Those are Termux's extra keys along the bottom: this is a phone.*

---

## Details

Google shipped a Linux Terminal app in Android 16. Tap it on a Pixel and you get Debian in
a real VM. Tap it on a Snapdragon 8 Elite phone and you get this:

```
java.lang.UnsupportedOperationException:
    Non-protected VMs are not supported on this device.
```

Samsung quietly removed the developer-options toggle for it in the One UI 8 release build.
Qualcomm's public position (Oct 2025) is that unprotected VM support will come "if there's
market demand." So: no toggle, no VM, no explanation.

I had a temporarily-rooted SM-S938U — a **US carrier model, bootloader permanently locked,
no OEM-unlock switch at all** — and decided to find out exactly where the wall is.

It turned out there are three walls, not one. Two of them are made of paper.

### Wall 1: a system property

The exception above comes from `VirtualMachineConfig$Builder.setProtectedVm(false)`, which
does nothing more than read a sysprop:

```bash
resetprop ro.boot.hypervisor.vm.supported true
```

Crash gone. `vm info` now cheerfully reports *"Both protected and non-protected VMs are
supported."* The app proceeds to actually launch a VM — virtmgr, virtualizationservice and
crosvm all spin up, crosvm opens `/dev/gunyah`, attaches disks, configures a device tree.

### Wall 2: an IRQ collision

With the app's full device set, crosvm dies at:

```
failed to register irq fd: File exists (os error 17)
```

Gunyah won't let two devices register an irqfd on the same GSI; KVM will. Trim the device
list and you sail past it.

### Wall 3: the one that's real

Strip it down to a minimal VM and every single Gunyah ioctl succeeds — create VM, map
memory, add vCPU, set the DTB, set the boot context — and then:

```
gunyah_rsc_mgr: RM rejected message 56000004. Error: 2
misc gunyah:    Failed to start VM: -19
```

`0x56000004` is the Resource Manager's `VM_START` RPC. `Error: 2` is `NORESOURCE`. That
rejection comes from **signed TrustZone firmware**. Root gets you to the doorstep and no
further.

I wrote this up as "impossible" and moved on. That was wrong.

### The control experiment that changed everything

Before declaring defeat I ran the obvious control: does *any* VM work?

```bash
$ vm run-microdroid --protected --debug full
payload is ready
[   89.89] reboot: Power down
```

A full Linux kernel booted, ran its payload and shut down cleanly, with zero Gunyah errors.

So the hypervisor works. The driver works. crosvm works. The firmware provisions VMs
happily — **as long as they're the protected kind.**

Which reframes the whole problem. The question isn't "how do I make an unprotected VM
start?" It's **"how do I put Debian inside a protected one?"**

### The lock on the protected door

Protected VMs are gated by `pvmfw`, the protected-VM firmware, which verifies the payload
with AVB. Point it at a stock Debian kernel and it says exactly what you'd expect:

```
[INFO]  pVM firmware
[ERROR] Footer magic is incorrect.
[ERROR] Error verifying vbmeta image: invalid vbmeta header
[ERROR] Failed to verify the payload: Invalid metadata
```

The trusted key lives in signed firmware. Self-signing is not an option.

But crosvm has a flag — and this is the whole trick —

```
--protected-vm-without-firmware
```

**Protected VM path. No pvmfw. No AVB check.** The firmware provisions the VM because it's
the type it likes; nobody checks the payload because pvmfw was never loaded.

```
[    0.000000] Booting Linux on physical CPU 0x0000000000
[    0.000000] Linux version 6.12.63-android16-6
[    0.783142] systemd[1]: systemd 257.9-1~deb13u1 running in system mode
root@localhost:/# cat /etc/os-release
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
```

Debian 13, own kernel, systemd, root shell. On a phone whose bootloader will never unlock.

### Three more things that will waste your afternoon

**`ulimit -l unlimited`.** The kernel caps locked memory at 64 KB by default and crosvm
needs to pin the entire guest. Without it: `Out of memory (os error 12)`.

**`8250.nr_uarts=4`.** The ferrochrome kernel doesn't instantiate `/dev/ttyS*` unless you
ask. Kernel printk still reaches your terminal, so everything *looks* fine — but userspace
can't open the console, and systemd's debug shell dies with
`Failed to set up standard input`.

**`systemd.mask=serial-getty@ttyS0.service`.** This one cost me the most time. Without it,
`serial-getty` and the debug shell fight over the same tty, the log fills with terminal
size probes (`[6n`, `[32766;32766H`), and then:

```
unknown gh exit reason: 3
vcpu hit unknown error: Invalid argument (os error 22)
```

`gh exit reason 3` is `GUNYAH_VCPU_EXIT_PAGE_FAULT` — an exit crosvm's Gunyah backend
doesn't implement. It looks *exactly* like memory exhaustion. I burned an hour bisecting
RAM sizes and vCPU counts, convinced I'd found a hypervisor memory ceiling. I hadn't. Mask
the getty and 2 GB runs for as long as you like.

### Where it stands

125-second soak test: zero crashes, shell responsive throughout, clean `poweroff`.

Serial console only so far — no networking, no GPU. Both are crosvm features that need
plumbing (a tap device, a display backend), not firmware permission, so they're work rather
than obstacles.

And the whole thing evaporates on reboot, because the root does. That's the price of a
locked bootloader.

Full write-up, scripts, and a long list of things that **don't** work:
**https://github.com/roobtx/s25u-native-linux**

Credit where it's due: [polygraphene/gunyah-on-sd-guide](https://github.com/polygraphene/gunyah-on-sd-guide)
demonstrated `--protected-vm-without-firmware` on Snapdragon 8 Elite. I would not have
thought to look at the protected path without it.

---

## Project Logs

### Log 1 — "Non-protected VMs are not supported on this device"

Fresh One UI 8.0 on an SM-S938U. No "Linux development environment" toggle anywhere in
developer options. `com.android.virtualization.terminal` exists but is disabled; enabling it
with `pm enable` makes it appear, and tapping it produces an unrecoverable-error screen with
a Java stack trace.

`ro.boot.hypervisor.protected_vm.supported` is `true`.
`ro.boot.hypervisor.vm.supported` doesn't exist at all. There's the gate.

### Log 2 — Root gets past the framework, not the firmware

`resetprop` the missing property and the app stops throwing. It launches a real VM. crosvm
runs. Then the Resource Manager in TrustZone rejects `VM_START` with `NORESOURCE`.

Ruled out, one at a time: memory size (256/512/1024/2048 MiB — identical failure), vCPU
count, device count, a stale disk image (re-downloaded a build six months newer — same),
and a missing `libpenguin.so` that turns out to be a graphics-stack red herring the Settings
app triggers too.

### Log 3 — strace, and an ioctl that lies about its name

Traced every ioctl crosvm issues to `/dev/gunyah`. Create, map memory, add vCPU, set DTB,
set boot context — all fine. The failure is the last call.

strace labels it `GSMIOC_DISABLE_NET`, which is nonsense for a hypervisor. Both that tty
ioctl and Gunyah's `GUNYAH_VM_START` are `_IO('G', 3)` = `0x4703`. Same number, different
universe. Worth knowing before you go hunting for a serial driver bug that isn't there.

### Log 4 — The control experiment

`vm run-microdroid --protected` boots completely and powers off cleanly. Everything below
the Android framework is healthy. Only the *unprotected* VM type is refused.

This is the moment the problem inverts: stop trying to unlock the closed door, start
figuring out how to get Debian through the open one.

### Log 5 — pvmfw says no, so don't invite it

`"protected": true` loads pvmfw, which runs and rejects the unsigned Debian kernel on AVB
grounds. Also worth noting: virtualizationservice refuses kernel files carrying an app's
private SELinux label — `Label u:object_r:privapp_data_file:s0 is not allowed`. Move them
to `/data/local/tmp`.

Then: `--protected-vm-without-firmware`. Protected VM, no firmware, no verification.
`Booting Linux on physical CPU 0x0000000000`.

### Log 6 — The crash that pretended to be a memory limit

Debian reaches `graphical.target` and then dies with `unknown gh exit reason: 3`. 2048 MB
with 2 vCPUs survived; 2048/4, 4096/2, 6144/2 and 8192/2 all died. Obvious conclusion:
hypervisor memory ceiling.

Obvious conclusion was wrong. The escape sequences immediately before every crash were
terminal-size probes — two processes negotiating on one tty. `serial-getty` versus
`systemd.debug_shell`. Mask the getty and the "memory ceiling" disappears.

Also checked, since it's the natural suspicion on Samsung: is Android's low-memory killer
doing this? No. Zero `lmkd` entries in logcat, and the crash is crosvm's own vCPU thread
returning an error, not a signal.

### Log 7 — Soak test

125 seconds, zero crashes, shell responsive at 95 s, `poweroff` shuts down cleanly.

```
root@localhost:/# uptime
 17:46:01 up 1 min,  0 users,  load average: 0.00, 0.00, 0.00
```

Next: networking, then a display.
