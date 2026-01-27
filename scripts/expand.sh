#!/bin/bash

####################################################################################
# Initialization Script for Rocky Linux 9: System Update, Optimization, and Tuning #
####################################################################################

set -e

CMD=$(basename "$0")

# Usage
usage() {
  cat <<EOF
Usage: $CMD <command>

Available commands:
  all       Run all initialization steps
  update    Update system and install base packages
  security  Disable SELinux and firewall
  time      Set timezone and enable NTP
  ssh       Configure SSH
  optimize  Apply system tuning: limits, sysctl, THP, NUMA
  disk      Format and mount a selected disk with LVM and filesystem
  autodisk  Auto-detect unmounted disks, format and mount to /custom path
  expand    Expand existing LVM volume and filesystem
  clean     Clean DNF cache
EOF
}

ensure_lvm_installed() {
  if ! command -v lvs &> /dev/null; then
    echo "lvs 命令不存在，正在安装 lvm2..."
    dnf install -y lvm2
  fi
}
# Clean DNF cache
clean_cache() {
  echo "清理 DNF 缓存..."
  dnf clean all
}
# System Update & Package Installation
update_system() {
  clean_cache
  echo "更新系统..."
  dnf update -y
  echo "安装基本软件包..."
  dnf install epel-release -y
  dnf install -y \
    unzip vim wget curl net-tools epel-release \
    htop git open-vm-tools bash-completion lvm2 cloud-utils-growpart parted xfsprogs e2fsprogs \
    iftop traceroute nmap lsof net-tools
}

# Disable Firewall and SELinux
configure_security() {
  echo "关闭防火墙..."
  systemctl stop firewalld || true
  systemctl disable firewalld || true

  echo "禁用 SELinux..."
  setenforce 0 || true
  sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
}

# Timezone and NTP
configure_time() {
  echo "设置时区为 Asia/Shanghai..."
  timedatectl set-timezone Asia/Shanghai

  echo "安装并配置 chrony 时间同步..."
  dnf install -y chrony
  systemctl enable --now chronyd
  timedatectl set-ntp true
}

# SSH Configuration
configure_ssh() {
  echo "配置 SSH..."
  sed -i "s@#UseDNS no@UseDNS no@g" /etc/ssh/sshd_config
  systemctl restart sshd
}

# Optimization: limits, sysctl, THP, NUMA
apply_optimizations() {
  echo "配置 limits.conf..."
  cat <<EOF >> /etc/security/limits.conf
* soft nofile 1024000
* hard nofile 1024000
* soft nproc 1024000
* hard nproc 1024000
* soft stack 1024000
* hard stack 1024000
EOF

  echo "配置 sysctl 参数..."
  cat <<EOF >> /etc/sysctl.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.all.accept_dad = 0
net.ipv6.conf.default.accept_dad = 0

vm.swappiness = 0
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
fs.file-max = 2097152
fs.aio-max-nr = 1048576
fs.inotify.max_user_watches = 524288
net.core.somaxconn = 1024
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 1024 65535
kernel.sched_min_granularity_ns = 10000000
kernel.sched_wakeup_granularity_ns = 15000000
vm.vfs_cache_pressure = 50
kernel.pid_max = 4194303
EOF
  sysctl -p

  echo "禁用透明大页 (THP)..."
  echo 'never' > /sys/kernel/mm/transparent_hugepage/enabled || true
  echo 'never' > /sys/kernel/mm/transparent_hugepage/defrag || true
  cat <<EOF >> /etc/rc.d/rc.local
if test -f /sys/kernel/mm/transparent_hugepage/enabled; then
  echo never > /sys/kernel/mm/transparent_hugepage/enabled
fi
if test -f /sys/kernel/mm/transparent_hugepage/defrag; then
  echo never > /sys/kernel/mm/transparent_hugepage/defrag
fi
EOF
  chmod +x /etc/rc.d/rc.local

  echo "禁用 NUMA..."
  sed -i '/^GRUB_CMDLINE_LINUX=/ s/"$/ numa=off"/' /etc/default/grub
  grub2-mkconfig -o /boot/grub2/grub.cfg
  [ -d /boot/efi/EFI/rocky ] && grub2-mkconfig -o /boot/efi/EFI/rocky/grub.cfg
}

setup_disk_lvm() {
  echo "可用磁盘如下："
  lsblk -d -e 7,11 -o NAME,SIZE,TYPE | grep disk

  read -p "请输入要格式化为 LVM 的磁盘名称（如 sdb）: " DISK
  read -p "请输入文件系统类型（xfs/ext4）[默认: xfs]: " FSTYPE
  FSTYPE=${FSTYPE:-xfs}
  read -p "请输入挂载目录（如 /data）: " MOUNTDIR

  DEV=/dev/$DISK

  if [ ! -b "$DEV" ]; then
    echo "错误: 磁盘 $DEV 不存在。"
    exit 1
  fi

  # 检查是否已有分区
  if lsblk "$DEV" | grep -q "${DISK}[0-9]"; then
    echo "检测到 $DEV 上已有分区，将自动清除..."
    # 卸载所有分区（谨慎处理）
    for PART in $(lsblk -ln $DEV | awk '$1 ~ /[0-9]$/ {print $1}'); do
      MOUNTED=$(lsblk -n -o MOUNTPOINT "/dev/$PART")
      if [ -n "$MOUNTED" ]; then
        echo "卸载挂载点 $MOUNTED"
        umount -f "$MOUNTED"
      fi
    done
    # 清除分区表
    wipefs -a "$DEV"
    parted -s "$DEV" mklabel gpt
  else
    echo "$DEV 无分区，无需清除。"
    parted -s "$DEV" mklabel gpt
  fi

  echo "创建分区和 LVM..."
  parted -s "$DEV" mkpart primary 0% 100%
  PARTITION="${DEV}p1"

  pvcreate "$PARTITION"
  vgcreate vg_data "$PARTITION"
  lvcreate -l 100%FREE -n lv_data vg_data

  mkfs.$FSTYPE /dev/vg_data/lv_data
  mkdir -p "$MOUNTDIR"
  echo "/dev/vg_data/lv_data $MOUNTDIR $FSTYPE defaults 0 0" >> /etc/fstab
  mount -a
  echo "✅ LVM 文件系统已挂载至 $MOUNTDIR"
}


# Automatically initialize and mount all unused disks
auto_format_disks() {
  read -p "请输入自动挂载目录前缀（如 /data）: " PREFIX
  [ -z "$PREFIX" ] && PREFIX=/data
  ensure_lvm_installed
  echo "自动检测未挂载未格式化磁盘并挂载到 ${PREFIX}X..."
  index=1
  for dev in $(lsblk -dpno NAME,TYPE | grep disk | awk '{print $1}'); do
    mountpoint=$(lsblk -no MOUNTPOINT ${dev} || true)
    fstype=$(lsblk -no FSTYPE ${dev} || true)
    if [ -z "$mountpoint" ] && [ -z "$fstype" ]; then
      echo "格式化 $dev 为 xfs，并挂载到 ${PREFIX}${index}"
      parted -s $dev mklabel gpt mkpart primary 0% 100%
      pvcreate ${dev}1
      vgcreate vg_data${index} ${dev}1
      lvcreate -l 100%FREE -n lv_data${index} vg_data${index}
      mkfs.xfs /dev/vg_data${index}/lv_data${index}
      mkdir -p ${PREFIX}${index}
      echo "/dev/vg_data${index}/lv_data${index} ${PREFIX}${index} xfs defaults 0 0" >> /etc/fstab
      mount ${PREFIX}${index}
      ((index++))
    fi
  done
}

# Expand existing LVM volume and filesystem
expand_lvm() {
  ensure_lvm_installed

  echo "[INFO] 自动扩展挂载在 / 的根文件系统..."

  ROOT_DEV=$(df / | awk 'NR==2 {print $1}' | xargs)
  echo "[INFO] 根设备: $ROOT_DEV"

  LV_PATH=$(lvs --noheadings -o lv_path | grep -E "$ROOT_DEV|/" | awk '{print $1}' | head -n1 || true)
  [ -z "$LV_PATH" ] && LV_PATH="$ROOT_DEV"

  VG_NAME=$(lvs "$LV_PATH" -o vg_name --noheadings | awk '{print $1}' || true)
  PV_NAME=$(pvs --noheadings -o pv_name | grep -E 'sd|nvme|vd' | awk '{print $1}' | head -n1)

  if [ -z "$VG_NAME" ] || [ -z "$PV_NAME" ]; then
    echo "[ERROR] 无法识别 VG 或 PV，扩展失败。"
    return 1
  fi

  DISK=$(echo "$PV_NAME" | sed -E 's/p?[0-9]+$//')
  PART=$(echo "$PV_NAME" | sed "s|$DISK||")

  echo "[INFO] 磁盘: $DISK 分区: $PART"
  echo "[STEP] growpart 扩展分区..."
  growpart "$DISK" "${PART/#p/}"

  echo "[STEP] 扩展 PV..."
  pvresize "$PV_NAME"

  echo "[STEP] 扩展逻辑卷 $LV_PATH..."
  lvextend -l +100%FREE "$LV_PATH"

  echo "[STEP] 扩展文件系统..."
  FSTYPE=$(lsblk -no FSTYPE "$LV_PATH")
  if [ "$FSTYPE" = "xfs" ]; then
    xfs_growfs /
  elif [ "$FSTYPE" = "ext4" ]; then
    resize2fs "$LV_PATH"
  else
    echo "[ERROR] 不支持的文件系统类型: $FSTYPE"
    return 1
  fi

  echo "[SUCCESS] 根文件系统扩展完成。"
  df -h /
}


# Main Entry
main() {
  if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 用户执行此脚本。"
    exit 1
  fi

  case "$1" in
    all)
      update_system
      configure_security
      configure_time
      configure_ssh
      apply_optimizations
      clean_cache
      ;;
    update)
      update_system
      ;;
    security)
      configure_security
      ;;
    time)
      configure_time
      ;;
    ssh)
      configure_ssh
      ;;
    optimize)
      apply_optimizations
      ;;
    disk)
      setup_disk_lvm
      ;;
    autodisk)
      auto_format_disks
      ;;
    expand)
      expand_lvm
      ;;
    clean)
      clean_cache
      ;;
    *)
      usage
      exit 1
      ;;
  esac

  echo "初始化完成，是否立即重启以应用配置？"
  read -p "现在重启系统吗？ (y/n): " REBOOT
  if [ "$REBOOT" = "y" ]; then
    reboot
  fi
}

main "$@"