#!/bin/bash
####################################################################################
#  Cross-Linux Initialization Script - CentOS7+/Rocky/Alma & Debian/Ubuntu         #
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
  all       Perform all configurations (install packages, security, timezone, SSH, optimization, expand partition)
  update    Install or update base packages only
  security  Disable firewall and SELinux (RHEL) or ufw (Debian)
  time      Set timezone to Asia/Shanghai and enable NTP
  ssh       Configure SSH (disable UseDNS)
  optimize  Optimize system parameters (sysctl and transparent huge pages/NUMA)
  expand    Expand root partition (LVM)

Examples:
  $0 all      # Perform all initialization tasks
  $0 expand   # Expand root LVM partition only
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

# Install base packages
install_pkgs() {
  echo "[INFO] Installing base packages..."
  if [ "$OS_FAMILY" = "rhel" ]; then
    $PKG_MGR install -y epel-release || {
      echo "[WARN] Failed to install epel-release, may already be installed or network issue"
      EXIT_CODE=1
    }
    $PKG_MGR install -y unzip vim wget curl net-tools \
      htop git bash-completion lvm2 cloud-utils-growpart parted xfsprogs e2fsprogs \
      iftop traceroute nmap lsof || {
      echo "[ERROR] Failed to install packages"
      EXIT_CODE=1
    }
  elif [ "$OS_FAMILY" = "debian" ]; then
    $PKG_MGR update -y || {
      echo "[ERROR] Failed to update package sources"
      EXIT_CODE=1
    }
    $PKG_MGR install -y unzip vim wget curl net-tools \
      htop git bash-completion lvm2 cloud-guest-utils parted xfsprogs e2fsprogs \
      iftop traceroute nmap lsof || {
      echo "[ERROR] Failed to install packages"
      EXIT_CODE=1
    }
  fi
}

# Disable firewall and SELinux/ufw
disable_security() {
  echo "[INFO] Disabling firewall..."
  if [ "$OS_FAMILY" = "rhel" ]; then
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
  elif [ "$OS_FAMILY" = "debian" ]; then
    systemctl disable --now ufw || {
      echo "[WARN] Failed to disable ufw, may not be installed"
      EXIT_CODE=1
    }
  fi
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

# Apply system optimizations (sysctl and limits)
apply_sysctl_limits() {
  echo "[INFO] Applying system optimizations..."
  cat <<EOF >/etc/security/limits.d/99-custom.conf
* soft nofile 1024000
* hard nofile 1024000
* soft nproc 1024000
* hard nproc 1024000
EOF
  [ $? -eq 0 ] || {
    echo "[ERROR] Failed to write limits configuration"
    EXIT_CODE=1
  }

  cat <<EOF >/etc/sysctl.d/99-custom.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
vm.swappiness = 0
fs.file-max = 2097152
net.core.somaxconn = 1024
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
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

  # Install growpart if not available
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

  # Detect root device
  ROOT_DEV=$(df / | awk 'NR==2 {print $1}')
  if [ -z "$ROOT_DEV" ]; then
    echo "[ERROR] Unable to detect root device"
    EXIT_CODE=1
    return
  fi

  # Extract disk and partition number
  DISK=$(lsblk -no pkname "$ROOT_DEV" 2>/dev/null)
  PART_NUM=$(echo "$ROOT_DEV" | grep -o '[0-9]*$' || true)
  if [ -z "$DISK" ] || [ -z "$PART_NUM" ]; then
    echo "[ERROR] Unable to determine disk or partition number"
    EXIT_CODE=1
    return
  fi

  # Expand partition, physical volume, and logical volume
  growpart /dev/$DISK $PART_NUM || {
    echo "[WARN] Failed to grow partition, may already be extended"
    EXIT_CODE=1
  }
  pvresize "$ROOT_DEV" || {
    echo "[WARN] Failed to resize physical volume, may not be LVM"
    EXIT_CODE=1
  }
  lvextend -l +100%FREE "$ROOT_DEV" || {
    echo "[WARN] Failed to extend logical volume"
    EXIT_CODE=1
  }

  # Resize filesystem
  FSTYPE=$(lsblk -no FSTYPE "$ROOT_DEV" 2>/dev/null)
  if [ "$FSTYPE" = "xfs" ]; then
    xfs_growfs / || {
      echo "[ERROR] Failed to grow XFS filesystem"
      EXIT_CODE=1
    }
  elif [ "$FSTYPE" = "ext4" ]; then
    resize2fs "$ROOT_DEV" || {
      echo "[ERROR] Failed to resize ext4 filesystem"
      EXIT_CODE=1
    }
  else
    echo "[WARN] Unsupported filesystem type: $FSTYPE"
    EXIT_CODE=1
  fi
}

# Main function to handle command-line arguments
main() {
  # Check if a command was provided
  [ $# -eq 0 ] && usage

  # Only call detect_os for commands that need it (excluding expand)
  case "$1" in
    all|update|security|time|ssh|optimize)
      detect_os
      ;;
    expand)
      # No need to call detect_os, handled in expand_root_lvm
      ;;
    *)
      echo "[ERROR] Invalid command: $1"
      usage
      ;;
  esac

  case "$1" in
    all)
      install_pkgs
      disable_security
      set_timezone_ntp
      configure_ssh
      apply_sysctl_limits
      disable_thp_numa
      ;;
    update)
      install_pkgs
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
    expand)
      expand_root_lvm
      ;;
  esac

  # Return exit code based on task outcomes
  if [ $EXIT_CODE -ne 0 ]; then
    echo "[WARN] Some tasks failed, check logs for details"
  else
    echo "[INFO] All tasks completed successfully"
  fi
  exit $EXIT_CODE
}

# Execute main function with provided arguments
main "$@"