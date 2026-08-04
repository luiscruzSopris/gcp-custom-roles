#!/usr/bin/env bash
#
# Creates (or updates) the GCP custom IAM roles defined by the YAML files in
# this directory.
#
# Roles are applied at the ORGANIZATION level by default (sopristec.com), so a
# single definition can be granted in any project under the org. Pass
# --project to apply them to one project instead.
#
# Safe to re-run: a role that already exists is updated in place instead of
# failing, and a role left in the DELETED state is undeleted first.
#
set -euo pipefail

# sopristec.com
DEFAULT_ORGANIZATION_ID="698696315274"
DEFAULT_PROJECT_ID="ssa-backend-services-dev"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Role definitions, one per line: "<role-id>|<yaml-file>".
# The role id must match ^[a-zA-Z0-9_.]{3,64}$ (no dashes allowed by GCP).
ROLES=(
  "swEngineer_v1|sw_engineer_v1.yaml"
  "databaseAdmin_v1|database_admin_v1.yaml"
  "dataAnalysis_v1|data_analysis_v1.yaml"
  "dataEngineer_v1|data_engineer_v1.yaml"
  "machineLearningEngineer_v1|machine_learning_v1.yaml"
  "platformEngineer_v1|platform_engineer_v1.yaml"
  "projectOperator_v1|project_operator_v1.yaml"
  "observabilityMonitoringOperator_v1|observability_and_monitoring_v1.yaml"
  "securityAdmin_v1|security_admin_v1.yaml"
  "networkAdmin_v1|network_admin_v1.yaml"
  "firebaseEngineer_v1|firebase_engineer_v1.yaml"
  "observer_v1|observer_v1.yaml"
)

ORGANIZATION_ID="${ORGANIZATION_ID:-$DEFAULT_ORGANIZATION_ID}"
PROJECT_ID="${PROJECT_ID:-$DEFAULT_PROJECT_ID}"
SCOPE="organization"
DRY_RUN=false

usage() {
  cat <<'EOF'
Create or update the Sopris GCP custom IAM roles from the YAML files here.

Usage:
  ./create_custom_roles.sh                     # org level (sopristec.com)
  ./create_custom_roles.sh -o ORG_ID           # another organization
  ./create_custom_roles.sh -p PROJECT_ID       # project level instead
  ./create_custom_roles.sh --dry-run           # print commands, change nothing

Options:
  -o, --organization [ID]  Apply at the organization level (default).
                           Requires roles/iam.organizationRoleAdmin.
  -p, --project [ID]       Apply to a single project instead.
                           Requires roles/iam.roleAdmin on that project.
  -n, --dry-run            Show what would run without applying it.
  -h, --help               This message.

Environment overrides: ORGANIZATION_ID, PROJECT_ID
EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--organization)
      SCOPE="organization"
      # ID is optional; falls back to the default org.
      if [[ -n "${2:-}" && "$2" != -* ]]; then ORGANIZATION_ID="$2"; shift; fi
      shift ;;
    -p|--project)
      SCOPE="project"
      if [[ -n "${2:-}" && "$2" != -* ]]; then PROJECT_ID="$2"; shift; fi
      shift ;;
    -n|--dry-run) DRY_RUN=true; shift ;;
    -h|--help)    usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run() {
  if [[ "$DRY_RUN" == true ]]; then
    log "  [dry-run] $*"
  else
    "$@"
  fi
}

# --- Resolve scope ---------------------------------------------------------

if [[ "$SCOPE" == "organization" ]]; then
  [[ -n "$ORGANIZATION_ID" ]] || die "No organization id given (use -o/--organization)."
  SCOPE_FLAG=("--organization=$ORGANIZATION_ID")
  SCOPE_LABEL="organizations/$ORGANIZATION_ID"
else
  [[ -n "$PROJECT_ID" ]] || die "No project id given (use -p/--project)."
  SCOPE_FLAG=("--project=$PROJECT_ID")
  SCOPE_LABEL="projects/$PROJECT_ID"
fi

# --- Preflight -------------------------------------------------------------

command -v gcloud >/dev/null 2>&1 || die "gcloud CLI not found in PATH."

if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" \
     | grep -q .; then
  die "No active gcloud account. Run: gcloud auth login"
fi

# Probe the permission the script actually needs (iam.roles.*) so we fail once
# with a clear message instead of 12 permission errors in a row.
account="$(gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -1)"

if ! gcloud iam roles list "${SCOPE_FLAG[@]}" --limit=1 >/dev/null 2>&1; then
  if [[ "$SCOPE" == "organization" ]]; then
    die "$account cannot manage custom roles in organizations/$ORGANIZATION_ID.
       Grant roles/iam.organizationRoleAdmin at the org level:
         gcloud organizations add-iam-policy-binding $ORGANIZATION_ID \\
           --member=user:$account --role=roles/iam.organizationRoleAdmin
       Or apply the roles to a single project instead:
         $0 --project $DEFAULT_PROJECT_ID"
  else
    die "$account cannot manage custom roles in projects/$PROJECT_ID.
       Grant roles/iam.roleAdmin on that project (or check the project id)."
  fi
fi

missing=()
for entry in "${ROLES[@]}"; do
  file="${entry#*|}"
  [[ -f "$SCRIPT_DIR/$file" ]] || missing+=("$file")
done
if (( ${#missing[@]} > 0 )); then
  die "Missing role definition file(s): ${missing[*]}"
fi

log "Scope : $SCOPE_LABEL"
log "Roles : ${#ROLES[@]}"
[[ "$DRY_RUN" == true ]] && log "Mode  : dry-run (no changes will be made)"
log ""

# --- Apply -----------------------------------------------------------------

created=0
updated=0
failed=()

for entry in "${ROLES[@]}"; do
  role_id="${entry%%|*}"
  file="$SCRIPT_DIR/${entry#*|}"

  # `describe` on a missing role exits non-zero; on a soft-deleted role it
  # succeeds and reports deleted: true.
  state="$(gcloud iam roles describe "$role_id" \
             "${SCOPE_FLAG[@]}" \
             --format="value(deleted)" 2>/dev/null)" && exists=true || exists=false

  if [[ "$exists" == false ]]; then
    log "==> Creating $role_id"
    if run gcloud iam roles create "$role_id" \
         "${SCOPE_FLAG[@]}" \
         --file="$file" \
         --quiet; then
      created=$((created + 1))
    else
      failed+=("$role_id")
    fi
    continue
  fi

  if [[ "$state" == "True" || "$state" == "true" ]]; then
    log "==> Undeleting $role_id"
    if ! run gcloud iam roles undelete "$role_id" \
           "${SCOPE_FLAG[@]}" --quiet; then
      failed+=("$role_id")
      continue
    fi
  fi

  log "==> Updating $role_id (already exists)"
  if run gcloud iam roles update "$role_id" \
       "${SCOPE_FLAG[@]}" \
       --file="$file" \
       --quiet; then
    updated=$((updated + 1))
  else
    failed+=("$role_id")
  fi
done

# --- Summary ---------------------------------------------------------------

log ""
log "Created: $created   Updated: $updated   Failed: ${#failed[@]}"
if (( ${#failed[@]} > 0 )); then
  log "Failed roles: ${failed[*]}"
  exit 1
fi
log "Done."
