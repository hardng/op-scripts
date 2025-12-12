#!/bin/bash

# Universal Docker & Docker Compose Installation Script
# Supports: Ubuntu/Debian and Rocky/CentOS series
# Author: System Administrator
# Version: 1.0

set -e

# Color codes for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

# Global variables
SCRIPT_NAME=$(basename "$0")
DOCKER_COMPOSE_VERSION="v2.24.5"
LOG_FILE="/tmp/docker_install_$(date +%Y%m%d_%H%M%S).log"

# Function to display usage information
usage() {
    cat << EOF
${BLUE}Usage: $SCRIPT_NAME [OPTIONS]${NC}

${YELLOW}Description:${NC}
  Universal script to install Docker and Docker Compose on Ubuntu/Debian and Rocky/CentOS systems

${YELLOW}Options:${NC}
  -h, --help              Show this help message and exit
  -d, --docker-only       Install Docker only (skip Docker Compose)
  -c, --compose-only      Install Docker Compose only (requires Docker to be installed)
  -v, --version VERSION   Specify Docker Compose version (default: $DOCKER_COMPOSE_VERSION)
  -u, --user USERNAME     Add specified user to docker group (default: current user)
  --uninstall             Uninstall Docker and Docker Compose
  --dry-run               Show what would be installed without actually installing

${YELLOW}Examples:${NC}
  $SCRIPT_NAME                    # Install both Docker and Docker Compose
  $SCRIPT_NAME -d                 # Install Docker only
  $SCRIPT_NAME -c                 # Install Docker Compose only
  $SCRIPT_NAME -v v2.20.0         # Install with specific Docker Compose version
  $SCRIPT_NAME -u myuser          # Add 'myuser' to docker group
  $SCRIPT_NAME --uninstall        # Uninstall Docker and Docker Compose

${YELLOW}Supported Systems:${NC}
  - Ubuntu 18.04, 20.04, 22.04, 24.04
  - Debian 9, 10, 11, 12
  - CentOS 7, 8, 9
  - Rocky Linux 8, 9
  - AlmaLinux 8, 9
  - Amazon Linux 2023

EOF
    exit 0
}

# Function to log messages
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        "INFO")
            echo -e "${GREEN}[INFO]${NC} $message" | tee -a "$LOG_FILE"
            ;;
        "WARN")
            echo -e "${YELLOW}[WARN]${NC} $message" | tee -a "$LOG_FILE"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} $message" | tee -a "$LOG_FILE"
            ;;
        "DEBUG")
            echo -e "${BLUE}[DEBUG]${NC} $message" | tee -a "$LOG_FILE"
            ;;
    esac
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log "WARN" "Running as root user. Consider running as a regular user with sudo privileges."
    fi
}

# Function to detect operating system
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
        OS_LIKE=$ID_LIKE
        DISTRO_ID=$ID
    else
        log "ERROR" "Cannot detect operating system. /etc/os-release not found."
        exit 1
    fi
    
    log "INFO" "Detected OS: $OS $VER"
    
    # Determine package manager and OS family
    case $DISTRO_ID in
        ubuntu|debian)
            OS_FAMILY="debian"
            PKG_MANAGER="apt"
            ;;
        centos|rhel|rocky|almalinux|amzn)
            OS_FAMILY="rhel"
            PKG_MANAGER="yum"
            # Use dnf for newer versions (CentOS 8+, Rocky 8+, AlmaLinux 8+)
            if [[ ( "$DISTRO_ID" == "centos" && "${VER%%.*}" -ge "8" ) ]] || \
               [[ ( "$DISTRO_ID" == "rocky" && "${VER%%.*}" -ge "8" ) ]] || \
               [[ ( "$DISTRO_ID" == "almalinux" && "${VER%%.*}" -ge "8" ) ]] || \
               [[ ( "$DISTRO_ID" == "amzn" && "${VER%%.*}" -ge "8" ) ]] || \
               [[ "$DISTRO_ID" == "rhel" && "${VER%%.*}" -ge "8" ]]; then
                if command -v dnf &> /dev/null; then
                    PKG_MANAGER="dnf"
                fi
            fi
            ;;
        *)
            log "ERROR" "Unsupported operating system: $DISTRO_ID"
            exit 1
            ;;
    esac
    
    log "INFO" "OS Family: $OS_FAMILY, Package Manager: $PKG_MANAGER"
}

# Function to check system requirements
check_requirements() {
    log "INFO" "Checking system requirements..."
    
    # Check architecture
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64)
            ARCH="arm64"
            ;;
        armv7l)
            ARCH="armhf"
            ;;
        *)
            log "ERROR" "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
    
    log "INFO" "Architecture: $ARCH"
    
    # Check available disk space (require at least 1GB)
    AVAILABLE_SPACE=$(df /var/lib 2>/dev/null | awk 'NR==2 {print $4}' || echo "1048576")
    if [[ $AVAILABLE_SPACE -lt 1048576 ]]; then
        log "WARN" "Low disk space detected. At least 1GB free space is recommended."
    fi
    
    # Check internet connectivity
    # Check internet connectivity
    log "INFO" "Checking internet connectivity..."
    local connectivity_ok=false
    local check_hosts=("google.com" "1.1.1.1" "baidu.com" "microsoft.com")
    
    # Method 1: Ping check
    for host in "${check_hosts[@]}"; do
        if ping -c 1 -W 2 "$host" &> /dev/null; then
            log "INFO" "Connectivity confirmed via ping to $host"
            connectivity_ok=true
            break
        fi
    done
    
    # Method 2: TCP Port 80 check (if ping fails)
    if [[ $connectivity_ok == false ]]; then
        log "INFO" "Ping failed, trying TCP port 80 connection..."
        for host in "google.com" "www.baidu.com" "www.microsoft.com"; do
            if timeout 3 bash -c "echo > /dev/tcp/$host/80" 2>/dev/null; then
                log "INFO" "Connectivity confirmed via TCP/80 to $host"
                connectivity_ok=true
                break
            fi
        done
    fi

    if [[ $connectivity_ok == false ]]; then
        log "ERROR" "No internet connection detected. Tried ping and TCP/80 to multiple global hosts."
        exit 1
    fi
    
    log "INFO" "System requirements check completed successfully."
}

# Function to update package repositories
update_packages() {
    log "INFO" "Updating package repositories..."
    
    case $OS_FAMILY in
        debian)
            sudo apt-get update -y
            ;;
        rhel)
            # Only refresh package cache, don't update all packages
            if [[ $PKG_MANAGER == "dnf" ]]; then
                sudo dnf makecache
            else
                sudo yum makecache fast
            fi
            ;;

    esac
    
    log "INFO" "Package repositories updated successfully."
}

# Function to install prerequisites
install_prerequisites() {
    log "INFO" "Installing prerequisites..."
    
    case $OS_FAMILY in
        debian)
            sudo apt-get install -y \
                apt-transport-https \
                ca-certificates \
                curl \
                gnupg \
                lsb-release \
                software-properties-common
            ;;
        rhel)
            sudo $PKG_MANAGER install -y \
                device-mapper-persistent-data \
                lvm2 \
                curl \
                ca-certificates
            ;;
        amzn)
            sudo $PKG_MANAGER install -y \
                device-mapper-persistent-data \
                lvm2 \
                ca-certificates
            ;;        
    esac
    
    log "INFO" "Prerequisites installed successfully."
}

# Function to install Docker
install_docker() {
    log "INFO" "Installing Docker..."
    
    case $OS_FAMILY in
        debian)
            # Add Docker's official GPG key
            curl -fsSL https://download.docker.com/linux/$DISTRO_ID/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            
            # Add Docker repository
            echo "deb [arch=$ARCH signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$DISTRO_ID $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            # Update package index
            sudo apt-get update -y
            
            # Install Docker
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        rhel)
            # Add Docker repository
            # Create repository file manually for better compatibility
            sudo tee /etc/yum.repos.d/docker-ce.repo > /dev/null <<EOF
[docker-ce-stable]
name=Docker CE Stable - \$basearch
baseurl=https://download.docker.com/linux/centos/\$releasever/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg

[docker-ce-stable-debuginfo]
name=Docker CE Stable - Debuginfo \$basearch
baseurl=https://download.docker.com/linux/centos/\$releasever/debug-\$basearch/stable
enabled=0
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg

[docker-ce-stable-source]
name=Docker CE Stable - Sources
baseurl=https://download.docker.com/linux/centos/\$releasever/source/stable
enabled=0
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg
EOF
            
            # Install Docker
            if [[ $PKG_MANAGER == "dnf" ]]; then
                sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            else
                sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            fi
            ;;
    esac
    
    # Start and enable Docker service
    sudo systemctl start docker
    sudo systemctl enable docker
    
    log "INFO" "Docker installed and started successfully."
}

# Function to install Docker Compose (standalone)
install_docker_compose() {
    log "INFO" "Installing Docker Compose $DOCKER_COMPOSE_VERSION..."
    
    # Download Docker Compose binary
    sudo curl -L "https://github.com/docker/compose/releases/download/$DOCKER_COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    
    # Make it executable
    sudo chmod +x /usr/local/bin/docker-compose
    
    # Create symlink for convenience
    sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
    
    # Verify installation
    if docker-compose --version &> /dev/null; then
        log "INFO" "Docker Compose installed successfully: $(docker-compose --version)"
    else
        log "ERROR" "Docker Compose installation failed."
        exit 1
    fi
}

# Function to add user to docker group
add_user_to_docker_group() {
    local username=${1:-$USER}
    
    log "INFO" "Adding user '$username' to docker group..."
    
    # Create docker group if it doesn't exist
    if ! getent group docker > /dev/null 2>&1; then
        sudo groupadd docker
    fi
    
    # Add user to docker group
    sudo usermod -aG docker "$username"
    
    log "INFO" "User '$username' added to docker group. Please log out and back in for changes to take effect."
}

# Function to verify installation
verify_installation() {
    log "INFO" "Verifying installation..."
    
    # Check Docker
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version)
        log "INFO" "Docker installed: $DOCKER_VERSION"
        
        # Test Docker with hello-world (if not dry run)
        if [[ $DRY_RUN != true ]]; then
            if sudo docker run --rm hello-world &> /dev/null; then
                log "INFO" "Docker is working correctly."
            else
                log "WARN" "Docker installation may have issues. Try running 'sudo docker run hello-world' manually."
            fi
        fi
    else
        log "ERROR" "Docker installation verification failed."
        return 1
    fi
    
    # Check Docker Compose
    if [[ $COMPOSE_ONLY != true ]] && [[ $DOCKER_ONLY != true ]]; then
        if command -v docker-compose &> /dev/null; then
            COMPOSE_VERSION=$(docker-compose --version)
            log "INFO" "Docker Compose installed: $COMPOSE_VERSION"
        else
            log "ERROR" "Docker Compose installation verification failed."
            return 1
        fi
    fi
    
    log "INFO" "Installation verification completed successfully."
}

# Function to uninstall Docker and Docker Compose
uninstall_docker() {
    log "INFO" "Uninstalling Docker and Docker Compose..."
    
    # Stop Docker service
    sudo systemctl stop docker || true
    sudo systemctl disable docker || true
    
    case $OS_FAMILY in
        debian)
            # Remove Docker packages
            sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            sudo apt-get autoremove -y
            ;;
        rhel)
            # Remove Docker packages
            sudo $PKG_MANAGER remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
    esac
    
    # Remove Docker Compose standalone
    sudo rm -f /usr/local/bin/docker-compose /usr/bin/docker-compose
    
    # Remove Docker data (optional - ask user)
    read -p "Do you want to remove Docker data directories? This will delete all containers, images, and volumes. [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo rm -rf /var/lib/docker
        sudo rm -rf /var/lib/containerd
        log "INFO" "Docker data directories removed."
    fi
    
    # Remove Docker group
    sudo groupdel docker 2>/dev/null || true
    
    log "INFO" "Docker and Docker Compose uninstalled successfully."
}

# Function to display installation summary
show_summary() {
    echo ""
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}  Installation Summary${NC}"
    echo -e "${GREEN}================================${NC}"
    echo -e "OS: ${BLUE}$OS $VER${NC}"
    echo -e "Architecture: ${BLUE}$ARCH${NC}"
    if command -v docker &> /dev/null; then
        echo -e "Docker: ${GREEN}$(docker --version)${NC}"
    fi
    if command -v docker-compose &> /dev/null; then
        echo -e "Docker Compose: ${GREEN}$(docker-compose --version)${NC}"
    fi
    echo -e "Log file: ${BLUE}$LOG_FILE${NC}"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "1. Log out and back in to use Docker without sudo"
    echo "2. Test your installation: docker run hello-world"
    echo "3. Start using Docker and Docker Compose!"
    echo ""
}

# Main function
main() {
    # Initialize variables
    DOCKER_ONLY=false
    COMPOSE_ONLY=false
    UNINSTALL=false
    DRY_RUN=false
    TARGET_USER=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                ;;
            -d|--docker-only)
                DOCKER_ONLY=true
                shift
                ;;
            -c|--compose-only)
                COMPOSE_ONLY=true
                shift
                ;;
            -v|--version)
                DOCKER_COMPOSE_VERSION="$2"
                shift 2
                ;;
            -u|--user)
                TARGET_USER="$2"
                shift 2
                ;;
            --uninstall)
                UNINSTALL=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                usage
                ;;
        esac
    done
    
    # Validate mutually exclusive options
    if [[ $DOCKER_ONLY == true && $COMPOSE_ONLY == true ]]; then
        log "ERROR" "Cannot use --docker-only and --compose-only together."
        exit 1
    fi
    
    # Start installation process
    log "INFO" "Starting Docker installation script..."
    log "INFO" "Log file: $LOG_FILE"
    
    # Handle uninstall
    if [[ $UNINSTALL == true ]]; then
        uninstall_docker
        exit 0
    fi
    
    # Check system and prerequisites
    check_root
    detect_os
    check_requirements
    
    # Dry run mode
    if [[ $DRY_RUN == true ]]; then
        log "INFO" "DRY RUN MODE - No actual installation will be performed"
        log "INFO" "Would install on: $OS $VER ($OS_FAMILY)"
        log "INFO" "Package manager: $PKG_MANAGER"
        if [[ $DOCKER_ONLY != true ]]; then
            log "INFO" "Would install Docker Compose version: $DOCKER_COMPOSE_VERSION"
        fi
        exit 0
    fi
    
    # Update packages and install prerequisites
    update_packages
    install_prerequisites
    
    # Install Docker (unless compose-only)
    if [[ $COMPOSE_ONLY != true ]]; then
        install_docker
        
        # Add user to docker group
        TARGET_USER=${TARGET_USER:-$USER}
        add_user_to_docker_group "$TARGET_USER"
    fi
    
    # Install Docker Compose (unless docker-only)
    if [[ $DOCKER_ONLY != true ]]; then
        # Check if Docker is available for compose-only installation
        if [[ $COMPOSE_ONLY == true ]] && ! command -v docker &> /dev/null; then
            log "ERROR" "Docker must be installed before installing Docker Compose."
            exit 1
        fi
        install_docker_compose
    fi
    
    # Verify installation
    verify_installation
    
    # Show summary
    show_summary
    
    log "INFO" "Installation completed successfully!"
}

# Run main function with all arguments
main "$@"