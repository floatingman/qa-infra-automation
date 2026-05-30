#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# destroy-all-workspaces.sh
# Destroy infrastructure in ALL tofu/terraform workspaces for a given module,
# then optionally delete the empty workspaces and clean up S3 state folders.
#
# Works with both local state and S3 (remote) backends — state location is
# discovered automatically via `tofu workspace list`.
#
# Usage:
#   destroy-all-workspaces.sh [OPTIONS] <tofu-module-dir>
#
# Options:
#   --auto-approve      Skip per-workspace confirmation prompts
#   --delete-workspaces Remove each workspace after successful destroy
#   --dry-run           Show what would be destroyed without running destroy
#   --var-file FILE     Use a specific var-file (default: auto-detected)
#   --help              Show this help message
#
# Examples:
#   # Interactive — prompt before each workspace
#   destroy-all-workspaces.sh tofu/aws/modules/cluster_nodes
#
#   # CI-friendly — destroy everything without prompts
#   destroy-all-workspaces.sh --auto-approve --delete-workspaces \
#       tofu/aws/modules/cluster_nodes
#
#   # Dry run — see what's out there
#   destroy-all-workspaces.sh --dry-run tofu/aws/modules/airgap
#
#   # Custom var-file
#   destroy-all-workspaces.sh --var-file custom.tfvars \
#       tofu/aws/modules/cluster_nodes
# ---------------------------------------------------------------------------

set -uo pipefail
# NOTE: intentionally NOT using `set -e` — we handle errors explicitly so
# that a single bad workspace never kills the entire loop.

export PATH="/usr/bin:/bin:/usr/local/bin:${PATH}"

# ── Colors (disabled when stdout is not a terminal) ─────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
fi

# ── Defaults ────────────────────────────────────────────────────────────────
AUTO_APPROVE=false
DELETE_WORKSPACES=false
DRY_RUN=false
VAR_FILE=""
TOFU_DIR=""

# ── Parse arguments ─────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --auto-approve)       AUTO_APPROVE=true;    shift ;;
        --delete-workspaces)  DELETE_WORKSPACES=true; shift ;;
        --dry-run)            DRY_RUN=true;         shift ;;
        --var-file)           VAR_FILE="$2";        shift 2 ;;
        --help|-h)
            sed -n '2,/^# ----/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        -*) echo -e "${RED}Error: Unknown option: $1${NC}" >&2; exit 2 ;;
        *)  TOFU_DIR="$1";   shift ;;
    esac
done

if [ -z "$TOFU_DIR" ]; then
    echo -e "${RED}Error: No tofu module directory specified.${NC}" >&2
    echo "Usage: $0 [OPTIONS] <tofu-module-dir>" >&2
    exit 2
fi

if [ ! -d "$TOFU_DIR" ]; then
    echo -e "${RED}Error: Directory not found: $TOFU_DIR${NC}" >&2
    exit 1
fi

# ── Detect tofu or terraform CLI ────────────────────────────────────────────
if command -v tofu >/dev/null 2>&1; then
    TF_CLI="tofu"
elif command -v terraform >/dev/null 2>&1; then
    TF_CLI="terraform"
else
    echo -e "${RED}Error: Neither 'tofu' nor 'terraform' found in PATH.${NC}" >&2
    exit 1
fi

# ── Resolve var-file ────────────────────────────────────────────────────────
cd "$TOFU_DIR"

if [ -n "$VAR_FILE" ]; then
    if [ ! -f "$VAR_FILE" ]; then
        echo -e "${RED}Error: Var-file not found: $VAR_FILE${NC}" >&2
        exit 1
    fi
    VAR_FILE_FLAG=(-var-file="$VAR_FILE")
elif [ -f "terraform.tfvars" ]; then
    VAR_FILE_FLAG=(-var-file=terraform.tfvars)
else
    echo -e "${YELLOW}Warning: No terraform.tfvars found. Using defaults / env vars.${NC}"
    VAR_FILE_FLAG=()
fi

# ── Detect backend type and parse S3 config ─────────────────────────────────
detect_backend_type() {
    if [ -f "backend.tf" ]; then
        if grep -q 'backend "s3"' backend.tf 2>/dev/null; then
            echo "s3"
        elif grep -q 'backend "local"' backend.tf 2>/dev/null; then
            echo "local"
        else
            echo "unknown"
        fi
    else
        echo "local"
    fi
}

S3_BUCKET=""
S3_KEY=""
S3_REGION=""

parse_s3_backend_config() {
    [ ! -f "backend.tf" ] && return
    local in_block=false key val line
    while IFS= read -r line; do
        case "$line" in
            *'backend "s3"'*) in_block=true ;;
            *'}'*)  $in_block && in_block=false ;;
            *)
                if $in_block; then
                    key=$(echo "$line" | sed -n 's/.*\(bucket\|key\|region\)\s*=\s*"\([^"]*\)".*/\1/p')
                    val=$(echo "$line" | sed -n 's/.*\(bucket\|key\|region\)\s*=\s*"\([^"]*\)".*/\2/p')
                    if [ -n "$key" ] && [ -n "$val" ]; then
                        case "$key" in
                            bucket) S3_BUCKET="$val" ;;
                            key)    S3_KEY="$val" ;;
                            region) S3_REGION="$val" ;;
                        esac
                    fi
                fi
                ;;
        esac
    done < backend.tf
}

BACKEND_TYPE=$(detect_backend_type)
if [ "$BACKEND_TYPE" = "s3" ]; then
    parse_s3_backend_config
fi

# ═══════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

# ── Helper: delete S3 state objects for a workspace ─────────────────────────
# When tofu uses an S3 backend, workspace state is stored under:
#   s3://<bucket>/<key>                    ← default workspace
#   s3://<bucket>/env:/<workspace>/<key>    ← named workspaces
# This removes those objects after a successful destroy.
delete_s3_workspace_state() {
    local ws="$1"

    [ "$BACKEND_TYPE" != "s3" ] && return

    if ! command -v aws >/dev/null 2>&1; then
        echo -e "  ${YELLOW}aws CLI not found — skipping S3 state cleanup for '${ws}'.${NC}"
        return
    fi

    if [ -z "$S3_BUCKET" ] || [ -z "$S3_REGION" ]; then
        echo -e "  ${YELLOW}Could not parse S3 bucket/region from backend.tf — skipping S3 cleanup.${NC}"
        return
    fi

    local s3_prefix use_recursive
    if [ "$ws" = "default" ]; then
        # Default workspace state lives at the base key
        s3_prefix="${S3_KEY}"
        use_recursive=false
    else
        # Named workspaces: env:/<workspace>/ — use the directory prefix
        # so --recursive catches all objects under it
        s3_prefix="env:/${ws}/"
        use_recursive=true
    fi

    echo -e "  ${CYAN}Cleaning S3 state: s3://${S3_BUCKET}/${s3_prefix}${NC}"

    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${YELLOW}[DRY RUN] Would delete: s3://${S3_BUCKET}/${s3_prefix}${NC}"
        return
    fi

    local aws_output rc
    if $use_recursive; then
        aws_output=$(aws s3 rm "s3://${S3_BUCKET}/${s3_prefix}" \
            --region "$S3_REGION" \
            --recursive 2>&1) && rc=0 || rc=$?
    else
        aws_output=$(aws s3 rm "s3://${S3_BUCKET}/${s3_prefix}" \
            --region "$S3_REGION" 2>&1) && rc=0 || rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
        if echo "$aws_output" | grep -q "delete:"; then
            echo "$aws_output" | grep "delete:" | sed 's/^/    /'
            echo -e "  ${GREEN}✓ S3 state objects removed for '${ws}'.${NC}"
        else
            echo -e "  ${GREEN}✓ No S3 state objects found for '${ws}' (already clean).${NC}"
        fi
    else
        echo -e "  ${YELLOW}Warning: S3 cleanup failed for '${ws}': ${aws_output}${NC}"
    fi
}

# ── Helper: delete a single workspace ───────────────────────────────────────
delete_single_workspace() {
    local ws="$1"
    if [ "$ws" = "default" ]; then
        echo -e "  ${YELLOW}Cannot delete 'default' workspace — skipping deletion.${NC}"
        return
    fi
    "$TF_CLI" workspace select "default" >/dev/null 2>&1 || true
    if "$TF_CLI" workspace delete "$ws" 2>&1; then
        echo -e "  ${GREEN}✓ Workspace '${ws}' deleted.${NC}"
    else
        echo -e "  ${YELLOW}Could not delete workspace '${ws}' (may still have state).${NC}"
    fi
}

# Derive a readable module name (handles both absolute paths and ".")
if [ "$TOFU_DIR" = "." ]; then
    MODULE_DISPLAY="tofu/$(pwd | sed 's|.*/tofu/||')"
else
    MODULE_DISPLAY=$(echo "$TOFU_DIR" | sed 's|.*/tofu/|tofu/|')
fi

# ── Header ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  Destroy All Workspaces                                        ║${NC}"
echo -e "${BOLD}║  Module:  ${CYAN}${MODULE_DISPLAY}${NC}"
echo -e "${BOLD}║  Backend: ${CYAN}${BACKEND_TYPE}${NC}"
echo -e "${BOLD}║  CLI:     ${CYAN}${TF_CLI}${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}║  Mode:    DRY RUN (no changes will be made)                    ║${NC}"
fi
echo -e "${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Ensure tofu is initialised ──────────────────────────────────────────────
if [ ! -d ".terraform" ]; then
    echo -e "${CYAN}Initializing ${TF_CLI}...${NC}"
    if ! "$TF_CLI" init -input=false; then
        echo -e "${RED}Error: ${TF_CLI} init failed.${NC}" >&2
        exit 1
    fi
    echo ""
fi

# ── Collect workspaces ──────────────────────────────────────────────────────
echo -e "${CYAN}Discovering workspaces...${NC}"
echo ""

CURRENT_WS=$(tofu workspace show 2>/dev/null) || CURRENT_WS="default"

declare -a WORKSPACES=()
while IFS= read -r line; do
    ws_name=$(echo "$line" | sed 's/^[* ]*//' | xargs)
    [ -z "$ws_name" ] && continue
    WORKSPACES+=("$ws_name")
done < <("$TF_CLI" workspace list 2>/dev/null)

if [ ${#WORKSPACES[@]} -eq 0 ]; then
    echo -e "${YELLOW}No workspaces found.${NC}"
    exit 0
fi

echo -e "  Found ${BOLD}${#WORKSPACES[@]}${NC} workspaces. Counting resources..."
echo ""

# ── Count resources per workspace ───────────────────────────────────────────
declare -A WS_RESOURCES=()

for ws in "${WORKSPACES[@]}"; do
    if [ "$ws" != "$CURRENT_WS" ]; then
        if ! "$TF_CLI" workspace select "$ws" >/dev/null 2>&1; then
            echo -e "  ${YELLOW}Warning: Could not select workspace '${ws}' — treating as 0 resources.${NC}"
            WS_RESOURCES["$ws"]=0
            continue
        fi
    fi
    # pipefail-safe count: redirect stderr, tolerate tofu state list failures
    resource_count=$("$TF_CLI" state list 2>/dev/null | wc -l | tr -d ' ') || resource_count=0
    WS_RESOURCES["$ws"]=$resource_count
done

# Restore original workspace
"$TF_CLI" workspace select "$CURRENT_WS" >/dev/null 2>&1 || true

# ── Display summary table ──────────────────────────────────────────────────
printf "  ${BOLD}%-4s %-40s %-12s %-10s${NC}\n" "#" "Workspace" "Resources" "Status"
printf "  %-4s %-40s %-12s %-10s\n" "---" "----------------------------------------" "----------" "----------"

total_resources=0
non_empty=0

for i in "${!WORKSPACES[@]}"; do
    ws="${WORKSPACES[$i]}"
    res="${WS_RESOURCES[$ws]}"
    total_resources=$((total_resources + res))

    if [ "$ws" = "$CURRENT_WS" ]; then
        marker="* current"
    elif [ "$res" -gt 0 ]; then
        marker="active"
        non_empty=$((non_empty + 1))
    else
        marker="empty"
    fi

    printf "  %-4s %-40s %-12s %-10s\n" "$((i+1))" "$ws" "$res" "$marker"
done

echo ""
echo -e "  Total: ${BOLD}${#WORKSPACES[@]}${NC} workspaces, ${BOLD}${total_resources}${NC} resources (${non_empty} non-empty)"
echo ""

# ── Nothing to destroy? ─────────────────────────────────────────────────────
if [ "$total_resources" -eq 0 ]; then
    echo -e "${GREEN}No resources found across any workspace. Nothing to destroy.${NC}"
    echo ""

    # Always clean up orphaned S3 state folders when using S3 backend
    if [ "$BACKEND_TYPE" = "s3" ]; then
        echo -e "${CYAN}Cleaning up S3 state folders...${NC}"
        for ws in "${WORKSPACES[@]}"; do
            delete_s3_workspace_state "$ws"
        done
        echo ""
    fi

    # Optionally delete workspace metadata
    if [ "$DELETE_WORKSPACES" = true ]; then
        for ws in "${WORKSPACES[@]}"; do
            if [ "$ws" != "default" ]; then
                delete_single_workspace "$ws"
            fi
        done
    fi
    exit 0
fi

# ── Dry-run exit ────────────────────────────────────────────────────────────
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}Dry run complete. No changes were made.${NC}"
    exit 0
fi

# ── Global confirmation ─────────────────────────────────────────────────────
if [ "$AUTO_APPROVE" != true ]; then
    echo -e "${RED}⚠  WARNING: This will destroy infrastructure in ALL listed workspaces.${NC}"
    echo ""
    read -rp "Destroy all workspaces? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
fi

# ── Destroy each workspace ──────────────────────────────────────────────────
failed=0
destroyed=0
skipped=0

for ws in "${WORKSPACES[@]}"; do
    res="${WS_RESOURCES[$ws]}"

    echo ""
    echo -e "${BOLD}──────────────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}  Workspace: ${CYAN}${ws}${NC}  (${res} resources)"
    echo -e "${BOLD}──────────────────────────────────────────────────────────────${NC}"

    # Skip empty workspaces
    if [ "$res" -eq 0 ]; then
        echo -e "  ${GREEN}No resources — skipping destroy.${NC}"
        # Clean up any orphaned S3 state even for empty workspaces
        delete_s3_workspace_state "$ws"
        if [ "$DELETE_WORKSPACES" = true ] && [ "$ws" != "default" ]; then
            delete_single_workspace "$ws"
        fi
        skipped=$((skipped + 1))
        continue
    fi

    # Per-workspace confirmation
    if [ "$AUTO_APPROVE" != true ]; then
        echo ""
        read -rp "  Destroy workspace '${ws}' (${res} resources)? [y/N] " ws_confirm
        if [[ ! "$ws_confirm" =~ ^[Yy]$ ]]; then
            echo -e "  ${YELLOW}Skipped.${NC}"
            skipped=$((skipped + 1))
            continue
        fi
    fi

    # Switch to target workspace
    echo -e "  ${CYAN}Switching to workspace '${ws}'...${NC}"
    if ! "$TF_CLI" workspace select "$ws" >/dev/null 2>&1; then
        echo -e "  ${RED}Failed to select workspace '${ws}'. Skipping.${NC}" >&2
        failed=$((failed + 1))
        continue
    fi

    # Run destroy
    echo -e "  ${CYAN}Running ${TF_CLI} destroy...${NC}"
    destroy_rc=0
    if [ ${#VAR_FILE_FLAG[@]} -gt 0 ]; then
        "$TF_CLI" destroy "${VAR_FILE_FLAG[@]}" -auto-approve 2>&1 | sed 's/^/    /' || destroy_rc=$?
    else
        "$TF_CLI" destroy -auto-approve 2>&1 | sed 's/^/    /' || destroy_rc=$?
    fi

    if [ "$destroy_rc" -eq 0 ]; then
        echo -e "  ${GREEN}✓ Workspace '${ws}' destroyed successfully.${NC}"
        destroyed=$((destroyed + 1))

        # Optionally delete the now-empty workspace
        if [ "$DELETE_WORKSPACES" = true ] && [ "$ws" != "default" ]; then
            delete_single_workspace "$ws"
        fi

        # Clean up S3 state folder for this workspace
        delete_s3_workspace_state "$ws"
    else
        echo -e "  ${RED}✗ Failed to destroy workspace '${ws}' (rc=${destroy_rc}).${NC}" >&2
        failed=$((failed + 1))
    fi
done

# ── Switch back to original workspace ───────────────────────────────────────
"$TF_CLI" workspace select "$CURRENT_WS" >/dev/null 2>&1 || true

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Summary${NC}"
echo -e "${BOLD}══════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Destroyed:  ${GREEN}${destroyed}${NC}"
echo -e "  Skipped:    ${YELLOW}${skipped}${NC}"
if [ "$failed" -gt 0 ]; then
    echo -e "  Failed:     ${RED}${failed}${NC}"
fi
echo ""

if [ "$failed" -gt 0 ]; then
    echo -e "${RED}Some workspaces failed to destroy. Review errors above.${NC}" >&2
    exit 1
else
    echo -e "${GREEN}All selected workspaces destroyed successfully.${NC}"
fi
