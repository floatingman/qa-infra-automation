# Rancher Helm Uninstall Role

This Ansible role uninstalls Rancher from an RKE2 cluster using Helm.

## Features

- **Complete Rancher Removal**: Uninstalls Rancher Helm release and all associated resources
- **Backup Creation**: Optional backup of Rancher configuration and resources before uninstall
- **cert-manager Cleanup**: Automatically removes cert-manager if it was installed by Rancher
- **Namespace Management**: Optionally removes the Rancher namespace and Helm repositories
- **Safety Checks**: Validates kubectl connectivity and Rancher installation status

## Variables

### Control Variables
- `uninstall_rancher` (default: false) - Enable Rancher uninstall
- `uninstall_helm` (default: false) - Install Helm binary if not present
- `force_uninstall` (default: false) - Force uninstall even with errors

### Configuration Variables
- `kubeconfig_path` (default: "/home/{{ ansible_user }}/.kube/config") - Path to kubectl config
- `rancher_namespace` (default: "cattle-system") - Rancher namespace
- `helm_version` (default: "v3.12.3") - Helm version to install

### Cleanup Options
- `create_backup` (default: true) - Create backup before uninstall
- `backup_path` (default: "/home/{{ ansible_user }}/rancher-backup-{{ ansible_date_time.iso8601 }}.yaml") - Backup file path
- `remove_namespace` (default: true) - Remove Rancher namespace after uninstall
- `remove_cert_manager` (default: true) - Remove cert-manager if present
- `remove_helm_repos` (default: false) - Remove Helm repositories

## Usage

### Using the Playbook

```bash
# Basic uninstall with defaults
ansible-playbook -i inventory/inventory.yml playbooks/deploy/rancher-helm-uninstall-playbook.yml

# Uninstall with custom variables
ansible-playbook -i inventory/inventory.yml playbooks/deploy/rancher-helm-uninstall-playbook.yml \
  -e "force_uninstall=true" \
  -e "remove_namespace=false"
```

### Using the Role Directly

```yaml
- hosts: bastion
  roles:
    - role: rancher_helm_uninstall
      uninstall_rancher: true
      create_backup: true
      remove_namespace: true
```

## What Gets Removed

1. **Rancher Helm Release**: The main Rancher deployment
2. **Rancher Namespace**: All resources in the cattle-system namespace (optional)
3. **cert-manager**: If installed by Rancher (optional)
4. **Helm Repositories**: Rancher and jetstack repositories (optional)
5. **Temporary Files**: Helm installation files

## Backup Information

When `create_backup=true`, the role creates:
- `rancher-backup-YYYY-MM-DDTHH-MM-SSZ-values.yaml` - Rancher Helm values
- `rancher-backup-YYYY-MM-DDTHH-MM-SSZ-resources.yaml` - All namespace resources

## Safety Features

- **Pre-flight Checks**: Validates kubectl connectivity before proceeding
- **Installation Check**: Only proceeds if Rancher is actually installed
- **Backup First**: Creates backups before making any changes
- **Error Handling**: Graceful handling of missing resources or failed operations
- **Verification**: Confirms successful uninstallation

## Prerequisites

- kubectl configured and connected to RKE2 cluster
- Ansible kubernetes.core collection installed
- Bastion host with sudo access
- Python kubernetes library (automatically installed)

## Example Output

```
=======================================
Rancher Uninstall Complete!
=======================================
Namespace: cattle-system
Status: Successfully uninstalled
Backup Location: /home/ec2-user/rancher-backup-2024-01-15T10-30-00Z.yaml
Remaining Resources: 0
=======================================
```

## Troubleshooting

### Common Issues

1. **Role not found**: Ensure ansible.cfg has correct `roles_path = ../../roles`
2. **kubectl not configured**: Run `setup-kubectl-access.yml` first
3. **Permission denied**: Ensure bastion user has sudo access
4. **Namespace stuck in terminating**: Check for finalizers or stuck resources

### Debug Mode

```bash
ansible-playbook -i inventory/inventory.yml playbooks/deploy/rancher-helm-uninstall-playbook.yml -vvv
```

## Integration

This role is designed to work with the RKE2 airgap deployment framework and integrates with:
- `rancher_helm_deploy` role (for reinstallation)
- RKE2 cluster management playbooks
- Registry configuration and management

## Related Files

- `playbooks/deploy/rancher-helm-uninstall-playbook.yml` - Main uninstall playbook
- `roles/rancher_helm_deploy/` - Rancher deployment role
- `inventory/group_vars/all.yml` - Global configuration variables