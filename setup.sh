#!/data/data/com.termux/files/usr/bin/bash
# setup.sh — 准备 Debian VM 镜像并安装 linuxvm 命令
set -eu

VMDIR=${LINUXVM_DIR:-/data/local/tmp/linuxvm}
APPDIR=/data/user/0/com.android.virtualization.terminal/files/linux
BINDIR=${BINDIR:-$HOME/.local/bin}
SRC="$(cd "$(dirname "$0")" && pwd)"

command -v su >/dev/null 2>&1 || { echo "!! 需要 root（找不到 su）" >&2; exit 1; }
su -c true 2>/dev/null || { echo "!! su 不可用，请先获取 root" >&2; exit 1; }

echo "==> [1/3] 查找镜像"
if su -c "test -r $APPDIR/vmlinuz && test -r $APPDIR/root_part" 2>/dev/null; then
  echo "    找到 Linux 终端应用下载的镜像：$APPDIR"
  SRCDIR=$APPDIR
elif [ -r ./vmlinuz ] && [ -r ./root_part ]; then
  echo "    使用当前目录下的 vmlinuz / root_part"
  SRCDIR=$(pwd)
else
  cat >&2 <<'EOT'
!! 找不到镜像。二选一：

   A) 让系统自带的「Linux 终端」应用下载（它跑不起 VM，但下载功能正常）：
        su -c 'pm enable com.android.virtualization.terminal'
        su -c 'settings put global linux_terminal_available 1'
        su -c 'am start -n com.android.virtualization.terminal/.MainActivity'
      在手机上点「安装」，等约 525 MB 下完，然后重跑本脚本。

   B) 自己下载 ferrochrome 镜像，解压出 vmlinuz 和 root_part 放到当前目录：
        curl -LO https://dl.google.com/android/ferrochrome/3500000/aarch64/images.tar.gz
        tar xf images.tar.gz
EOT
  exit 1
fi

echo "==> [2/3] 复制到 $VMDIR（保留稀疏，实占约 1.6G）"
su -c "mkdir -p $VMDIR && \
       $PREFIX/bin/cp --sparse=always $SRCDIR/vmlinuz $VMDIR/ && \
       $PREFIX/bin/cp --sparse=always $SRCDIR/root_part $VMDIR/ && \
       $PREFIX/bin/du -sh $VMDIR"

echo "==> [3/3] 安装 linuxvm 到 $BINDIR"
mkdir -p "$BINDIR"
install -m 755 "$SRC/linuxvm" "$BINDIR/linuxvm"
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo "    提示：$BINDIR 不在 PATH 里，请加上：echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc" ;;
esac

cat <<EOT

完成。启动：

    linuxvm

会落到 Debian 13 的 root shell；VM 内输入 poweroff 退出。
注意：root 是临时的，手机重启后需要重新获取 root，linuxvm 才能用。
EOT
