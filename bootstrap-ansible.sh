#!/usr/bin/env bash
#
# bootstrap-ansible.sh
# Advanced bootstrap script for Debian/Ubuntu servers
# Prepares server for Ansible management with optional Docker and monitoring
#
# Usage:
#   # Basic bootstrap (no Docker, no monitoring)
#   curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/bootstrap-ansible.sh | bash
#
#   # With Docker
#   curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/bootstrap-ansible.sh | bash -s -- --docker
#
#   # With Docker and monitoring
#   curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/bootstrap-ansible.sh | bash -s -- --docker --monitoring
#
#   # Custom SSH key
#   curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/bootstrap-ansible.sh | bash -s -- --ssh-key "ssh-ed25519 AAA..."
#

set -euo pipefail

# --- Configuration ---
ANSIBLE_USER="${ANSIBLE_USER:-ansible}"
DEFAULT_SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICd1ZjjeqniD4m7F+AapwEablHCNB8xi4NMKEw6Q0rO8 openclaw-ansible"
SSH_PUBKEY="${DEFAULT_SSH_PUBKEY}"
INSTALL_DOCKER=false
INSTALL_MONITORING=false
MON01_IP="${MON01_IP:-192.168.1.56}"
LOKI_URL="${LOKI_URL:-http://192.168.1.56:3100/loki/api/v1/push}"

# Base packages (matching common_base role)
BASE_PACKAGES="sudo curl vim git python3 python3-apt openssh-client ca-certificates gnupg lsb-release"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --docker)
            INSTALL_DOCKER=true
            shift
            ;;
        --monitoring)
            INSTALL_MONITORING=true
            shift
            ;;
        --mon01-ip)
            MON01_IP="$2"
            shift 2
            ;;
        --ssh-key)
            SSH_PUBKEY="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--docker] [--monitoring] [--mon01-ip IP] [--ssh-key KEY]"
            exit 1
            ;;
    esac
done

# --- Helper functions ---
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $*"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_NAME="$ID"
        OS_VERSION="$VERSION_ID"
        OS_CODENAME="$VERSION_CODENAME"
        log_info "Detected OS: $PRETTY_NAME"
    else
        log_error "Cannot detect OS. Only Debian/Ubuntu is supported."
        exit 1
    fi

    if [[ ! "$OS_NAME" =~ ^(debian|ubuntu)$ ]]; then
        log_error "Unsupported OS: $OS_NAME. Only Debian and Ubuntu are supported."
        exit 1
    fi
}

detect_virtualization() {
    local virt_type="physical"

    # Check for LXC
    if [[ -f /proc/1/environ ]] && grep -qa container=lxc /proc/1/environ; then
        virt_type="lxc"
    elif systemd-detect-virt --container &>/dev/null; then
        virt_type="lxc"
    # Check for KVM/QEMU
    elif systemd-detect-virt --vm &>/dev/null; then
        virt_type="kvm"
    fi

    VIRT_TYPE="$virt_type"
    log_info "Virtualization type: $VIRT_TYPE"
}

cleanup_apt_repos() {
    log_step "Cleaning up problematic APT repositories..."

    # Patterns to remove (matching your Ansible config)
    local patterns=(
        "packages.wazuh.com"
        "repos.influxdata.com"
    )

    local cleaned=0
    for pattern in "${patterns[@]}"; do
        for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
            if [[ -f "$file" ]] && grep -q "$pattern" "$file" 2>/dev/null; then
                log_info "Removing '$pattern' from $file"
                cp -n "$file" "${file}.bak" 2>/dev/null || true
                sed -i "/$pattern/d" "$file"
                cleaned=1
            fi
        done
    done

    if [[ $cleaned -eq 1 ]]; then
        log_info "Repositories cleaned, updating cache..."
        apt-get update -qq 2>/dev/null || log_warn "APT cache update failed (non-fatal)"
    fi
}

install_base_packages() {
    log_step "Installing base packages..."
    export DEBIAN_FRONTEND=noninteractive

    log_info "Updating package cache..."
    apt-get update -qq

    log_info "Installing: $BASE_PACKAGES"
    apt-get install -y -qq $BASE_PACKAGES

    log_info "Running autoremove and autoclean..."
    apt-get autoremove -y -qq
    apt-get autoclean -qq
}

setup_virtualization_specific() {
    log_step "Configuring virtualization-specific settings..."

    case "$VIRT_TYPE" in
        lxc)
            log_info "LXC container detected - removing cloud-init..."
            apt-get remove -y -qq cloud-init 2>/dev/null || log_warn "cloud-init not installed"
            apt-get purge -y -qq cloud-init 2>/dev/null || true
            rm -rf /etc/cloud /var/lib/cloud 2>/dev/null || true
            ;;
        kvm)
            log_info "KVM/QEMU VM detected - installing qemu-guest-agent..."
            apt-get install -y -qq qemu-guest-agent
            systemctl enable qemu-guest-agent 2>/dev/null || true
            systemctl start qemu-guest-agent 2>/dev/null || true
            ;;
        *)
            log_info "Physical or unknown virtualization - skipping specific setup"
            ;;
    esac
}

create_ansible_user() {
    log_step "Setting up ansible user..."

    if id "$ANSIBLE_USER" &>/dev/null; then
        log_warn "User '$ANSIBLE_USER' already exists"
    else
        log_info "Creating user '$ANSIBLE_USER'..."
        useradd -m -s /bin/bash -G sudo "$ANSIBLE_USER"
    fi

    # Ensure user is in sudo group
    usermod -aG sudo "$ANSIBLE_USER" 2>/dev/null || true
}

setup_passwordless_sudo() {
    local sudoers_file="/etc/sudoers.d/90-${ANSIBLE_USER}"

    log_info "Setting up passwordless sudo..."

    mkdir -p /etc/sudoers.d
    chmod 755 /etc/sudoers.d

    echo "${ANSIBLE_USER} ALL=(ALL) NOPASSWD:ALL" > "$sudoers_file"
    chmod 0440 "$sudoers_file"

    if ! visudo -cf "$sudoers_file"; then
        log_error "Invalid sudoers file syntax!"
        rm -f "$sudoers_file"
        exit 1
    fi
}

install_ssh_key() {
    local user_home
    user_home=$(eval echo "~$ANSIBLE_USER")
    local ssh_dir="${user_home}/.ssh"
    local authorized_keys="${ssh_dir}/authorized_keys"

    log_step "Installing SSH key..."

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    if [[ -f "$authorized_keys" ]] && grep -qF "$SSH_PUBKEY" "$authorized_keys"; then
        log_warn "SSH key already present"
    else
        echo "$SSH_PUBKEY" >> "$authorized_keys"
        chmod 600 "$authorized_keys"
        log_info "SSH key installed"
    fi

    chown -R "${ANSIBLE_USER}:${ANSIBLE_USER}" "$ssh_dir"
}

setup_ssh_config() {
    local user_home
    user_home=$(eval echo "~$ANSIBLE_USER")
    local ssh_dir="${user_home}/.ssh"
    local ssh_config="${ssh_dir}/config"

    log_step "Configuring SSH client..."

    mkdir -p "$ssh_dir"

    cat > "$ssh_config" <<'EOF'
# GitHub via SSH over HTTPS (port 443)
Host github.com
    HostName ssh.github.com
    User git
    Port 443
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new

# Default settings
Host *
    ServerAliveInterval 60
    ServerAliveCountMax 3
    IdentitiesOnly yes
EOF

    chmod 600 "$ssh_config"
    chown "${ANSIBLE_USER}:${ANSIBLE_USER}" "$ssh_config"
}

optimize_ssh_daemon() {
    log_step "Enabling SSH with root and password access..."

    local sshd_custom="/etc/ssh/sshd_config.d/99-ansible-bootstrap.conf"

    if [[ -d "/etc/ssh/sshd_config.d" ]]; then
        cat > "$sshd_custom" <<EOF
# Ansible bootstrap - enable root and password access
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
PermitEmptyPasswords no
UsePAM yes
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

        chmod 644 "$sshd_custom"

        if sshd -t 2>/dev/null; then
            systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
            log_info "SSH daemon configured: root login + password auth enabled"
        else
            log_warn "SSH config test failed, reverting"
            rm -f "$sshd_custom"
        fi
    else
        # Fallback for older systems without sshd_config.d
        log_info "No sshd_config.d directory, configuring main sshd_config..."

        # Backup original config
        cp -n /etc/ssh/sshd_config /etc/ssh/sshd_config.backup 2>/dev/null || true

        # Enable root login if disabled
        if grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then
            sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        else
            echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
        fi

        # Enable password authentication if disabled
        if grep -q "^PasswordAuthentication" /etc/ssh/sshd_config; then
            sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        else
            echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
        fi

        if sshd -t 2>/dev/null; then
            systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
            log_info "SSH daemon configured (fallback method)"
        else
            log_error "SSH config test failed!"
        fi
    fi
}

install_docker() {
    if [[ "$INSTALL_DOCKER" != "true" ]]; then
        return
    fi

    log_step "Installing Docker CE..."

    # Ensure keyring directory
    mkdir -p /etc/apt/keyrings

    # Install Docker GPG key
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        log_info "Adding Docker GPG key..."
        curl -fsSL "https://download.docker.com/linux/${OS_NAME}/gpg" | \
            gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    # Detect architecture
    local arch
    arch=$(dpkg --print-architecture)

    # Configure Docker repository
    log_info "Configuring Docker repository..."
    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_NAME} ${OS_CODENAME} stable
EOF

    # Install Docker
    log_info "Installing Docker packages..."
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add ansible user to docker group
    usermod -aG docker "$ANSIBLE_USER"

    # Enable and start Docker
    systemctl enable docker
    systemctl start docker

    log_info "Docker CE installed successfully"
}

install_monitoring() {
    if [[ "$INSTALL_MONITORING" != "true" ]]; then
        return
    fi

    log_step "Installing monitoring stack..."

    # Docker is required for monitoring
    if ! command -v docker &>/dev/null; then
        log_error "Docker is required for monitoring. Use --docker flag."
        return
    fi

    local base_dir="/opt/monitoring"
    mkdir -p "$base_dir/promtail/positions"

    # Create docker-compose.yml
    log_info "Creating monitoring stack..."
    cat > "$base_dir/docker-compose.yml" <<EOF
version: '3.8'

services:
  node-exporter:
    image: prom/node-exporter:v1.8.2
    container_name: node-exporter
    restart: unless-stopped
    network_mode: host
    pid: host
    command:
      - '--path.rootfs=/host'
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
    volumes:
      - /:/host:ro,rslave

  promtail:
    image: grafana/promtail:3.1.1
    container_name: promtail
    restart: unless-stopped
    network_mode: host
    volumes:
      - /var/log:/var/log:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - ./promtail/promtail-config.yaml:/etc/promtail/config.yml:ro
      - ./promtail/positions:/tmp/positions
    command: -config.file=/etc/promtail/config.yml
EOF

    # Create promtail config
    local hostname
    hostname=$(hostname)

    cat > "$base_dir/promtail/promtail-config.yaml" <<EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions/positions.yaml

clients:
  - url: ${LOKI_URL}

scrape_configs:
  - job_name: system
    static_configs:
      - targets:
          - localhost
        labels:
          job: varlogs
          host: ${hostname}
          __path__: /var/log/*log

  - job_name: journal
    journal:
      json: false
      max_age: 12h
      path: /var/log/journal
      labels:
        job: systemd-journal
        host: ${hostname}
EOF

    # Setup rsyslog forwarding
    log_info "Configuring rsyslog..."

    # Install rsyslog if not present
    apt-get install -y -qq rsyslog

    # Create spool directory
    mkdir -p /var/spool/rsyslog
    chmod 750 /var/spool/rsyslog

    # Configure rsyslog
    cat > /etc/rsyslog.conf <<'EOF'
module(load="imjournal"
      StateFile="imjournal.state"
      PersistStateInterval="1000")

module(load="impstats" interval="10" severity="7"
      log.file="/var/log/rsyslog-stats.log")

$FileOwner root
$FileGroup adm
$FileCreateMode 0640
$DirCreateMode 0755
$Umask 0022
$WorkDirectory /var/spool/rsyslog

*.*;auth,authpriv.none          -/var/log/syslog
auth,authpriv.*                 /var/log/auth.log
cron.*                          -/var/log/cron.log
kern.*                          -/var/log/kern.log
mail.*                          -/var/log/mail.log
user.*                          -/var/log/user.log

*.emerg                         :omusrmsg:*

$IncludeConfig /etc/rsyslog.d/*.conf
EOF

    # Configure forwarding to mon-01
    cat > /etc/rsyslog.d/40-forward-to-mon01.conf <<EOF
*.* action(
  type="omfwd"
  target="${MON01_IP}"
  port="1514"
  protocol="tcp"
  Template="RSYSLOG_SyslogProtocol23Format"
  keepalive="on"
  action.resumeRetryCount="-1"
  action.resumeInterval="30"
  action.reportSuspension="on"
  action.reportSuspensionContinuation="on"
  queue.type="LinkedList"
  queue.size="100000"
  queue.spoolDirectory="/var/spool/rsyslog"
  queue.filename="omfwd_mon01"
  queue.maxdiskspace="1g"
  queue.saveonshutdown="on"
)
EOF

    # Remove old config if exists
    rm -f /etc/rsyslog.d/90-forward-to-mon01.conf

    # Restart rsyslog
    systemctl enable rsyslog
    systemctl restart rsyslog

    # Allow unprivileged port binding for promtail
    cat > /etc/sysctl.d/99-promtail.conf <<EOF
net.ipv4.ip_unprivileged_port_start = 0
EOF
    sysctl -p /etc/sysctl.d/99-promtail.conf 2>/dev/null || true

    # Start monitoring stack
    log_info "Starting monitoring containers..."
    cd "$base_dir"
    docker compose pull -q
    docker compose up -d

    log_info "Monitoring stack installed and running"
    log_info "  - Node Exporter: http://$(hostname -I | awk '{print $1}'):9100/metrics"
    log_info "  - Promtail: http://$(hostname -I | awk '{print $1}'):9080/ready"
    log_info "  - Rsyslog forwarding to: ${MON01_IP}:1514"
}

print_summary() {
    local user_home
    user_home=$(eval echo "~$ANSIBLE_USER")
    local ip_addr
    ip_addr=$(hostname -I | awk '{print $1}')
    local hostname
    hostname=$(hostname)

    echo ""
    echo "=========================================="
    log_info "Bootstrap completed successfully!"
    echo "=========================================="
    echo ""
    echo "  Hostname:           $hostname"
    echo "  IP Address:         $ip_addr"
    echo "  Virtualization:     $VIRT_TYPE"
    echo "  OS:                 $OS_NAME $OS_VERSION"
    echo ""
    echo "  Ansible User:       $ANSIBLE_USER"
    echo "  Home Directory:     $user_home"
    echo "  Sudo:               Passwordless"
    echo "  SSH Key:            ✓ Installed"
    echo "  SSH Config:         ✓ GitHub via port 443"
    echo ""
    echo "  Docker:             $(if [[ "$INSTALL_DOCKER" == "true" ]]; then echo "✓ Installed"; else echo "✗ Not installed"; fi)"
    echo "  Monitoring:         $(if [[ "$INSTALL_MONITORING" == "true" ]]; then echo "✓ Installed"; else echo "✗ Not installed"; fi)"
    echo ""
    echo "Next steps:"
    echo ""
    echo "  1. Test SSH access:"
    echo "     ssh ${ANSIBLE_USER}@${ip_addr}"
    echo ""
    echo "  2. Add to inventory (inventories/lab/hosts.yml):"
    echo ""
    echo "     all_hosts:"
    echo "       hosts:"
    echo "         ${hostname}:"
    echo "           ansible_host: ${ip_addr}"
    echo ""

    if [[ "$VIRT_TYPE" == "lxc" ]]; then
        echo "     lxc_hosts:"
        echo "       hosts:"
        echo "         ${hostname}:"
        echo ""
    elif [[ "$VIRT_TYPE" == "kvm" ]]; then
        echo "     vm_hosts:"
        echo "       hosts:"
        echo "         ${hostname}:"
        echo ""
    fi

    if [[ "$INSTALL_DOCKER" == "true" ]]; then
        echo "     docker_hosts:"
        echo "       hosts:"
        echo "         ${hostname}:"
        echo ""
    fi

    if [[ "$INSTALL_MONITORING" == "true" ]]; then
        echo "     monitored_hosts:"
        echo "       hosts:"
        echo "         ${hostname}:"
        echo ""
    fi

    echo "  3. Run Ansible playbooks:"
    echo "     ansible-playbook playbooks/00_sanity.yml --limit ${hostname}"
    echo ""

    if [[ "$INSTALL_DOCKER" != "true" ]]; then
        echo "  💡 Tip: Re-run with --docker to install Docker"
    fi

    if [[ "$INSTALL_MONITORING" != "true" ]]; then
        echo "  💡 Tip: Re-run with --monitoring to install monitoring stack"
    fi

    echo ""
}

# --- Main execution ---
main() {
    echo ""
    log_info "Starting Ansible Advanced Bootstrap"
    echo ""
    echo "  Docker:      $(if [[ "$INSTALL_DOCKER" == "true" ]]; then echo "Yes"; else echo "No"; fi)"
    echo "  Monitoring:  $(if [[ "$INSTALL_MONITORING" == "true" ]]; then echo "Yes"; else echo "No"; fi)"
    echo "  Mon-01 IP:   $MON01_IP"
    echo ""

    check_root
    detect_os
    detect_virtualization
    cleanup_apt_repos
    install_base_packages
    setup_virtualization_specific
    create_ansible_user
    setup_passwordless_sudo
    install_ssh_key
    setup_ssh_config
    optimize_ssh_daemon
    install_docker
    install_monitoring
    print_summary
}

main "$@"
