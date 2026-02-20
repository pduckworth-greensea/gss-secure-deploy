#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ANSIBLE_DIR="${PROJECT_DIR}/ansible"

# Run clevis TPM binding on a target host
# Usage: ansible_bind_tpm <hostname> <luks_device> <luks_passphrase>
ansible_bind_tpm() {
    local hostname="$1"
    local luks_device="${2:-/dev/sda3}"
    local luks_passphrase="$3"
    
    ansible-playbook "${ANSIBLE_DIR}/playbooks/clevis-bind.yml" \
        -i "${hostname}," \
        -e "target_host=${hostname}" \
        -e "luks_device=${luks_device}" \
        -e "luks_passphrase=${luks_passphrase}" \
        -e "clevis_pcr_bank=sha256" \
        -e "ansible_user=gssadmin" \
        -e "ansible_ssh_private_key_file=${HOME}/.ssh/gss_maas"
}
