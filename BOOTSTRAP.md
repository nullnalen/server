# Ansible Bootstrap Guide

Dette scriptet forbereder en fersk Debian/Ubuntu-server for Ansible-administrasjon.

## Quick Start

### På den nye serveren (som root):

```bash
# Last ned og kjør bootstrap-scriptet
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/bootstrap-ansible.sh | bash
```

### Eller med custom SSH-nøkkel:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/bootstrap-ansible.sh | bash -s -- "ssh-ed25519 AAAAC3Nza... your-key"
```

## Hva scriptet gjør

1. ✅ **Installerer nødvendige pakker**: python3, sudo, git, vim, curl, openssh-client
2. ✅ **Oppretter ansible-bruker** med sudo-rettigheter
3. ✅ **Konfigurerer passwordless sudo** via `/etc/sudoers.d/90-ansible`
4. ✅ **Installerer SSH public key** (openclaw-ansible)
5. ✅ **Setter opp SSH-konfig** for GitHub via port 443
6. ✅ **Rydder problematiske APT-repos** (wazuh, influxdata)
7. ✅ **Optimaliserer SSH-sikkerhet** (deaktiverer password auth)

## Standard SSH-nøkkel

Scriptet bruker som standard `openclaw-ansible` public key:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICd1ZjjeqniD4m7F+AapwEablHCNB8xi4NMKEw6Q0rO8 openclaw-ansible
```

## SSH-konfigurasjon

Scriptet oppretter `~ansible/.ssh/config`:

```
Host github.com
    HostName ssh.github.com
    User git
    Port 443
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new

Host *
    ServerAliveInterval 60
    ServerAliveCountMax 3
    IdentitiesOnly yes
```

Dette gjør at Ansible-brukeren kan aksessere GitHub via port 443 (nyttig når port 22 er blokkert).

## Etter bootstrap

### 1. Test SSH-tilkobling

```bash
ssh ansible@<server-ip>
```

### 2. Legg til i inventory

Rediger `inventories/lab/hosts.yml`:

```yaml
new_hosts:
  hosts:
    newserver:
      ansible_host: 192.168.1.100
```

### 3. Kjør baseline-konfigurasjon

```bash
# Sanity check
ansible-playbook playbooks/00_sanity.yml --limit newserver

# Full baseline
ansible-playbook playbooks/site.yml --limit newserver

# Legg til monitoring
ansible-playbook playbooks/monitored_hosts.yml --limit newserver
```

### 4. Flytt fra new_hosts til riktig gruppe

Når serveren er konfigurert, flytt den fra `new_hosts` til riktig gruppe i inventory:

```yaml
all_hosts:
  hosts:
    newserver:
      ansible_host: 192.168.1.100

lxc_hosts:  # eller vm_hosts, docker_hosts, etc.
  hosts:
    newserver:
```

## Troubleshooting

### SSH-tilkobling feiler

```bash
# Test fra control node
ssh -v ansible@<server-ip>

# Sjekk authorized_keys på serveren
sudo cat /home/ansible/.ssh/authorized_keys
```

### Sudo fungerer ikke

```bash
# Sjekk sudoers-fil
sudo visudo -cf /etc/sudoers.d/90-ansible

# Test sudo
sudo -u ansible sudo whoami
```

### GitHub-tilgang feiler

```bash
# Test GitHub SSH på serveren
sudo -u ansible ssh -T git@github.com

# Skal gi: "Hi! You've successfully authenticated, but GitHub does not provide shell access."
```

## Sikkerhetsmerknad

Dette scriptet:
- ✅ **Deaktiverer** password authentication for SSH
- ✅ **Krever** SSH key for innlogging
- ✅ **Begrenser** root login til key-only
- ✅ **Validerer** sudoers syntax før aktivering

Public key er trygg å dele i public repo (det er **public** key, ikke private).

## Manuell installasjon

Hvis du foretrekker manuell installasjon:

```bash
# 1. Installer pakker
apt-get update
apt-get install -y sudo python3 python3-apt curl vim git openssh-client

# 2. Opprett bruker
useradd -m -s /bin/bash -G sudo ansible

# 3. Konfigurer sudo
echo "ansible ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-ansible
chmod 0440 /etc/sudoers.d/90-ansible

# 4. Installer SSH-nøkkel
mkdir -p /home/ansible/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICd1ZjjeqniD4m7F+AapwEablHCNB8xi4NMKEw6Q0rO8 openclaw-ansible" >> /home/ansible/.ssh/authorized_keys
chmod 700 /home/ansible/.ssh
chmod 600 /home/ansible/.ssh/authorized_keys
chown -R ansible:ansible /home/ansible/.ssh

# 5. Konfigurer SSH for GitHub
cat > /home/ansible/.ssh/config <<EOF
Host github.com
    HostName ssh.github.com
    User git
    Port 443
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
EOF
chmod 600 /home/ansible/.ssh/config
chown ansible:ansible /home/ansible/.ssh/config
```

## Idempotens

Scriptet er idempotent og kan kjøres flere ganger uten problemer:
- Eksisterende bruker blir ikke overskrevet
- SSH-nøkkel legges bare til hvis den ikke finnes
- Pakker oppdateres hvis nødvendig

## Kompatibilitet

Testet på:
- ✅ Debian 11 (Bullseye)
- ✅ Debian 12 (Bookworm)
- ✅ Ubuntu 20.04 LTS
- ✅ Ubuntu 22.04 LTS
- ✅ Ubuntu 24.04 LTS

Støtter både LXC containers og VMs.
