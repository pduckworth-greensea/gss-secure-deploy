# gss-secure-deploy

Interactive CLI wizard for deploying LUKS-encrypted Ubuntu developer workstations via MAAS.

## Features (In Development)

- Interactive machine selection with gum
- LUKS encryption via MAAS curtin
- TPM auto-unlock with Clevis
- Full Ubuntu Desktop configuration via Ansible
- Supports VMs and physical ThinkPads

## Requirements

- Bash 4.0+
- charmbracelet/gum
- MAAS CLI
- Ansible 2.9+

## Usage

```bash
./gss-secure-deploy
```

## Development Status

🚧 Under active development
