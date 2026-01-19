#!/bin/bash
####################################################################################
# Cross-Linux Initialization Script - CentOS7+/Rocky/Alma & Debian/Ubuntu          #
####################################################################################
set -e
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin

# Define global variables
OS_FAMILY=""
OS_NAME=""
OS_VERSION=""
PKG_MGR=""
EXIT_CODE=0

# Display detailed usage information
usage() {
  cat <<EOF
Usage: $0 <command>
Initialize and configure Linux systems (supports CentOS7+/Rocky/Alma and Debian/Ubuntu)

Available commands:
  all       Perform all configurations (install packages, security, timezone, SSH, optimization, expand, clean)
  init      Perform configurations (install packages, security, timezone, SSH, optimization, clean)
  update    Install or update base packages
  mirror    Configure package mirrors to use Aliyun (China) for faster downloads
  security  Disable firewall and SELinux (RHEL) or ufw (Debian)
  time      Set timezone to Asia/Shanghai and enable NTP
  ssh       Configure SSH (disable UseDNS)
  optimize  Optimize system parameters (sysctl, limits, THP, NUMA)
  disk      Format and mount a selected disk with LVM and filesystem
  autodisk  Auto-detect unmounted disks, format, and mount to /dataX
  expand    Expand root LVM partition
  clean     Clean package manager cache

Examples:
  $0 all       # Perform all initialization tasks
  $0 mirror    # Configure Aliyun mirrors for faster downloads
  $0 autodisk  # Auto-format and mount unused disks
  $0 expand    # Expand root LVM partition
EOF
  exit 1
}

# Detect operating system type and version
detect_os() {
  echo "[INFO] Detecting operating system..."
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME=$ID
    OS_VERSION=$VERSION_ID
    case "$ID" in
      centos|rocky|almalinux|rhel)
        OS_FAMILY="rhel"
        PKG_MGR=$(command -v dnf >/dev/null 2>&1 && echo "dnf" || echo "yum")
        ;;
      debian|ubuntu)
        OS_FAMILY="debian"
        PKG_MGR="apt"
        ;;
      *)
        echo "[ERROR] Unsupported OS: $ID"
        exit 1
        ;;
    esac
    echo "[INFO] Detected OS: $OS_NAME $OS_VERSION ($OS_FAMILY)"
  else
    echo "[ERROR] Unable to detect OS: /etc/os-release not found"
    exit 1
  fi
}

# Check available memory and warn if low
check_memory() {
  local mem_available_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  local mem_available_mb=$((mem_available_kb / 1024))
  
  echo "[INFO] Available memory: ${mem_available_mb}MB"
  
  if [ $mem_available_mb -lt 512 ]; then
    echo "[WARN] Low memory detected (${mem_available_mb}MB available)"
    echo "[WARN] Package installation uses batched mode to reduce memory pressure"
    echo "[WARN] If installation still fails, consider increasing system memory"
  fi
}


# Ensure lvm2 and parted are installed
ensure_lvm_installed() {
  if ! command -v lvs &>/dev/null || ! command -v parted &>/dev/null; then
    echo "[INFO] Installing lvm2 and parted..."
    if [ "$OS_FAMILY" = "rhel" ]; then
      $PKG_MGR install -y lvm2 parted || {
        echo "[ERROR] Failed to install lvm2 or parted"
        EXIT_CODE=1
        return 1
      }
    elif [ "$OS_FAMILY" = "debian" ]; then
      $PKG_MGR update -y || {
        echo "[ERROR] Failed to update package sources"
        EXIT_CODE=1
        return 1
      }
      $PKG_MGR install -y lvm2 parted || {
        echo "[ERROR] Failed to install lvm2 or parted"
        EXIT_CODE=1
        return 1
      }
    fi
  fi
}

# Clean package manager cache
clean_cache() {
  echo "[INFO] Cleaning package manager cache..."
  if [ "$OS_FAMILY" = "rhel" ]; then
    $PKG_MGR clean all || {
      echo "[WARN] Failed to clean package cache"
      EXIT_CODE=1
    }
  elif [ "$OS_FAMILY" = "debian" ]; then
    $PKG_MGR clean || {
      echo "[WARN] Failed to clean package cache"
      EXIT_CODE=1
    }
  fi
}

# Configure base package mirrors to use Aliyun (China) for faster downloads
configure_base_mirrors() {
  echo "[INFO] Configuring base package mirrors..."
  
  if [ "$OS_FAMILY" = "rhel" ]; then
    # Backup original repo files
    if [ ! -d /etc/yum.repos.d/backup ]; then
      mkdir -p /etc/yum.repos.d/backup
      cp -f /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/ 2>/dev/null || true
    fi
    
    # Configure based on OS version
    case "$OS_NAME" in
      rocky)
        echo "[INFO] Configuring Rocky Linux Aliyun mirrors..."
        sed -e 's|^mirrorlist=|#mirrorlist=|g' \
            -e 's|^#baseurl=http://dl.rockylinux.org/$contentdir|baseurl=https://mirrors.aliyun.com/rockylinux|g' \
            -i.bak /etc/yum.repos.d/rocky*.repo
        ;;
      almalinux)
        echo "[INFO] Configuring AlmaLinux Aliyun mirrors..."
        sed -e 's|^mirrorlist=|#mirrorlist=|g' \
            -e 's|^#baseurl=https://repo.almalinux.org|baseurl=https://mirrors.aliyun.com|g' \
            -i.bak /etc/yum.repos.d/almalinux*.repo
        ;;
      centos)
        if [ "${OS_VERSION%%.*}" = "7" ]; then
          echo "[INFO] Configuring CentOS 7 Aliyun mirrors..."
          sed -e 's|^mirrorlist=|#mirrorlist=|g' \
              -e 's|^#baseurl=http://mirror.centos.org|baseurl=https://mirrors.aliyun.com|g' \
              -i.bak /etc/yum.repos.d/CentOS-*.repo
        else
          echo "[INFO] Configuring CentOS Stream Aliyun mirrors..."
          sed -e 's|^mirrorlist=|#mirrorlist=|g' \
              -e 's|^#baseurl=http://mirror.centos.org|baseurl=https://mirrors.aliyun.com|g' \
              -i.bak /etc/yum.repos.d/centos*.repo
        fi
        ;;
    esac
    
    # Clean and rebuild cache
    $PKG_MGR clean all
    $PKG_MGR makecache || {
      echo "[WARN] Failed to rebuild cache, continuing anyway"
      EXIT_CODE=1
    }
    
  elif [ "$OS_FAMILY" = "debian" ]; then
    # Backup original sources.list
    if [ ! -f /etc/apt/sources.list.bak ]; then
      cp /etc/apt/sources.list /etc/apt/sources.list.bak
    fi
    
    echo "[INFO] Configuring Debian/Ubuntu Aliyun mirrors..."
    case "$OS_NAME" in
      ubuntu)
        sed -i 's|http://.*archive.ubuntu.com|https://mirrors.aliyun.com|g' /etc/apt/sources.list
        sed -i 's|http://.*security.ubuntu.com|https://mirrors.aliyun.com|g' /etc/apt/sources.list
        ;;
      debian)
        sed -i 's|http://.*debian.org|https://mirrors.aliyun.com|g' /etc/apt/sources.list
        ;;
    esac
    
    $PKG_MGR update || {
      echo "[WARN] Failed to update package sources"
      EXIT_CODE=1
    }
  fi
  
  echo "[INFO] Base mirror configuration completed"
}

# Configure EPEL mirror (must be called after epel-release is installed)
configure_epel_mirror() {
  if [ "$OS_FAMILY" = "rhel" ]; then
    if [ -f /etc/yum.repos.d/epel.repo ]; then
      echo "[INFO] Configuring EPEL Aliyun mirror..."
      
      # Disable metalink and enable baseurl for all EPEL repos
      for repo_file in /etc/yum.repos.d/epel*.repo; do
        # Comment out metalink
        sed -i 's/^metalink=/#metalink=/g' "$repo_file"
        
        # Uncomment baseurl if it exists
        sed -i 's/^#baseurl=/baseurl=/g' "$repo_file"
        
        # Replace download.fedoraproject.org or download.example with mirrors.aliyun.com
        sed -i 's|download\.fedoraproject\.org/pub|mirrors.aliyun.com|g' "$repo_file"
        sed -i 's|download\.example/pub|mirrors.aliyun.com|g' "$repo_file"
      done
      
      # Clean and rebuild cache
      $PKG_MGR clean all
      $PKG_MGR makecache || {
        echo "[WARN] Failed to rebuild EPEL cache, continuing anyway"
        EXIT_CODE=1
      }
      echo "[INFO] EPEL mirror configuration completed"
    else
      echo "[WARN] EPEL repo file not found, skipping EPEL mirror configuration"
    fi
  fi
}


# Install base packages
install_pkgs() {
  echo "[INFO] Installing base packages..."
  if [ "$OS_FAMILY" = "rhel" ]; then
    # Install epel-release first
    $PKG_MGR install -y epel-release || {
      echo "[WARN] Failed to install epel-release, may already be installed or network issue"
      EXIT_CODE=1
    }
    
    # Now configure EPEL mirror after epel-release is installed
    configure_epel_mirror || true
    
    # Install in batches to avoid OOM on low-memory systems
    echo "[INFO] Installing core utilities..."
    $PKG_MGR install -y unzip vim wget curl net-tools htop git bash-completion || {
      echo "[ERROR] Failed to install core utilities"
      EXIT_CODE=1
    }
    
    echo "[INFO] Installing disk and filesystem tools..."
    $PKG_MGR install -y lvm2 cloud-utils-growpart parted xfsprogs e2fsprogs || {
      echo "[ERROR] Failed to install disk tools"
      EXIT_CODE=1
    }
    
    echo "[INFO] Installing network and monitoring tools..."
    $PKG_MGR install -y iftop traceroute nmap lsof open-vm-tools || {
      echo "[ERROR] Failed to install network tools"
      EXIT_CODE=1
    }
  elif [ "$OS_FAMILY" = "debian" ]; then
    $PKG_MGR update -y || {
      echo "[ERROR] Failed to update package sources"
      EXIT_CODE=1
    }
    
    # Install in batches to avoid OOM on low-memory systems
    echo "[INFO] Installing core utilities..."
    $PKG_MGR install -y unzip vim wget curl net-tools htop git bash-completion || {
      echo "[ERROR] Failed to install core utilities"
      EXIT_CODE=1
    }
    
    echo "[INFO] Installing disk and filesystem tools..."
    $PKG_MGR install -y lvm2 cloud-guest-utils parted xfsprogs e2fsprogs || {
      echo "[ERROR] Failed to install disk tools"
      EXIT_CODE=1
    }
    
    echo "[INFO] Installing network and monitoring tools..."
    $PKG_MGR install -y iftop traceroute nmap lsof || {
      echo "[ERROR] Failed to install network tools"
      EXIT_CODE=1
    }
  fi
}

# Disable firewall and SELinux/ufw
disable_security() {
  case "$OS_FAMILY" in 
    "rhel")
      systemctl disable --now firewalld || {
        echo "[WARN] Failed to disable firewalld, may not be installed"
        EXIT_CODE=1
      }
      echo "[INFO] Disabling SELinux..."
      setenforce 0 2>/dev/null || {
        echo "[WARN] Failed to set SELinux to permissive, may already be disabled"
        EXIT_CODE=1
      }
      if [ -f /etc/selinux/config ]; then
        sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config || {
          echo "[ERROR] Failed to update SELinux config"
          EXIT_CODE=1
        }
      else
        echo "[WARN] SELinux config file not found"
        EXIT_CODE=1
      fi
      ;;
    "debian")
      systemctl disable --now ufw || {
        echo "[WARN] Failed to disable ufw, may not be installed"
        EXIT_CODE=1
      }
      ;;
  esac
}

# Set timezone to Asia/Shanghai and enable NTP
set_timezone_ntp() {
  echo "[INFO] Setting timezone to Asia/Shanghai and enabling NTP..."
  timedatectl set-timezone Asia/Shanghai || {
    echo "[ERROR] Failed to set timezone"
    EXIT_CODE=1
  }
  if [ "$OS_FAMILY" = "rhel" ]; then
    $PKG_MGR install -y chrony || {
      echo "[ERROR] Failed to install chrony"
      EXIT_CODE=1
    }
    systemctl enable --now chronyd || {
      echo "[ERROR] Failed to enable chronyd"
      EXIT_CODE=1
    }
  elif [ "$OS_FAMILY" = "debian" ]; then
    $PKG_MGR install -y chrony || {
      echo "[ERROR] Failed to install chrony"
      EXIT_CODE=1
    }
    systemctl enable --now chrony || {
      echo "[ERROR] Failed to enable chrony"
      EXIT_CODE=1
    }
  fi
  timedatectl set-ntp true || {
    echo "[ERROR] Failed to enable NTP"
    EXIT_CODE=1
  }
}

# Configure SSH to disable UseDNS
configure_ssh() {
  echo "[INFO] Configuring SSH..."
  if [ -f /etc/ssh/sshd_config ]; then
    sed -i 's/#UseDNS .*/UseDNS no/' /etc/ssh/sshd_config || {
      echo "[ERROR] Failed to configure SSH UseDNS"
      EXIT_CODE=1
    }
    sed -i 's/UseDNS .*/UseDNS no/' /etc/ssh/sshd_config || true # Ensure idempotency
    systemctl restart sshd || {
      echo "[ERROR] Failed to restart SSH service"
      EXIT_CODE=1
    }
  else
    echo "[ERROR] SSH configuration file not found"
    EXIT_CODE=1
  fi
}

# Apply system optimizations (sysctl, limits, THP, NUMA)
apply_sysctl_limits() {
  echo "[INFO] Applying system optimizations..."
  cat <<EOF >/etc/security/limits.d/99-custom.conf
* soft nofile 1024000
* hard nofile 1024000
* soft nproc 1024000
* hard nproc 1024000
* soft stack 1024000
* hard stack 1024000
EOF
  [ $? -eq 0 ] || {
    echo "[ERROR] Failed to write limits configuration"
    EXIT_CODE=1
  }

  cat <<EOF >/etc/sysctl.d/99-custom.conf
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
  [ $? -eq 0 ] || {
    echo "[ERROR] Failed to write sysctl configuration"
    EXIT_CODE=1
  }
  sysctl --system || {
    echo "[ERROR] Failed to apply sysctl settings"
    EXIT_CODE=1
  }
}

# Disable transparent huge pages and NUMA
disable_thp_numa() {
  echo "[INFO] Disabling transparent huge pages and NUMA..."
  if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo never > /sys/kernel/mm/transparent_hugepage/enabled || {
      echo "[ERROR] Failed to disable transparent huge pages (enabled)"
      EXIT_CODE=1
    }
    echo never > /sys/kernel/mm/transparent_hugepage/defrag || {
      echo "[ERROR] Failed to disable transparent huge pages (defrag)"
      EXIT_CODE=1
    }
    cat <<EOF >> /etc/rc.d/rc.local
#!/bin/bash
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
  echo never > /sys/kernel/mm/transparent_hugepage/enabled
fi
if [ -f /sys/kernel/mm/transparent_hugepage/defrag ]; then
  echo never > /sys/kernel/mm/transparent_hugepage/defrag
fi
EOF
    chmod +x /etc/rc.d/rc.local || {
      echo "[WARN] Failed to make rc.local executable"
      EXIT_CODE=1
    }
  else
    echo "[WARN] Transparent huge pages not supported on this system"
  fi

  if ! grep -q "numa=off" /etc/default/grub; then
    sed -i '/^GRUB_CMDLINE_LINUX=/ s/"$/ numa=off"/' /etc/default/grub || {
      echo "[ERROR] Failed to update GRUB configuration"
      EXIT_CODE=1
    }
    if [ "$OS_FAMILY" = "rhel" ]; then
      grub2-mkconfig -o /boot/grub2/grub.cfg || {
        echo "[ERROR] Failed to update GRUB config for RHEL"
        EXIT_CODE=1
      }
      [ -d /boot/efi/EFI/"$OS_NAME" ] && grub2-mkconfig -o /boot/efi/EFI/"$OS_NAME"/grub.cfg || true
    else
      update-grub || {
        echo "[ERROR] Failed to update GRUB config for Debian"
        EXIT_CODE=1
      }
    fi
  fi
}

# Format and mount a selected disk with LVM and filesystem
setup_disk_lvm() {
  echo "[INFO] Available disks:"
  lsblk -d -e 7,11 -o NAME,SIZE,TYPE | grep disk

  read -p "Enter the disk name to format as LVM (e.g., sdb): " DISK
  read -p "Enter filesystem type (xfs/ext4) [default: xfs]: " FSTYPE
  FSTYPE=${FSTYPE:-xfs}
  read -p "Enter mount directory (e.g., /data): " MOUNTDIR

  DEV=/dev/$DISK

  if [ ! -b "$DEV" ]; then
    echo "[ERROR] Disk $DEV does not exist"
    EXIT_CODE=1
    return
  fi

  # Check for existing partitions
  if lsblk "$DEV" | grep -q "${DISK}[0-9]"; then
    echo "[INFO] Detected partitions on $DEV, clearing..."
    for PART in $(lsblk -ln $DEV | awk '$1 ~ /[0-9]$/ {print $1}'); do
      MOUNTED=$(lsblk -n -o MOUNTPOINT "/dev/$PART")
      if [ -n "$MOUNTED" ]; then
        echo "[INFO] Unmounting $MOUNTED"
        umount -f "$MOUNTED" || {
          echo "[WARN] Failed to unmount $MOUNTED"
          EXIT_CODE=1
        }
      fi
    done
    wipefs -a "$DEV" || {
      echo "[ERROR] Failed to wipe filesystem on $DEV"
      EXIT_CODE=1
    }
    parted -s "$DEV" mklabel gpt || {
      echo "[ERROR] Failed to create GPT label on $DEV"
      EXIT_CODE=1
    }
  else
    echo "[INFO] No partitions on $DEV, creating GPT label"
    parted -s "$DEV" mklabel gpt || {
      echo "[ERROR] Failed to create GPT label on $DEV"
      EXIT_CODE=1
    }
  fi

  echo "[INFO] Creating partition and LVM..."
  parted -s "$DEV" mkpart primary 0% 100% || {
    echo "[ERROR] Failed to create partition on $DEV"
    EXIT_CODE=1
  }
  PARTITION="${DEV}p1"

  ensure_lvm_installed || return
  pvcreate "$PARTITION" || {
    echo "[ERROR] Failed to create physical volume on $PARTITION"
    EXIT_CODE=1
  }
  vgcreate vg_data "$PARTITION" || {
    echo "[ERROR] Failed to create volume group"
    EXIT_CODE=1
  }
  lvcreate -l 100%FREE -n lv_data vg_data || {
    echo "[ERROR] Failed to create logical volume"
    EXIT_CODE=1
  }

  mkfs.$FSTYPE /dev/vg_data/lv_data || {
    echo "[ERROR] Failed to format filesystem on /dev/vg_data/lv_data"
    EXIT_CODE=1
  }
  mkdir -p "$MOUNTDIR" || {
    echo "[ERROR] Failed to create mount directory $MOUNTDIR"
    EXIT_CODE=1
  }
  echo "/dev/vg_data/lv_data $MOUNTDIR $FSTYPE defaults 0 0" >> /etc/fstab
  mount -a || {
    echo "[ERROR] Failed to mount $MOUNTDIR"
    EXIT_CODE=1
  }
  echo "[INFO] LVM filesystem mounted at $MOUNTDIR"
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

# Expand root LVM partition (standalone)
expand_root_lvm() {
  echo "[INFO] Expanding root partition..."

  # Local OS detection for standalone execution
  local local_os_family=""
  local local_pkg_mgr=""
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
      centos|rocky|almalinux|rhel)
        local_os_family="rhel"
        local_pkg_mgr=$(command -v dnf >/dev/null 2>&1 && echo "dnf" || echo "yum")
        ;;
      debian|ubuntu)
        local_os_family="debian"
        local_pkg_mgr="apt"
        ;;
      *)
        echo "[ERROR] Unsupported OS: $ID"
        EXIT_CODE=1
        return
        ;;
    esac
    echo "[INFO] Detected OS: $ID $VERSION_ID ($local_os_family)"
  else
    echo "[ERROR] Unable to detect OS: /etc/os-release not found"
    EXIT_CODE=1
    return
  fi

  # Install growpart and lvm2 if not available
  if ! command -v growpart &>/dev/null; then
    echo "[INFO] Installing growpart tool..."
    if [ "$local_os_family" = "rhel" ]; then
      $local_pkg_mgr install -y cloud-utils-growpart || {
        echo "[ERROR] Failed to install cloud-utils-growpart"
        EXIT_CODE=1
        return
      }
    elif [ "$local_os_family" = "debian" ]; then
      $local_pkg_mgr update -y || {
        echo "[ERROR] Failed to update package sources"
        EXIT_CODE=1
        return
      }
      $local_pkg_mgr install -y cloud-guest-utils || {
        echo "[ERROR] Failed to install cloud-guest-utils"
        EXIT_CODE=1
        return
      }
    fi
  fi
  if ! command -v lvs &>/dev/null; then
    echo "[INFO] Installing lvm2..."
    if [ "$local_os_family" = "rhel" ]; then
      $local_pkg_mgr install -y lvm2 || {
        echo "[ERROR] Failed to install lvm2"
        EXIT_CODE=1
        return
      }
    elif [ "$local_os_family" = "debian" ]; then
      $local_pkg_mgr update -y || {
        echo "[ERROR] Failed to update package sources"
        EXIT_CODE=1
        return
      }
      $local_pkg_mgr install -y lvm2 || {
        echo "[ERROR] Failed to install lvm2"
        EXIT_CODE=1
        return
      }
    fi
  fi

  # Detect root device
  ROOT_DEV=$(df / | awk 'NR==2 {print $1}')
  if [ -z "$ROOT_DEV" ]; then
    echo "[ERROR] Unable to detect root device"
    EXIT_CODE=1
    return
  fi
  echo "[INFO] Root device: $ROOT_DEV"

  # Get LVM details
  LV_PATH=$(lvs --noheadings -o lv_path | grep -E "$ROOT_DEV|/" || true)
  [ -z "$LV_PATH" ] && LV_PATH="$ROOT_DEV"
  VG_NAME=$(lvs "$LV_PATH" -o vg_name --noheadings | awk '{print $1}' || true)
  PV_NAME=$(pvs --noheadings -o pv_name | grep -E 'sd|nvme|vd' | head -n1 || true)

  if [ -z "$VG_NAME" ] || [ -z "$PV_NAME" ]; then
    echo "[ERROR] Unable to identify VG or PV for expansion"
    EXIT_CODE=1
    return
  fi

  # Extract disk and partition
  DISK=$(echo "$PV_NAME" | sed -E 's/p?[0-9]+$//')
  PART=$(echo "$PV_NAME" | sed "s|$DISK||")
  if [ -z "$DISK" ] || [ -z "$PART" ]; then
    echo "[ERROR] Unable to determine disk or partition number"
    EXIT_CODE=1
    return
  fi
  echo "[INFO] Disk: $DISK, Partition: $PART"

  # Expand partition, physical volume, and logical volume
  echo "[INFO] Growing partition..."
  growpart "$DISK" "${PART/#p/}" || {
    echo "[WARN] Failed to grow partition, may already be extended"
    EXIT_CODE=1
  }
  echo "[INFO] Resizing physical volume..."
  pvresize "$PV_NAME" || {
    echo "[WARN] Failed to resize physical volume, may not be LVM"
    EXIT_CODE=1
  }
  echo "[INFO] Extending logical volume $LV_PATH..."
  lvextend -l +100%FREE "$LV_PATH" || {
    echo "[WARN] Failed to extend logical volume"
    EXIT_CODE=1
  }

  # Resize filesystem
  echo "[INFO] Resizing filesystem..."
  FSTYPE=$(lsblk -no FSTYPE "$LV_PATH" 2>/dev/null)
  if [ "$FSTYPE" = "xfs" ]; then
    xfs_growfs / || {
      echo "[ERROR] Failed to grow XFS filesystem"
      EXIT_CODE=1
    }
  elif [ "$FSTYPE" = "ext4" ]; then
    resize2fs "$LV_PATH" || {
      echo "[ERROR] Failed to resize ext4 filesystem"
      EXIT_CODE=1
    }
  else
    echo "[WARN] Unsupported filesystem type: $FSTYPE"
    EXIT_CODE=1
  fi
  echo "[INFO] Root filesystem expansion completed"
  df -h /
}

# Main function to handle command-line arguments
main() {
  # Check for root privileges
  if [ $EUID -ne 0 ]; then
    echo "[ERROR] This script must be run as root"
    exit 1
  fi

  # Check if a command was provided
  [ $# -eq 0 ] && usage

  # Only call detect_os for commands that need it (excluding expand, autodisk, disk)
  case "$1" in
    all|init|update|mirror|security|time|ssh|optimize|clean)
      detect_os
      check_memory
      ;;
    expand|autodisk|disk)
      # Handled within respective functions
      ;;
    *)
      echo "[ERROR] Invalid command: $1"
      usage
      ;;
  esac

  case "$1" in
    all)
      configure_base_mirrors || true
      install_pkgs || true
      disable_security || true
      set_timezone_ntp || true
      configure_ssh || true
      apply_sysctl_limits || true
      disable_thp_numa || true
      clean_cache || true
      ;;
    init)
      configure_base_mirrors || true
      install_pkgs || true
      disable_security || true
      set_timezone_ntp || true
      configure_ssh || true
      apply_sysctl_limits || true
      disable_thp_numa || true
      clean_cache || true
      ;;
    update)
      install_pkgs
      ;;
    mirror)
      configure_base_mirrors
      # Also configure EPEL if epel-release is already installed
      configure_epel_mirror || true
      ;;
    security)
      disable_security
      ;;
    time)
      set_timezone_ntp
      ;;
    ssh)
      configure_ssh
      ;;
    optimize)
      apply_sysctl_limits
      disable_thp_numa
      ;;
    disk)
      detect_os # Needed for package manager in ensure_lvm_installed
      setup_disk_lvm
      ;;
    autodisk)
      detect_os # Needed for package manager in ensure_lvm_installed
      auto_format_disks
      ;;
    expand)
      expand_root_lvm
      ;;
    clean)
      clean_cache
      ;;
  esac

  # Return exit code based on task outcomes
  if [ $EXIT_CODE -ne 0 ]; then
    echo "[WARN] Some tasks failed, check logs for details"
  else
    echo "[INFO] All tasks completed successfully"
  fi

  # Prompt for reboot (skip in non-interactive mode)
  if [ -t 0 ]; then
    echo "[INFO] Initialization completed. A reboot may be required to apply some changes."
    read -p "Reboot system now? (y/n): " REBOOT
    if [ "$REBOOT" = "y" ]; then
      reboot
    fi
  fi
  exit $EXIT_CODE
}

# Execute main function with provided arguments
main "$@"