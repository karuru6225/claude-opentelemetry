#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./manage.sh plan
#   ./manage.sh apply
#   ./manage.sh apply --auto-approve
#   ./manage.sh plan   --profile myprofile
#   ./manage.sh destroy

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ACTION=""
PROFILE=""
AUTO_APPROVE=false

usage() {
  echo "Usage: $0 {plan|apply|destroy} [--profile NAME] [--auto-approve|-y]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    plan | apply | destroy)
      ACTION="$1"
      shift
      ;;
    --profile | -Profile)
      [[ $# -ge 2 ]] || usage
      PROFILE="$2"
      shift 2
      ;;
    --auto-approve | -AutoApprove | -y)
      AUTO_APPROVE=true
      shift
      ;;
    -h | --help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

[[ -n "$ACTION" ]] || usage

if [[ -n "$PROFILE" ]]; then
  export AWS_PROFILE="$PROFILE"
  echo "AWS profile: $PROFILE"
  echo "==> aws configure export-credentials"
  # shellcheck disable=SC2046
  eval "$(aws configure export-credentials --profile "$PROFILE" --format env)" || {
    echo "Failed to get credentials. Run 'aws login' first and try again." >&2
    exit 1
  }
fi

BackendFile=backend.tfbackend
TfvarsFile=terraform.tfvars

if [[ ! -f "$BackendFile" ]]; then
  echo "backend.tfbackend not found. Copy backend.tfbackend.example and fill in the values." >&2
  exit 1
fi
if [[ ! -f "$TfvarsFile" ]]; then
  echo "terraform.tfvars not found. Copy terraform.tfvars.example and fill in the values." >&2
  exit 1
fi

echo "==> terraform init"
terraform init -backend-config "$BackendFile" -reconfigure

if [[ "$ACTION" == "plan" ]]; then
  echo "==> terraform plan"
  terraform plan -var-file "$TfvarsFile"
elif [[ "$ACTION" == "apply" ]]; then
  echo "==> terraform plan"
  terraform plan -var-file "$TfvarsFile" -out tfplan

  if [[ "$AUTO_APPROVE" != "true" ]]; then
    read -r -p "Apply? (yes/no) " confirm
    if [[ "$confirm" != "yes" ]]; then
      echo "Aborted."
      rm -f tfplan
      exit 0
    fi
  fi

  echo "==> terraform apply"
  terraform apply tfplan
  rm -f tfplan

  echo ""
  echo "==> apply done. Outputs:"
  terraform output
elif [[ "$ACTION" == "destroy" ]]; then
  if [[ "$AUTO_APPROVE" != "true" ]]; then
    read -r -p "Destroy all resources? (yes/no) " confirm
    if [[ "$confirm" != "yes" ]]; then
      echo "Aborted."
      exit 0
    fi
  fi

  echo "==> terraform destroy"
  if [[ "$AUTO_APPROVE" == "true" ]]; then
    terraform destroy -var-file "$TfvarsFile" -auto-approve
  else
    terraform destroy -var-file "$TfvarsFile"
  fi
  echo "==> destroy done"
fi
