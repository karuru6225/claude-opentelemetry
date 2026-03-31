#Requires -Version 5.1
param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('apply', 'destroy', 'plan')]
  [string]$Action,

  [string]$Profile = '',

  [switch]$AutoApprove
)

# Usage:
#   .\manage.ps1 plan
#   .\manage.ps1 apply
#   .\manage.ps1 apply  -AutoApprove
#   .\manage.ps1 plan   -Profile myprofile
#   .\manage.ps1 destroy

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Profile) {
  $env:AWS_PROFILE = $Profile
  Write-Host "AWS profile: $Profile"

  Write-Host '==> aws configure export-credentials'
  $credEnv = aws configure export-credentials --profile $Profile --format powershell
  if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to get credentials. Run 'aws login' first and try again."
    exit 1
  }
  Invoke-Expression ($credEnv -join "`n")
}

$BackendFile = 'backend.tfbackend'
$TfvarsFile  = 'terraform.tfvars'

if (-not (Test-Path $BackendFile)) {
  Write-Error "backend.tfbackend not found. Copy backend.tfbackend.example and fill in the values."
  exit 1
}
if (-not (Test-Path $TfvarsFile)) {
  Write-Error "terraform.tfvars not found. Copy terraform.tfvars.example and fill in the values."
  exit 1
}

Write-Host '==> terraform init'
terraform init -backend-config $BackendFile -reconfigure
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($Action -eq 'plan') {
  Write-Host '==> terraform plan'
  terraform plan -var-file $TfvarsFile
}
elseif ($Action -eq 'apply') {
  Write-Host '==> terraform plan'
  terraform plan -var-file $TfvarsFile -out tfplan
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

  if (-not $AutoApprove) {
    $confirm = Read-Host 'Apply? (yes/no)'
    if ($confirm -ne 'yes') {
      Write-Host 'Aborted.'
      Remove-Item -Force tfplan -ErrorAction SilentlyContinue
      exit 0
    }
  }

  Write-Host '==> terraform apply'
  terraform apply tfplan
  Remove-Item -Force tfplan -ErrorAction SilentlyContinue

  Write-Host ''
  Write-Host '==> apply done. Outputs:'
  terraform output
}
elseif ($Action -eq 'destroy') {
  if (-not $AutoApprove) {
    $confirm = Read-Host 'Destroy all resources? (yes/no)'
    if ($confirm -ne 'yes') {
      Write-Host 'Aborted.'
      exit 0
    }
  }

  Write-Host '==> terraform destroy'
  if ($AutoApprove) {
    terraform destroy -var-file $TfvarsFile -auto-approve
  } else {
    terraform destroy -var-file $TfvarsFile
  }
  Write-Host '==> destroy done'
}
