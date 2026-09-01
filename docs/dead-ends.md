# 走不通的路（附证据）

*[English version](dead-ends.en.md)*

这份文档记录了在 SM-S938U 上**试过但失败**的每一条路，以及失败的**确切原因**。
写它的目的是：让你不必重走一遍。每条都附了原始报错，方便你搜索比对。

按"最容易被误导"排序。

---

## 1. ❌ 官方「Linux 终端」应用（非保护 VM）—— 真正的死路

### 界面上看到的

> **不可恢复的错误**
> 未能从错误中恢复。您可以尝试重启终端，或尝试某一恢复选项。
> 如果所有尝试都失败，请通过在"开发者选项"中开启/关闭 Linux 终端来擦除所有数据。
>
> 错误代码：
> ```
> java.lang.UnsupportedOperationException: Non-protected VMs are not supported on this device.
>     at android.system.virtualmachine.VirtualMachineConfig$Builder.setProtectedVm(VirtualMachineConfig.java:1322)
>     at com.android.virtualization.terminal.ConfigJson.toConfigBuilder(ConfigJson.kt:88)
>     at com.android.virtualization.terminal.VmLauncherService.doStart(VmLauncherService.kt:208)
> ```

⚠️ 提示里那句「通过开发者选项开启/关闭 Linux 终端来擦除所有数据」**没用**：正式版 One UI 8
已经把那个开关移除了。而且真触发了会删掉几个 GB 的镜像，得重下。**别点「恢复」按钮反复试。**

### 这一层能绕过

那个异常只是在读一个系统属性 `ro.boot.hypervisor.vm.supported`。有 root 就能改：

```bash
/data/adb/ksu/bin/resetprop ro.boot.hypervisor.vm.supported true
```

改完崩溃立刻消失，`vm info` 也改口：

```
$ vm info
Both protected and non-protected VMs are supported.
```

应用会一路跑到真的去启动虚拟机 —— virtmgr、virtualizationservice、crosvm 全部起来：

```
virtmgr : Non-protected virtual machine "debian" (owner: u0_a494, cid: 2048) created
virtmgr : Non-protected virtual machine "debian" (owner: u0_a494, cid: 2048) started
crosvm  : creating hypervisor: Gunyah { device: Some("/dev/gunyah") }
```

### 但下一层挡住了：TrustZone

把设备减到最少、越过中间层之后，最终撞在这里：

```
$ dmesg
gunyah_rsc_mgr hypervisor:qcom,resource-manager-rpc@...: RM rejected message 56000004. Error: 2
misc gunyah: Failed to start VM: -19
```

- `0x56000004` = Gunyah RM 的 **`VM_START`** RPC
- `Error: 2` = **`GUNYAH_RM_ERROR_NORESOURCE`**（不是 DENIED，也不是 UNIMPLEMENTED）
- 驱动把它映射成 `-ENODEV`（19），crosvm 侧表现为
  `failed to initialize virtual machine No such device (os error 19)`

**用 strace 逐个 ioctl 观测到的完整序列**（证明所有配置都被接受，只有"启动"被拒）：

```
ioctl(7, _IOC(_IOC_NONE,  0x47, 0x0, 0))     = 9   GUNYAH_CREATE_VM         → ok
ioctl(9, _IOC(_IOC_WRITE, 0x47, 0x1, 0x20))  = 0   SET_USER_MEM_REGION      → ok
ioctl(9, _IOC(_IOC_WRITE, 0x47, 0x4, 0x10))  = 3   ADD_FUNCTION (vCPU)      → ok
ioctl(9, _IOC(_IOC_WRITE, 0x47, 0x2, 0x10))  = 0   SET_DTB_CONFIG           → ok
ioctl(9, _IOC(_IOC_WRITE, 0x47, 0xa, 0x10))  = 0   SET_BOOT_CONTEXT         → ok
ioctl(9, GSMIOC_DISABLE_NET, 0)              = -1 ENODEV   ← 实为 GUNYAH_VM_START
```

> 🪤 **strace 的坑**：它把 `_IO('G', 3)` = `0x4703` 显示成 `GSMIOC_DISABLE_NET`（tty 的 ioctl）。
> Gunyah 的 `GUNYAH_VM_START` 也是 `_IO('G', 0x3)`，**数值撞了**。别被名字骗了。

### 结论

**这条路无解。** 拒绝方是签名的 TrustZone 固件，root 到不了那一层。
和高通 2025-10 的公开表态一致（非保护 VM「有市场需求才考虑支持」）。

### 已排除的干扰因素（都实测过）

| 猜测 | 测法 | 结果 |
|---|---|---|
| 内存不足 | 256 / 512 / 1024 / 2048 MiB | 四档**完全相同**的失败 |
| 设备太多 | `one_cpu` + 去掉 GPU/网络/共享目录 | 仍在 VM_START 被拒 |
| 镜像损坏/过期 | 重下全新官方镜像（新旧结构差异很大，见下） | 表现一致 |
| 整套 VM 机制坏了 | `vm run-microdroid --protected` | **完整启动成功**，见下 |

---

## 2. ✅ 对照实验：受保护 VM 是好的（这是突破口）

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

完整启动、运行负载、干净关机，`dmesg` 里零 Gunyah 错误。

**这证明 crosvm / Gunyah 驱动 / TrustZone RM 整条链路完全正常，唯独"非保护"这个类型被拒。**
→ 于是想到：走受保护通道，但绕开签名检查。

---

## 3. ❌ 受保护 VM + pvmfw + Debian 内核

`"protected": true` 配合 pvmfw 时，pvmfw **确实会启动**，然后拒绝没有 AVB 签名的内核：

```
[INFO]  pvmfw config version: 1.0
[INFO]  pVM firmware
[ERROR] avb_footer.c: Footer magic is incorrect.
[ERROR] avb_vbmeta_image.c: Magic is incorrect.
[ERROR] avb_slot_verify.c: Error verifying vbmeta image: invalid vbmeta header
[ERROR] Failed to verify the payload: Invalid metadata
```

验证用的公钥固化在设备的签名固件里，**自签无效**。

👉 解法就是 `--protected-vm-without-firmware`：走受保护通道但根本不加载 pvmfw。

### 顺带一个坑：内核文件不能放在应用私有目录

```
Error: Failed to create VM
Caused by: '-1: kernel file invalid
  Caused by: Label u:object_r:privapp_data_file:s0:c238,... is not allowed'
```

virtualizationservice 对内核文件的 SELinux 标签有白名单。放到 `/data/local/tmp/`
（`shell_data_file`）即可。

---

## 4. ❌ `libpenguin.so` 缺失 —— 红鲱鱼，别追

logcat 里会看到：

```
E BufferQueueProducer: Unable to open libpenguin.so: dlopen failed: library "libpenguin.so" not found.
E zation.terminal: Unable to open libpenguin.so: dlopen failed: library "libpenguin.so" not found.
```

这个库在整个系统里确实不存在，看起来非常像"缺文件导致失败"。**但它与 VM 无关：**

- 报错来源是 `BufferQueueProducer`（Android 图形组件），不是虚拟化栈
- **系统设置应用会报一模一样的错** —— 随便启动个应用对照一下就知道了
- `penguin` 字符串在 `VmTerminalApp.apk` 里出现 **0 次**

它是三星图形栈里一个可选库，任何绘图应用都会试探性 dlopen 一下，缺了无害。

---

## 5. ⚠️ 新旧镜像结构差异很大（但都不能救非保护 VM）

应用重下之后，镜像换了一代：

| | 旧 `hourly-1825`（2025-07-14） | 新 `hourly-6572`（2026-01-28） |
|---|---|---|
| vmlinuz | 13 MB | **43 MB** |
| initrd.img | 1 MB | **36 MB** |
| root_part | 467 GB 稀疏 | 3.1 GB |
| cidata.iso | 无 | **有**（cloud-init） |
| kernel_extras_part | 有 | 无 |
| 内核参数 | 基础 | 多了 `arm64.nompam 8250.nr_uarts=4` |

新镜像明显更好（也是本方案用的那份），但**换新镜像并不能让非保护 VM 启动** —— 实测同样被拒。

---

## 6. ❌ 从 Termux 用 adb 无线配对（用于启用应用）

Termux 和 proot Alpine 里的 `adb` **配对功能是坏的**：

```
$ adb pair 192.168.1.70:38501 <code>
error: protocol fault (couldn't read status message): Success

# adb server 日志：
tls_connection.cpp: [client]: Handshake failed in SSL_accept/SSL_connect [invalid library (0)]
pairing_connection.cpp: Failed to handshake with the peer fd=11
```

adbwifi 的配对需要 BoringSSL，而 termux 的 android-tools 是对 OpenSSL 编译的。
**每个端口都会这样失败，不是你操作错了。**

👉 用 **Shizuku**（自带正确的配对实现）+ 它导出的 `rish`：

```bash
RISH_APPLICATION_ID=com.termux bash ~/.rish/rish -c 'pm enable com.android.virtualization.terminal'
```

⚠️ Termux:API / Shizuku 这类声明了 `sharedUserId` 的应用**必须和 Termux 本体同签名**
（F-Droid 版 Termux → 装 F-Droid 版 Termux:API），否则 Android 直接拒绝安装。

---

## 7. ❌ 在 Android 侧 loop 挂载 root_part 来改镜像

```
$ losetup /dev/block/loop54 root_part && mount -t ext4 /dev/block/loop54 /mnt/vmroot
mount: '/dev/block/loop54'->'/mnt/vmroot': I/O error

$ dmesg
I/O error, dev loop54, sector 0 op 0x0:(READ)
EXT4-fs (loop54): unable to read superblock
```

文件本身是好的（`dd` 能读，ext4 魔数 `53 ef` 在偏移 0x438 处正常）。
loop 设备在 f2fs 上的大稀疏文件会读失败。

👉 想改 rootfs 就从 VM 内部改，或者用内核参数（`systemd.mask=` 等）绕过，不必改镜像。

---

## 8. ❌ `init=/bin/sh` 进单用户模式

```
[    0.692318][    T1] Warning: unable to open an initial console.
[    0.757011][    T1] Run /bin/sh as init process
[    0.765174][    T1] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000000
```

内核打不开 `/dev/console`（**根因还是缺 `8250.nr_uarts=4`**），`/bin/sh` 拿不到 stdin
立刻读到 EOF 退出 → init 退出 → panic。

👉 用 systemd 正常启动 + `systemd.debug_shell=ttyS0`，systemd 会正确设置控制台。

---

## 9. ❌ `idle=poll` 治崩溃

我一度以为崩溃是 guest 进入空闲（WFI）导致的，加了 `idle=poll`。**没用，反而崩得更早。**

真正原因是 getty 和 debug shell 抢 ttyS0，见主 README。

---

## 10. ❌ 「是不是被 Android 的内存回收干掉了？」

合理的猜测，但**证据不支持**：

- logcat 里搜 `lowmemorykiller|lmkd|kill.*crosvm` → **零条记录**
- 崩溃是 crosvm 自己的 vCPU 线程报的内部错误：
  `vcpu hit unknown error: Invalid argument (os error 22)`，不是被信号杀掉
- 崩溃点**确定性复现**在同一个启动阶段（`graphical.target` 之后），不是随机的
- 修好 getty 冲突后，同样的内存占用下跑 125 秒零崩溃

---

## 11. ❌ 第三方 crosvm 构建（本方案不需要）

[gunyah-on-sd-guide](https://github.com/polygraphene/gunyah-on-sd-guide) 的 v0.0.2 提供了
`crosvm-a16` + `libbinder.so` + `libbinder_ndk.so`。我下载测试过：

**在没屏蔽 getty 的情况下它同样崩溃**。屏蔽之后，系统自带的
`/apex/com.android.virt/bin/crosvm` 就完全够用了，不需要第三方二进制。

---

## 12. ❌ 解锁 bootloader / 获得永久 root（美版机型）

```
ro.product.model      = SM-S938U
ro.boot.flash.locked  = 1
ro.boot.carrierid     = XAA
sys.oem_unlock_allowed = (空)
ro.oem_unlock_supported = (空)
```

美版三星（U / U1）的 bootloader **永久锁定**，开发者选项里连「OEM 解锁」这一项都不会出现。
不能刷改过的 boot 镜像 → Magisk/KernelSU 的标准安装方式都用不了，只能靠临时 root 方案。

`smfwtool` 之类的工具**换 CSC/国家码也没用** —— 那只改客制化配置，hypervisor 能力编译在
固件二进制里，同型号所有 CSC 共用同一套。跨型号刷（如国际版 SM-S938B）在锁定 BL 下会被拒。

---

## 13. ℹ️ 顺带：这台机器为什么没有 `/dev/kvm`

```
$ zcat /proc/config.gz | grep -E '^CONFIG_(KVM|GUNYAH)'
CONFIG_KVM=y
CONFIG_GUNYAH=y
$ ls /dev/kvm
ls: /dev/kvm: No such file or directory
$ cat /sys/hypervisor/type
gunyah
```

KVM 编译进内核了，但 **Gunyah 占着 EL2**，内核只能跑在 EL1，KVM 无法初始化。
所以别指望用 KVM，只能走 Gunyah。

---

## 附:官方应用能被推进到哪一步（以及为什么最终仍不行）

有 root 的话，官方 Terminal 应用可以被一路推到**只差一步**。完整实测记录：

| 关卡 | 做法 | 结果 |
|---|---|---|
| ① 框架门禁 | 配置里 `"protected": true` | ✅ 过（`UnsupportedOperationException` 消失） |
| ② SELinux 标签 | `chcon u:object_r:shell_data_file:s0` 镜像文件 | ✅ 过（否则 `Label u:object_r:privapp_data_file:s0 is not allowed`） |
| ③ pVM 不支持网络 | 配置里 `"network": false` | ✅ 过（否则 `Network feature is not supported for pVM yet`） |
| ④ **VM 真的被创建并启动** | — | ✅ `Protected virtual machine "debian" (cid: 2076) created / started` |
| ⑤ 中断号冲突 | — | ❌ `failed to register irq fd: File exists` |

第 ⑤ 关无解。原因是**设备数量超限**，实测阈值很精确：

```
最小配置 + 额外 6 个 virtio-console  → 正常启动
最小配置 + 额外 8 个                 → 正常启动
最小配置 + 额外 9 个                 → 正常启动
最小配置 + 额外 10 个                → failed to register irq fd
```

也就是**约 11~12 个虚拟设备到顶**。而官方应用要求约 13 个：

```
4 × --input（触摸/键盘/鼠标/开关）
1 × --virtio-snd（声卡）
3 × virtio-console + 2 × hardware=serial
2 × --block
1 × vsock + 1 × --android-display-service
```

**只超了一两个，却过不去。** 根因是 Gunyah 要求每个 irqfd 有唯一标签，而 **KVM 允许多个 irqfd 共用同一个 GSI** —— 同样的设备清单在 Pixel 上毫无问题。

**而且这些设备关不掉。** 应用的 `ConfigJson` 确实支持 `input` / `audio` / `display` / `gpu` 字段
（从 DEX 里能看到 `ConfigJson$InputJson`、`ConfigJson$AudioJson`、`ConfigJson$DisplayJson`），
但实测把它们全设成 false 之后，`--input` 和 `--virtio-snd` **一个都没少** —— 说明是应用代码里
写死的，不受配置控制。要去掉只能改 APK 或 crosvm，而两者都在 **dm-verity 保护的只读 APEX 里**，
改了签名过不了，应用根本加载不起来。

> 顺带澄清一个常见误解：**小米 15 等骁龙机型同样"有"这个应用，但同样用不了。**
> 它是 mainline 模块，每台 Android 16 设备都带；能否运行取决于芯片。
> 目前只有 Tensor G1+、天玑 9400+、Exynos 2500 支持
> （[Android Authority](https://www.androidauthority.com/snapdragon-chips-android-linux-terminal-3608648/)）。
