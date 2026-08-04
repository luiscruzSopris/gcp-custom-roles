#!/usr/bin/env bash
#
# Creates (or updates) the GCP custom IAM roles defined by the YAML files in
# this directory.
#
# Safe to re-run: a role that already exists is updated in place instead of
# failing, and a role left in the DELETED state is undeleted first.
#
# Usage:
#   ./create_custom_roles.sh                          # uses DEFAULT_PROJECT_ID
#   ./create_custom_roles.sh -p my-project            # target another project
#   ./create_custom_roles.sh --dry-run                # print commands only
#
set -euo pipefail

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

PROJECT_ID="${PROJECT_ID:-$DEFAULT_PROJECT_ID}"
DRY_RUN=false

usage() {
  sed -n '3,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project) PROJECT_ID="${2:-}"; shift 2 ;;
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

# --- Preflight -------------------------------------------------------------

command -v gcloud >/dev/null 2>&1 || die "gcloud CLI not found in PATH."
[[ -n "$PROJECT_ID" ]] || die "No project id given (use -p/--project)."

if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" \
     | grep -q .; then
  die "No active gcloud account. Run: gcloud auth login"
fi

missing=()
for entry in "${ROLES[@]}"; do
  file="${entry#*|}"
  [[ -f "$SCRIPT_DIR/$file" ]] || missing+=("$file")
done
if (( ${#missing[@]} > 0 )); then
  die "Missing role definition file(s): ${missing[*]}"
fi

log "Project : $PROJECT_ID"
log "Roles   : ${#ROLES[@]}"
[[ "$DRY_RUN" == true ]] && log "Mode    : dry-run (no changes will be made)"
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
             --project="$PROJECT_ID" \
             --format="value(deleted)" 2>/dev/null)" && exists=true || exists=false

  if [[ "$exists" == false ]]; then
    log "==> Creating $role_id"
    if run gcloud iam roles create "$role_id" \
         --project="$PROJECT_ID" \
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
           --project="$PROJECT_ID" --quiet; then
      failed+=("$role_id")
      continue
    fi
  fi

  log "==> Updating $role_id (already exists)"
  if run gcloud iam roles update "$role_id" \
       --project="$PROJECT_ID" \
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
