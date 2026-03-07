#!/usr/bin/env bash
#
# bootstrap-ansible.sh
# Prepares a fresh Debian/Ubuntu server for Ansible management
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/bootstrap-ansible.sh | bash
#   # OR with custom SSH key:
#   curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/bootstrap-ansible.sh | bash -s -- "ssh-ed25519 AAAAC3... user@host"
#

set -euo pipefail

# --- Configuration ---
ANSIBLE_USER="${ANSIBLE_USER:-ansible}"
SSH_PUBKEY="${1:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICd1ZjjeqniD4m7F+AapwEablHCNB8xi4NMKEw6Q0rO8 openclaw-ansible}"
REQUIRED_PACKAGES="sudo curl vim git python3 python3-apt openssh-client"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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

install_packages() {
    log_info "Updating package cache..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    log_info "Installing required packages: $REQUIRED_PACKAGES"
    apt-get install -y -qq $REQUIRED_PACKAGES

    log_info "Running autoremove and autoclean..."
    apt-get autoremove -y -qq
    apt-get autoclean -qq
}

create_ansible_user() {
    if id "$ANSIBLE_USER" &>/dev/null; then
        log_warn "User '$ANSIBLE_USER' already exists, skipping creation."
    else
        log_info "Creating user '$ANSIBLE_USER'..."
        useradd -m -s /bin/bash -G sudo "$ANSIBLE_USER"
    fi

    # Ensure user is in sudo group
    usermod -aG sudo "$ANSIBLE_USER" 2>/dev/null || true
}

setup_passwordless_sudo() {
    local sudoers_file="/etc/sudoers.d/90-${ANSIBLE_USER}"

    log_info "Setting up passwordless sudo for '$ANSIBLE_USER'..."

    # Create sudoers.d directory if it doesn't exist
    mkdir -p /etc/sudoers.d
    chmod 755 /etc/sudoers.d

    # Create sudoers entry
    echo "${ANSIBLE_USER} ALL=(ALL) NOPASSWD:ALL" > "$sudoers_file"
    chmod 0440 "$sudoers_file"

    # Validate syntax
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

    if [[ -z "$SSH_PUBKEY" ]]; then
        log_warn "No SSH public key provided."
        log_warn "Please add your public key manually to: $authorized_keys"
        return
    fi

    log_info "Installing SSH public key for '$ANSIBLE_USER'..."

    # Create .ssh directory
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    # Add key if not already present
    if [[ -f "$authorized_keys" ]] && grep -qF "$SSH_PUBKEY" "$authorized_keys"; then
        log_warn "SSH key already present in authorized_keys"
    else
        echo "$SSH_PUBKEY" >> "$authorized_keys"
        chmod 600 "$authorized_keys"
        log_info "SSH key installed successfully"
    fi

    # Set correct ownership
    chown -R "${ANSIBLE_USER}:${ANSIBLE_USER}" "$ssh_dir"
}

setup_ssh_config() {
    local user_home
    user_home=$(eval echo "~$ANSIBLE_USER")
    local ssh_dir="${user_home}/.ssh"
    local ssh_config="${ssh_dir}/config"

    log_info "Setting up SSH config for GitHub access via port 443..."

    mkdir -p "$ssh_dir"

    # Create SSH config for GitHub over port 443
    cat > "$ssh_config" <<'EOF'
# GitHub via SSH over HTTPS (port 443)
# Useful when port 22 is blocked by firewall
Host github.com
    HostName ssh.github.com
    User git
    Port 443
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new

# Default settings for all hosts
Host *
    ServerAliveInterval 60
    ServerAliveCountMax 3
    IdentitiesOnly yes
EOF

    chmod 600 "$ssh_config"
    chown "${ANSIBLE_USER}:${ANSIBLE_USER}" "$ssh_config"

    log_info "SSH config created at: $ssh_config"
}

cleanup_apt_repos() {
    log_info "Cleaning up problematic APT repositories..."

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

    # Update cache after cleanup if anything was changed
    if [[ $cleaned -eq 1 ]]; then
        log_info "Updating APT cache after repository cleanup..."
        apt-get update -qq 2>/dev/null || log_warn "APT cache update failed (non-fatal)"
    fi
}

optimize_ssh_security() {
    log_info "Configuring SSH daemon for better security..."

    local sshd_config="/etc/ssh/sshd_config"
    local sshd_custom="/etc/ssh/sshd_config.d/99-ansible-bootstrap.conf"

    # Check if we can use sshd_config.d (Debian 11+, Ubuntu 20.04+)
    if [[ -d "/etc/ssh/sshd_config.d" ]]; then
        log_info "Using /etc/ssh/sshd_config.d/ for custom config..."

        cat > "$sshd_custom" <<EOF
# Ansible bootstrap security settings
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

        chmod 644 "$sshd_custom"

        # Test and reload SSH
        if sshd -t 2>/dev/null; then
            systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
            log_info "SSH configuration updated and reloaded"
        else
            log_warn "SSH config test failed, reverting changes"
            rm -f "$sshd_custom"
        fi
    else
        log_warn "Skipping SSH optimization (no sshd_config.d directory)"
    fi
}

print_summary() {
    local user_home
    user_home=$(eval echo "~$ANSIBLE_USER")
    local ip_addr
    ip_addr=$(hostname -I | awk '{print $1}')
    local hostname
    hostname=$(hostname)

    echo ""
    log_info "=========================================="
    log_info "Bootstrap completed successfully!"
    log_info "=========================================="
    echo ""
    echo "  Hostname:           $hostname"
    echo "  IP Address:         $ip_addr"
    echo "  User created:       $ANSIBLE_USER"
    echo "  Home directory:     $user_home"
    echo "  Sudo access:        Passwordless (via /etc/sudoers.d/90-${ANSIBLE_USER})"
    echo "  SSH key installed:  $([ -n "$SSH_PUBKEY" ] && echo "Yes (openclaw-ansible)" || echo "No")"
    echo "  SSH config:         GitHub via port 443"
    echo ""
    echo "Next steps:"
    echo ""
    echo "  1. Test SSH access from your control node:"
    echo "     ssh ${ANSIBLE_USER}@${ip_addr}"
    echo ""
    echo "  2. Add to your Ansible inventory (inventories/lab/hosts.yml):"
    echo "     new_hosts:"
    echo "       hosts:"
    echo "         ${hostname}:"
    echo "           ansible_host: ${ip_addr}"
    echo ""
    echo "  3. Run baseline configuration:"
    echo "     ansible-playbook playbooks/site.yml --limit ${hostname}"
    echo ""
    echo "  4. Or run specific playbooks:"
    echo "     ansible-playbook playbooks/00_sanity.yml --limit ${hostname}"
    echo "     ansible-playbook playbooks/monitored_hosts.yml --limit ${hostname}"
    echo ""

    if grep -q "Port 443" "${user_home}/.ssh/config" 2>/dev/null; then
        echo "  ℹ GitHub access configured via ssh.github.com:443"
        echo "    Test with: sudo -u ${ANSIBLE_USER} ssh -T git@github.com"
        echo ""
    fi
}

# --- Main execution ---
main() {
    log_info "Starting Ansible bootstrap..."
    echo ""

    check_root
    detect_os
    install_packages
    create_ansible_user
    setup_passwordless_sudo
    install_ssh_key
    setup_ssh_config
    cleanup_apt_repos
    optimize_ssh_security
    print_summary
}

main "$@"
