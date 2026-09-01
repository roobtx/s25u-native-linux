# 关键日志证据（原文）

保留原始输出，方便搜索比对。所有内容采集自 SM-S938U / Android 16 / One UI 8.0 / 2026-09。

---

## A. 成功：Debian 13 启动并拿到 root shell

```
linuxvm: booting Debian 13  (2048 MiB, 2 vCPU) — 'poweroff' to exit
[    0.000000][    T0] Booting Linux on physical CPU 0x0000000000 [0x000f0480]
[    0.000000][    T0] Linux version 6.12.63-android16-6-g8ee72b352c6a-ab14789739-4k
[    0.000000][    T0] KASLR enabled
[    0.000000][    T0] Machine model: linux,dummy-virt
[    0.000000][    T0] psci: PSCIv1.1 detected in firmware.
...
[    0.783142][    T1] systemd[1]: systemd 257.9-1~deb13u1 running in system mode
[    1.336962][    T1] systemd[1]: Finished systemd-fsck-root.service - File System Check on Root Device.
[    1.425054][    T1] systemd[1]: Started systemd-journald.service - Journal Service.
[    1.563929][  T208] Adding 973308k swap on /dev/zram0.
[  OK  ] Reached target multi-user.target - Multi-User System.

root@localhost:/# cat /etc/os-release | head -2
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME="Debian GNU/Linux"
root@localhost:/# whoami
root
root@localhost:/# uname -r
6.12.63-android16-6-g8ee72b352c6a-ab14789739-4k
root@localhost:/# free -m
               total        used        free      shared  buff/cache   available
Mem:            1901         143        1710           0         114        1758
root@localhost:/# uptime
 17:46:01 up 1 min,  0 users,  load average: 0.00, 0.00, 0.00

[   27.143472][    T1] systemd-shutdown[1]: Powering off.
[   27.145134][    T1] reboot: Power down
```

125 秒稳定性测试：`exit=124`（跑满超时未崩溃），`grep -c "unknown gh exit"` = **0**。

---

## B. 非保护 VM 被 TrustZone 拒绝

```
$ dmesg
[46560.872182] gunyah_rsc_mgr hypervisor:qcom,resource-manager-rpc@d0ee3087b9dfac79: RM rejected message 56000004. Error: 2
[46560.872579] misc gunyah: Failed to start VM: -19
```

crosvm 侧：
```
[ERROR] crosvm] exiting with error 1: the architecture failed to build the vm
Caused by:
    failed to initialize virtual machine No such device (os error 19)
VM ended: StartFailed
```

对照 —— 设备较多时更早撞在中断注册：
```
[ERROR] crosvm] exiting with error 1: the architecture failed to build the vm
Caused by:
    failed to register irq fd: File exists (os error 17)
```

---

## C. strace 抓到的 Gunyah ioctl 全序列

```
26410 openat(AT_FDCWD, "/dev/gunyah", O_RDWR|O_CLOEXEC) = 7
26410 ioctl(7, _IOC(_IOC_NONE,  0x47, 0,    0),    0)            = 9
26410 ioctl(9, _IOC(_IOC_WRITE, 0x47, 0x1,  0x20), 0x7fc8636d38) = 0
26410 ioctl(9, _IOC(_IOC_WRITE, 0x47, 0x4,  0x10), 0x7fc86357d0) = 3
26410 ioctl(9, _IOC(_IOC_WRITE, 0x47, 0x2,  0x10), 0x7fc86357f0) = 0
26410 ioctl(9, _IOC(_IOC_WRITE, 0x47, 0xa,  0x10), 0x7fc86357f0) = 0
26410 ioctl(9, GSMIOC_DISABLE_NET, 0)                            = -1 ENODEV (No such device)
```

对应关系（`'G'` = 0x47）：

| ioctl | 含义 | 结果 |
|---|---|---|
| `_IO('G',0)` | `GUNYAH_CREATE_VM` | ok → VM fd 9 |
| `_IOW('G',1)` | `GUNYAH_VM_SET_USER_MEM_REGION` | ok |
| `_IOW('G',4)` | `GUNYAH_VM_ADD_FUNCTION`（vCPU） | ok |
| `_IOW('G',2)` | `GUNYAH_VM_SET_DTB_CONFIG` | ok |
| `_IOW('G',0xa)` | `GUNYAH_VM_SET_BOOT_CONTEXT` | ok |
| `_IO('G',3)` = 0x4703 | **`GUNYAH_VM_START`** | **ENODEV** |

> strace 把 `0x4703` 误标为 `GSMIOC_DISABLE_NET`，因为 tty 的这个 ioctl 数值相同。

---

## D. 受保护 microdroid VM 完整启动（对照组）

```
$ vm run-microdroid --protected --debug full
Created debuggable VM from EmptyPayloadApp.apk
09-01 17:08:35.332 microdroid_manager: payload pid = 86
payload is ready
09-01 17:08:35.344 vm_payload: Notified host payload ready successfully
[   89.757350][    T1] init: ####Reboot start, reason: shutdown
[   89.893207][    T1] init: Reboot ending, jumping to kernel
[   89.893508][    T1] reboot: Power down
```

`dmesg | grep gunyah` → 无输出（零错误）。

---

## E. pvmfw 拒绝未签名内核

```
[INFO]  pvmfw config version: 1.0
[INFO]  pVM firmware
[ERROR] avb_footer.c  : Footer magic is incorrect.
[ERROR] avb_vbmeta_image.c : Magic is incorrect.
[ERROR] avb_slot_verify.c  : Error verifying vbmeta image: invalid vbmeta header
[ERROR] Failed to verify the payload: Invalid metadata
```

---

## F. 缺 `8250.nr_uarts=4` 的表现

```
[    1.152763][    T1] systemd[1]: Expecting device dev-ttyS0.device - /dev/ttyS0...
[    1.186547][    T1] systemd[1]: Started debug-shell.service - Early root shell on /dev/ttyS0
[    1.130879][  T100] (bash)[100]: debug-shell.service: Failed to set up standard input: No such file or directory
[    1.132252][  T100] (bash)[100]: debug-shell.service: Failed at step STDIN spawning /usr/bin/bash: No such file or directory
[    1.191565][    T1] systemd[1]: debug-shell.service: Main process exited, code=exited, status=208/STDIN
```

加上之后：
```
[  OK  ] Found device dev-ttyS0.device - /dev/ttyS0.
[  OK  ] Started debug-shell.service - Early root shell on /dev/ttyS0 FOR DEBUGGING ONLY.
```

---

## G. getty 与 debug shell 抢串口导致的崩溃

```
[  OK  ] Reached target multi-user.target - Multi-User System.
[  OK  ] Reached target graphical.target - Graphical Interface.
[!p]104[?7h[6n[32766;32766H[6n[!p]104[?7h[6n[32766;32766H[6n[!p]104[?7h[6n...
[WARN ] hypervisor::gunyah] unknown gh exit reason: 3
[ERROR] crosvm::sys::linux::vcpu] vcpu hit unknown error: Invalid argument (os error 22)
[ERROR] crosvm::sys::linux::vcpu] failed to send VcpuControl: sending on a closed channel
```

`[6n` 是终端光标位置查询，`[32766;32766H` 是探测终端尺寸 —— 两个进程在同一个 tty 上反复协商。
`gh exit reason 3` = `GUNYAH_VCPU_EXIT_PAGE_FAULT`，crosvm 未实现处理。

加上 `systemd.mask=serial-getty@ttyS0.service` 后消失。

---

## H. 平台信息

```
$ getprop | grep -i hypervisor
[ro.boot.hypervisor.protected_vm.supported]: [true]
# 注意：ro.boot.hypervisor.vm.supported 不存在（这就是①层门禁的依据）

$ cat /sys/hypervisor/type
gunyah
$ cat /sys/hypervisor/version/api    → 1
$ cat /sys/hypervisor/version/variant → 81
$ cat /proc/device-tree/hypervisor/qcom,gunyah-vm/qcom,vmid → 3

$ ls /dev/gunyah /dev/kvm
crw-rw-rw- 1 root root u:object_r:vendor_gunyah_dev:s0 /dev/gunyah
ls: /dev/kvm: No such file or directory

$ ps -A | grep qcrosvm
5073 qcrosvm  /system_ext/bin/qcrosvm --disk=/product/vm-system/trustedvm/system.img,label=10,rw=false --vm=trustedvm
```

最后一条说明：**Gunyah 本身在这台机器上一直在跑 VM**（高通自己的 trustedvm），
只是它只认经过授权/签名的 VM。
