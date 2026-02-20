#!/usr/bin/env bash

MAAS_PROFILE="${MAAS_PROFILE:-admin}"
MAAS_SERVER="${MAAS_SERVER:-gssadmin@192.168.6.20}"
MAAS_SSH_KEY="${MAAS_SSH_KEY:-$HOME/.ssh/gss_maas}"
PRESEED_DIR="${PRESEED_DIR:-/var/snap/maas/current/preseeds}"
PRESEED_FILE="${PRESEED_FILE:-curtin_userdata_ubuntu_amd64_generic_jammy}"
PRESEED_PATH="${PRESEED_DIR}/${PRESEED_FILE}"

PROXMOX_HOST="${PROXMOX_HOST:-pveplym1}"
PROXMOX_VMID="${PROXMOX_VMID:-9200}"

DISTRO_SERIES="${DISTRO_SERIES:-jammy}"
LUKS_PASSPHRASE="${LUKS_PASSPHRASE:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_DIR="${PROJECT_DIR}/templates"
WORK_DIR="${WORK_DIR:-${PROJECT_DIR}/working}"

SYSTEM_ID=""
HOSTNAME=""
USERNAME=""
PASSWORD=""
ASSIGNED_IP=""

MACHINE_WORK_DIR=""
HYDRATED_CONFIG=""
LUKS_CONFIG=""
USER_DATA_FILE=""
ORIGINAL_PRESEED=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
    exit 1
}

ssh_maas() {
    ssh -i "${MAAS_SSH_KEY}" "${MAAS_SERVER}" "$@"
}

scp_to_maas() {
    scp -i "${MAAS_SSH_KEY}" "$1" "${MAAS_SERVER}:$2"
}

scp_from_maas() {
    scp -i "${MAAS_SSH_KEY}" "${MAAS_SERVER}:$1" "$2"
}

require_init() {
    if [[ -z "${SYSTEM_ID}" || -z "${HOSTNAME}" || -z "${USERNAME}" || -z "${PASSWORD}" ]]; then
        error "deploy_init must be called before running deployment steps"
    fi

    if [[ -z "${LUKS_PASSPHRASE}" ]]; then
        error "LUKS_PASSPHRASE environment variable is required"
    fi
}

check_maas_connectivity() {
    if [[ ! -f "${MAAS_SSH_KEY}" ]]; then
        error "MAAS_SSH_KEY not found at ${MAAS_SSH_KEY}"
    fi

    if ! ssh_maas "test -d ${PRESEED_DIR}" >/dev/null 2>&1; then
        error "Unable to reach MAAS server or access ${PRESEED_DIR}"
    fi
}

wait_for_status() {
    local system_id="$1"
    local target_status="$2"
    local max_attempts="${3:-30}"
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        local status
        status=$(maas "${MAAS_PROFILE}" machine read "${system_id}" 2>/dev/null | jq -r '.status_name')
        if [[ "${status}" == "${target_status}" ]]; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    return 1
}

wait_for_status_any() {
    local system_id="$1"
    shift
    local max_attempts="$1"
    shift
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        local status
        status=$(maas "${MAAS_PROFILE}" machine read "${system_id}" 2>/dev/null | jq -r '.status_name')
        for allowed in "$@"; do
            if [[ "${status}" == "${allowed}" ]]; then
                return 0
            fi
        done
        attempt=$((attempt + 1))
        sleep 2
    done
    return 1
}

wait_for_vm_stopped() {
    local host="$1"
    local vmid="$2"
    local max_attempts="${3:-30}"
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        local status
        status=$(ssh "${host}" qm status "${vmid}" 2>/dev/null | awk -F': ' '{print $2}')
        if [[ "${status}" == "stopped" ]]; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    return 1
}

generate_password_hash() {
    local password="$1"
    openssl passwd -6 "${password}"
}

deploy_init() {
    set -euo pipefail

    local system_id="$1"
    local hostname="$2"
    local username="$3"
    local password="$4"

    if [[ -z "${system_id}" ]]; then
        error "SYSTEM_ID is required"
    fi

    if [[ -z "${hostname}" ]]; then
        hostname="${system_id}"
    fi

    if [[ -z "${username}" ]]; then
        error "TARGET_USERNAME is required"
    fi

    if [[ -z "${password}" ]]; then
        error "TARGET_PASSWORD is required"
    fi

    SYSTEM_ID="${system_id}"
    HOSTNAME="${hostname}"
    USERNAME="${username}"
    PASSWORD="${password}"

    mkdir -p "${WORK_DIR}/${HOSTNAME}"
    MACHINE_WORK_DIR="${WORK_DIR}/${HOSTNAME}"

    HYDRATED_CONFIG="${MACHINE_WORK_DIR}/hydrated-curtin.yaml"
    LUKS_CONFIG="${MACHINE_WORK_DIR}/luks-preseed.yaml"
    USER_DATA_FILE="${MACHINE_WORK_DIR}/cloud-init-user-data.yaml"
    ORIGINAL_PRESEED="${MACHINE_WORK_DIR}/original-preseed.yaml"

    require_init
    check_maas_connectivity
}

deploy_backup_preseed() {
    set -euo pipefail
    require_init
    check_maas_connectivity

    log "Backing up original preseed from MAAS server..."

    if ssh_maas "sudo test -f ${PRESEED_PATH}"; then
        scp_from_maas "${PRESEED_PATH}" "${ORIGINAL_PRESEED}" 2>/dev/null || true
        log "Original preseed backed up to ${ORIGINAL_PRESEED}"
    else
        log "No existing preseed found, will restore from template after deploy"
        ssh_maas "cat ${PRESEED_DIR}/curtin_userdata.sample" > "${ORIGINAL_PRESEED}" 2>/dev/null || true
    fi

    log "Removing preseed before hydration..."
    ssh_maas "sudo rm -f ${PRESEED_PATH}"
}

deploy_hydrate() {
    set -euo pipefail
    require_init

    log "Releasing machine and verifying status..."
    maas "${MAAS_PROFILE}" machine release "${SYSTEM_ID}" > /dev/null 2>&1 || true

    if ! wait_for_status_any "${SYSTEM_ID}" 30 "Ready" "Allocated"; then
        error "Timeout waiting for machine to reach Ready or Allocated"
    fi

    log "Starting deploy to hydrate curtin config..."
    maas "${MAAS_PROFILE}" machine deploy "${SYSTEM_ID}" distro_series="${DISTRO_SERIES}" > /dev/null 2>&1

    log "Waiting for deploy to start..."
    if ! wait_for_status "${SYSTEM_ID}" "Deploying" 30; then
        error "Timeout waiting for deploy to start"
    fi

    log "Deploy started, fetching hydrated curtin config..."
    maas "${MAAS_PROFILE}" machine get-curtin-config "${SYSTEM_ID}" > "${HYDRATED_CONFIG}" 2>/dev/null

    if [[ ! -s "${HYDRATED_CONFIG}" ]]; then
        error "Failed to fetch hydrated curtin config"
    fi

    log "Hydrated config saved to ${HYDRATED_CONFIG}"

    ASSIGNED_IP=$(maas "${MAAS_PROFILE}" machine read "${SYSTEM_ID}" 2>/dev/null | jq -r '.ip_addresses[0] // empty')
    if [[ -n "${ASSIGNED_IP}" ]]; then
        log "Assigned IP: ${ASSIGNED_IP}"
        echo "${ASSIGNED_IP}" > "${MACHINE_WORK_DIR}/assigned-ip.txt"
    fi

    log "Aborting deploy..."
    maas "${MAAS_PROFILE}" machine abort "${SYSTEM_ID}" > /dev/null 2>&1
    sleep 5

    log "Forcing VM power off and verifying stopped..."
    ssh "${PROXMOX_HOST}" qm stop "${PROXMOX_VMID}" > /dev/null 2>&1 || true
    if ! wait_for_vm_stopped "${PROXMOX_HOST}" "${PROXMOX_VMID}" 30; then
        error "Timeout waiting for VM ${PROXMOX_VMID} to stop"
    fi
}

deploy_generate_luks_preseed() {
    set -euo pipefail
    require_init

    log "Creating LUKS preseed with Tempita template..."

    HYDRATED_CONFIG_PATH="${HYDRATED_CONFIG}" \
    LUKS_CONFIG_PATH="${LUKS_CONFIG}" \
    LUKS_PASSPHRASE_VALUE="${LUKS_PASSPHRASE}" \
    python3 << 'PYEOF'
import yaml
import sys
import os

with open(os.environ["HYDRATED_CONFIG_PATH"], "r") as f:
    hydrated = yaml.safe_load(f)

storage = hydrated.get("storage", {})
storage_config = storage.get("config", [])

disk = None
for item in storage_config:
    if item.get("type") == "disk":
        disk = item
        break

if not disk:
    print("ERROR: No disk found in storage config", file=sys.stderr)
    sys.exit(1)

disk_id = disk["id"]
disk_serial = disk.get("serial", "")
disk_model = disk.get("model", "")

partitions = [item for item in storage_config if item.get("type") == "partition"]
total_partition_size = sum(int(str(p.get("size", "0")).rstrip("B")) for p in partitions)

efi_size = 536870912
boot_size = 2147483648
part1_offset = 4194304
gpt_backup = 1048576

disk_size = part1_offset + total_partition_size + gpt_backup
part3_size = disk_size - part1_offset - efi_size - boot_size - gpt_backup

luks_passphrase = os.environ["LUKS_PASSPHRASE_VALUE"]

preseed_content = f'''#cloud-config
debconf_selections:
 maas: |
  {{{{for line in str(curtin_preseed).splitlines()}}}}
  {{{{line}}}}
  {{{{endfor}}}}
early_commands:
  driver_00:
  - sh
  - -c
  - echo third party drivers not installed or necessary.
install:
  error_tarfile: /tmp/curtin-logs.tar
  log_file: /tmp/install.log
  post_files:
  - /tmp/install.log
  - /tmp/curtin-logs.tar
kernel:
  mapping: {{}}
  package: linux-generic
kernel-crash-dumps:
  enabled: false
late_commands:
  maas: [wget, '--no-proxy', {{{{node_disable_pxe_url|escape.json}}}}, '--post-data', {{{{node_disable_pxe_data|escape.json}}}}, '-O', '/dev/null']
  00_setup_luks_keyfile:
  - curtin
  - in-target
  - --
  - sh
  - -c
  - echo '{luks_passphrase}' > /root/luks-key && chmod 600 /root/luks-key
  01_curtin_crypttab:
  - curtin
  - in-target
  - --
  - sh
  - -c
  - echo '{disk_id}-part3_crypt UUID=$(blkid -s UUID -o value /dev/{disk_id}3) /root/luks-key luks,discard' >> /etc/crypttab
  02_add_keyfile_to_initramfs:
  - curtin
  - in-target
  - --
  - sh
  - -c
  - echo 'KEYFILE_PATTERN=/root/luks-key' >> /etc/cryptsetup-initramfs/conf-hook && echo 'UMASK=0077' >> /etc/initramfs-tools/initramfs.conf
  03_update_initramfs:
  - curtin
  - in-target
  - --
  - update-initramfs
  - -u
  - -k
  - all
  04_update_grub:
  - curtin
  - in-target
  - --
  - update-grub
network_commands:
  builtin:
  - curtin
  - net-meta
  - custom
partitioning_commands:
  builtin:
  - curtin
  - block-meta
  - custom
showtrace: true
storage:
  version: 1
  config:
  - id: {disk_id}
    type: disk
    ptable: gpt
    grub_device: true
    model: {disk_model}
    serial: {disk_serial}
    name: {disk_id}
    wipe: superblock
  - id: {disk_id}-part1
    type: partition
    device: {disk_id}
    number: 1
    size: {efi_size}B
    offset: {part1_offset}B
    flag: boot
    wipe: superblock
  - id: {disk_id}-part2
    type: partition
    device: {disk_id}
    number: 2
    size: {boot_size}B
    wipe: superblock
  - id: {disk_id}-part3
    type: partition
    device: {disk_id}
    number: 3
    size: {part3_size}B
    wipe: superblock
  - id: {disk_id}-part3_crypt
    type: dm_crypt
    dm_name: {disk_id}-part3_crypt
    volume: {disk_id}-part3
    key: {luks_passphrase}
    keysize: '512'
  - id: {disk_id}-part1_format
    type: format
    fstype: fat32
    label: efi
    volume: {disk_id}-part1
  - id: {disk_id}-part2_format
    type: format
    fstype: ext4
    label: boot
    volume: {disk_id}-part2
  - id: {disk_id}-part3_format
    type: format
    fstype: ext4
    label: root
    volume: {disk_id}-part3_crypt
  - id: {disk_id}-part3_mount
    type: mount
    path: /
    device: {disk_id}-part3_format
  - id: {disk_id}-part2_mount
    type: mount
    path: /boot
    device: {disk_id}-part2_format
  - id: {disk_id}-part1_mount
    type: mount
    path: /boot/efi
    device: {disk_id}-part1_format
verbosity: 3
'''

with open(os.environ["LUKS_CONFIG_PATH"], "w") as f:
    f.write(preseed_content)

print(f"LUKS preseed written to {os.environ['LUKS_CONFIG_PATH']}")
print(f"Disk: {disk_id}, Model: {disk_model}, Serial: {disk_serial}")
print(f"Partition 3 size: {part3_size}B ({part3_size / 1024 / 1024 / 1024:.2f} GB)")
PYEOF

    if [[ ! -s "${LUKS_CONFIG}" ]]; then
        error "Failed to generate LUKS preseed"
    fi
}

deploy_generate_cloud_init() {
    set -euo pipefail
    require_init

    if [[ ! -f "${TEMPLATE_DIR}/cloud-init.yaml.tpl" ]]; then
        error "Cloud-init template not found at ${TEMPLATE_DIR}/cloud-init.yaml.tpl"
    fi

    local password_hash
    password_hash=$(generate_password_hash "${PASSWORD}")

    export USERNAME="${USERNAME}"
    export PASSWORD_HASH="${password_hash}"

    envsubst < "${TEMPLATE_DIR}/cloud-init.yaml.tpl" > "${USER_DATA_FILE}"
}

deploy_upload_preseed() {
    set -euo pipefail
    require_init
    check_maas_connectivity

    log "Uploading LUKS preseed to MAAS server..."
    scp_to_maas "${LUKS_CONFIG}" "/tmp/luks-preseed-${SYSTEM_ID}.yaml"
    ssh_maas "sudo cp /tmp/luks-preseed-${SYSTEM_ID}.yaml ${PRESEED_PATH}"
}

deploy_execute() {
    set -euo pipefail
    require_init

    log "Deploying with LUKS preseed and user-data..."
    local user_data_b64
    user_data_b64=$(base64 -w 0 "${USER_DATA_FILE}")

    maas "${MAAS_PROFILE}" machine deploy "${SYSTEM_ID}" \
        distro_series="${DISTRO_SERIES}" \
        user_data="${user_data_b64}" > /dev/null 2>&1

    sleep 5
    local deploy_status
    deploy_status=$(maas "${MAAS_PROFILE}" machine read "${SYSTEM_ID}" 2>/dev/null | jq -r '.status_name')
    if [[ -z "${deploy_status}" || "${deploy_status}" == "null" ]]; then
        error "Failed to read deploy status from MAAS"
    fi
    log "Current status: ${deploy_status}"
}

deploy_restore_preseed() {
    set -euo pipefail
    require_init
    check_maas_connectivity

    log "Waiting for deployment to complete before restoring preseed..."

    local restore_attempt=0
    local restore_max=90
    while [[ $restore_attempt -lt $restore_max ]]; do
        local current_status
        current_status=$(maas "${MAAS_PROFILE}" machine read "${SYSTEM_ID}" 2>/dev/null | jq -r '.status_name')

        case "${current_status}" in
            "Deployed")
                log "Machine deployed successfully!"
                break
                ;;
            "Failed deployment")
                log "WARNING: Deployment failed. Check MAAS logs."
                break
                ;;
            "Deploying")
                ;;
            *)
                log "Unexpected status: ${current_status}"
                ;;
        esac

        restore_attempt=$((restore_attempt + 1))
        if (( restore_attempt % 6 == 0 )); then
            log "  Still deploying... (${restore_attempt}/${restore_max}, status: ${current_status})"
        fi
        sleep 20
    done

    if [[ $restore_attempt -ge $restore_max ]]; then
        log "WARNING: Timeout waiting for deployment. Restoring preseed anyway."
    fi

    log "Restoring original preseed..."
    if [[ -s "${ORIGINAL_PRESEED}" ]]; then
        scp_to_maas "${ORIGINAL_PRESEED}" "/tmp/original-preseed-restore.yaml"
        ssh_maas "sudo cp /tmp/original-preseed-restore.yaml ${PRESEED_PATH}"
        log "Original preseed restored"
    else
        log "No original preseed to restore, leaving current in place"
    fi
}

deploy_run() {
    set -euo pipefail
    require_init

    deploy_backup_preseed
    deploy_hydrate
    deploy_generate_luks_preseed
    deploy_generate_cloud_init
    deploy_upload_preseed
    deploy_execute
    deploy_restore_preseed
}
