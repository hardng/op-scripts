#!/bin/bash
# 格式化磁盘并挂载为 XFS
# 用法: ./format_xfs.sh /dev/sdb /data/xfsdir

set -euo pipefail

disk="$1"        # 磁盘设备，例如 /dev/sdb
mount_point="$2" # 挂载目录，例如 /data/xfsdir

if [[ -z "$disk" || -z "$mount_point" ]]; then
  echo "用法: $0 <磁盘设备> <挂载目录>"
  exit 1
fi

# 确认磁盘存在
if [[ ! -b "$disk" ]]; then
  echo "❌ 磁盘设备不存在: $disk"
  exit 1
fi

# 确认磁盘未挂载
if mount | grep -q "^$disk"; then
  echo "❌ 磁盘已挂载: $disk"
  exit 1
fi

# 创建挂载目录
mkdir -p "$mount_point"

echo "⚠️  将清空磁盘: $disk"
read -rp "确认继续吗？(yes/NO): " confirm
if [[ "$confirm" != "yes" ]]; then
  echo "取消操作"
  exit 0
fi

# 格式化为 XFS
echo "👉 格式化 $disk 为 XFS..."
mkfs.xfs -f "$disk"

# 获取 UUID
uuid=$(blkid -s UUID -o value "$disk")

# 写入 /etc/fstab（避免重启后丢失挂载）
echo "👉 写入 /etc/fstab..."
grep -q "$uuid" /etc/fstab || echo "UUID=$uuid $mount_point xfs defaults 0 0" >> /etc/fstab

# 挂载
echo "👉 挂载到 $mount_point..."
mount -a

echo "✅ 完成: $disk 已挂载到 $mount_point (XFS)"