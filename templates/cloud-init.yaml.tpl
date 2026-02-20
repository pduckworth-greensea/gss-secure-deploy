#cloud-config
# Greensea Systems Inc. - Secure Deployment Cloud-Init Configuration
# Users-only template for secure VM provisioning
# Variables: ${USERNAME}, ${PASSWORD_HASH}

disable_root: true
ssh_pwauth: true

users:
  - name: gssadmin
    gecos: 'Greensea Systems Administrator'
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: [sudo, adm, cdrom, dip, plugdev, lxd]
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICRNio+QrRE0j5qm9N20MpZIHQGNT9XtTD99F6jOSEJd
  - name: ${USERNAME}
    gecos: 'Target User'
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: [sudo, adm, cdrom, dip, plugdev, lxd]
    lock_passwd: false
    passwd: ${PASSWORD_HASH}
