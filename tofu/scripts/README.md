# Tofu Scripts

This directory contains centralized utility scripts for OpenTofu/Terraform operations across all modules.

## destroy-all-workspaces.sh

Destroy infrastructure in ALL tofu/terraform workspaces for a given module. Works with both **local state** and **S3 (remote)** backends — the backend type is auto-detected.

### Usage

```bash
# Interactive — prompt before each workspace
tofu/scripts/destroy-all-workspaces.sh tofu/aws/modules/cluster_nodes

# CI-friendly — destroy everything without prompts and delete workspaces
tofu/scripts/destroy-all-workspaces.sh --auto-approve --delete-workspaces \
    tofu/aws/modules/cluster_nodes

# Dry run — see what would be destroyed
tofu/scripts/destroy-all-workspaces.sh --dry-run tofu/aws/modules/airgap

# Custom var-file
tofu/scripts/destroy-all-workspaces.sh --var-file custom.tfvars \
    tofu/aws/modules/cluster_nodes
```

### Options

| Flag                    | Description                                              |
|-------------------------|----------------------------------------------------------|
| `--auto-approve`        | Skip per-workspace confirmation prompts                  |
| `--delete-workspaces`   | Delete each workspace after successful destroy           |
| `--dry-run`             | Show what would be destroyed without running destroy     |
| `--var-file FILE`       | Use a specific var-file (default: auto-detected)        |
| `--help`                | Show help message                                        |

### Make Integration

```bash
make infra-nuke-all                                    # Interactive
make infra-nuke-all AUTO_APPROVE=yes                   # No prompts
make infra-nuke-all AUTO_APPROVE=yes DELETE_WORKSPACES=yes  # Full cleanup
make infra-nuke-all DRY_RUN=yes                        # Preview only
make infra-nuke-all ENV=airgap                         # Target airgap module
```

### How It Works

1. **Auto-detects backend** — reads `backend.tf` to determine S3 vs local state
2. **Initializes tofu** if `.terraform/` is missing
3. **Enumerates all workspaces** and counts resources in each
4. **Displays a summary table** with workspace names, resource counts, and status
5. **Destroys each workspace** with `tofu destroy -auto-approve`
6. **Optionally deletes** empty workspaces after destroy
7. **Restores original workspace** when finished

### Safety Features

- **Global confirmation** — requires `y` to proceed (unless `--auto-approve`)
- **Per-workspace confirmation** — approve each workspace individually (unless `--auto-approve`)
- **Skips empty workspaces** — only attempts destroy on workspaces with resources
- **Protects `default` workspace** — cannot be deleted even with `--delete-workspaces`
- **Dry run mode** — preview what will be destroyed without making changes
- **Summary report** — shows destroyed / skipped / failed counts

### S3 State Cleanup

When using the S3 backend, the script **automatically removes orphaned state files** from S3 after each workspace is destroyed. This prevents stale state objects from accumulating in your S3 bucket.

S3 state paths follow the standard OpenTofu/Terraform layout:

```
s3://<bucket>/<key>                         # default workspace
s3://<bucket>/env:/<workspace>/<key>         # named workspaces
```

For example, with `key = "terraform.tfstate"` in `backend.tf`:

```
s3://jenkins-terraform-state-storage/terraform.tfstate                                    # default
s3://jenkins-terraform-state-storage/env:/my-testing/terraform.tfstate                    # my-testing
```

The S3 cleanup:
- Is triggered **only after a successful `tofu destroy`** — failed destroys leave state intact for recovery
- Parses `backend.tf` automatically to discover the bucket, key, and region
- Requires the `aws` CLI to be installed and configured with appropriate S3 permissions
- Gracefully skips cleanup if `aws` CLI is not available (with a warning)
- Works with `--dry-run` to preview which S3 paths would be deleted

### Local vs S3 Backend

The script works identically with both backends. Key differences:

- **Local backend**: State stored in `terraform.tfstate.d/<workspace>/terraform.tfstate` within the module directory
- **S3 backend**: State stored remotely in S3; `tofu workspace list/destroy` uses the S3 API

No configuration changes are needed — the script reads your existing `backend.tf` to determine the backend type.

## new-workspace.sh

Interactive workspace creation with validation and naming suggestions.

### Usage

```bash
# From any tofu module directory
../../scripts/new-workspace.sh [path]

# Or using make (recommended)
make workspace-new              # Interactive creation
make workspace-new WORKSPACE=name  # Direct creation
```

### Features

- Interactive prompt with workspace naming suggestions
- Validates workspace name format (alphanumeric, hyphens, underscores)
- Prevents creation of 'default' (reserved by OpenTofu)
- Checks for duplicate workspace names
- Shows next steps after creation

### Examples

```bash
# Run interactive creation
make workspace-new

# Output:
# ╔════════════════════════════════════════════════════════════════╗
# ║  OpenTofu Workspace Creator                                   ║
# ║  Module: aws/modules/cluster_nodes                            ║
# ║  Current: default                                              ║
# ╚════════════════════════════════════════════════════════════════╝
#
# Workspace naming suggestions:
#   - Environment names: dev, staging, prod, test
#   - Feature names: feature-x, bugfix-123, experiment-1
#   - User names: username-workspace, personal-test
#   - Date-based: 2026-04-24-test, sprint-5
#
# Enter new workspace name (or 'cancel' to abort): dev-environment
#
# Creating workspace: dev-environment
# Module: aws/modules/cluster_nodes
#
# ✓ Workspace 'dev-environment' created successfully!
#
# Next steps:
#   1. Deploy infrastructure to this workspace:
#      make infra-up WORKSPACE=dev-environment
#
#   2. Or switch to it as your active workspace:
#      make workspace-select WORKSPACE=dev-environment
#      make infra-up
```

## select-workspace.sh

Interactive workspace selection menu for tofu/terraform modules.

### Usage

```bash
# From any tofu module directory
../../scripts/select-workspace.sh [path]

# Or using make (recommended)
make workspace-select              # Interactive menu
make workspace-select WORKSPACE=name  # Direct selection
```

### Features

- Lists all workspaces with current workspace marked with `*`
- Interactive numbered menu for easy selection
- Option to create new workspaces if none exist
- Cancel operation with option 0
- Shows current workspace after selection

### Examples

```bash
# Run interactive menu
make workspace-select

# Output:
# Available workspaces:
#
#   * default (current)
#
#     1. dev-environment
#     2. testing
#     0. cancel
#
# Select workspace (number or name): 1
#
# Selecting workspace 'dev-environment'...
# Switched to workspace "dev-environment"
#
# Current workspace: dev-environment
```

## delete-workspace.sh

Interactive workspace deletion with resource counts and safety confirmations.

### Usage

```bash
# From any tofu module directory
../../scripts/delete-workspace.sh [path]

# Or using make (recommended)
make workspace-delete              # Interactive deletion
make workspace-delete WORKSPACE=name  # Direct deletion
```

### Features

- Lists all workspaces with resource counts
- Excludes current workspace from deletion (prevents accidents)
- Shows resource count before deletion
- Multi-stage confirmation:
  - Non-empty workspaces: requires typing 'DELETE'
  - Empty workspaces: simple 'y/N' confirmation
- Shows remaining workspaces after deletion

### Examples

```bash
# Run interactive deletion
make workspace-delete

# Output:
# ╔════════════════════════════════════════════════════════════════╗
# ║  OpenTofu Workspace Deleter                                   ║
# ║  Module: aws/modules/cluster_nodes                            ║
# ╚════════════════════════════════════════════════════════════════╝
#
# Available workspaces to delete:
#
#   Current: default (cannot delete)
#
#     1. dev-environment           12 res
#     2. old-test                   0 res
#     0. cancel
#
# Select workspace to delete (number or name): 1
#
# Workspace to delete: dev-environment
# Resources in workspace: 12
#
# ⚠️  WARNING: This workspace contains 12 resource(s).
#
# Type 'DELETE' to confirm destruction of 12 resources: DELETE
#
# Deleting workspace 'dev-environment'...
#
# ✓ Workspace 'dev-environment' deleted successfully.
#
# Remaining workspaces:
#   default
#   old-test
```

### Safety Features

- **Cannot delete current workspace**: Must switch first with `make workspace-select`
- **Resource counts**: Shows how many resources will be destroyed
- **Type-to-confirm**: Non-empty workspaces require typing 'DELETE'
- **Empty workspace protection**: Simple confirmation for empty workspaces

## init-backend.sh

Centralized backend configuration script that generates `backend.tf` from templates and initializes the working directory.

### Usage

```bash
# From any tofu module directory
../../scripts/init-backend.sh <backend-type> [options]

# Or using make (recommended)
make backend-s3 BUCKET=my-bucket KEY=my-key REGION=us-east-1
make backend-local
```

### S3 Backend

```bash
../../scripts/init-backend.sh s3 \
  --bucket my-terraform-state \
  --key rke2-default/terraform.tfstate \
  --region us-east-1 \
  --dynamodb-table my-lock-table \
  --encrypt true
```

Or using make:
```bash
make backend-s3 BUCKET=my-terraform-state \
  KEY=rke2-default/terraform.tfstate \
  REGION=us-east-1 \
  DYNAMODB_TABLE=my-lock-table
```

### Local Backend

```bash
../../scripts/init-backend.sh local --path terraform.tfstate
```

Or using make:
```bash
make backend-local PATH=terraform.tfstate
```

### How It Works

1. Reads template from `tofu/templates/backend-{type}.tf.tmpl`
2. Substitutes placeholders with provided values
3. Writes `backend.tf` in current directory
4. Runs `tofu init -reconfigure` to apply new backend

### Adding New Backend Types

1. Create template in `tofu/templates/backend-{type}.tf.tmpl`
2. Add case handler in `init-backend.sh` for the new type
3. Update this README with usage examples

## Available Backend Types

- **s3**: AWS S3 with optional DynamoDB locking
- **local**: Local file storage

## Requirements

- OpenTofu (`tofu`) or Terraform (`terraform`) in PATH
- Appropriate cloud credentials for backend type

## Quick Reference

### Common Workflows

**1. Setup Backend:**
```bash
make backend-s3 BUCKET=my-state KEY=terraform.tfstate REGION=us-east-1
```

**2. Work with Workspaces:**
```bash
make workspace-list           # See all workspaces
make workspace-select         # Interactive menu with resource counts
make workspace-inspect        # Detailed workspace information
```

**3. Manage Infrastructure:**
```bash
make infra-scan               # See ALL infrastructure across modules
make infra-up                 # Deploy infrastructure
make infra-down               # Destroy with detailed confirmation
```

**4. Discovery:**
```bash
# What infrastructure exists?
make infra-ls                 # Quick list
make infra-scan              # Detailed view with resources

# What's in my current workspace?
make workspace-inspect       # Workspace details
make workspace-show          # Just show workspace name
```

### Understanding Module Context

The makefile automatically maps ENV variables to tofu modules:
- `ENV=default` → `tofu/aws/modules/cluster_nodes`
- `ENV=airgap` → `tofu/aws/modules/airgap`

Always check which module you're operating on:
```bash
make workspace-inspect       # Shows module path
make infra-down               # Shows target before destroying
```
