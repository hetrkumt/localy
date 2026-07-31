#Requires -Version 5.1
<#
.SYNOPSIS
  LEGACY / emergency only.

  Platform Grafana SM (/localy/prod/platform/grafana) is owned by Terraform L3:
    infrastructure/environments/prod/l3-app-integration/secrets_platform.tf

  Workload oauth paths are owned by secrets_workload.tf.

  Prefer:
    terraform -chdir=.../l3-app-integration apply

  Use this script only if TF state cannot be applied and you must unblock ESO.
  DEFAULT IS DRY-RUN.

.EXAMPLE
  .\sm-migrate-oauth-grafana.ps1
  .\sm-migrate-oauth-grafana.ps1 -Execute
#>
param(
  [switch]$Execute,
  [string]$Region = "ap-northeast-2"
)

$ErrorActionPreference = "Continue"

$secrets = @(
  @{
    Name        = "/localy/prod/workload/user-oauth"
    Description = "LEGACY seed — prefer secrets_workload.tf"
    Template    = '{"clientSecret":"REPLACE_ME_USER_CLIENT_SECRET"}'
    MigrateFrom = "/localy/prod/workload/jwt-secret property=clientSecret"
  },
  @{
    Name        = "/localy/prod/workload/edge-oauth"
    Description = "LEGACY seed — prefer secrets_workload.tf"
    Template    = '{"clientSecret":"REPLACE_ME_EDGE_CLIENT_SECRET"}'
    MigrateFrom = "/localy/prod/workload/jwt-secret property=edgeClientSecret"
  },
  @{
    Name        = "/localy/prod/platform/grafana"
    Description = "LEGACY seed — prefer secrets_platform.tf"
    Template    = '{"admin-user":"admin","admin-password":"REPLACE_ME_GRAFANA_ADMIN_PASSWORD"}'
    MigrateFrom = "n/a (new platform secret)"
  }
)

Write-Host "Mode: $(if ($Execute) { 'EXECUTE (will create secrets)' } else { 'DRY-RUN (no AWS writes)' })"
Write-Host "Region: $Region"
Write-Host "NOTE: Terraform L3 is SSOT for these paths. Prefer terraform apply."
Write-Host ""

foreach ($s in $secrets) {
  Write-Host "---- $($s.Name) ----"
  Write-Host "  description : $($s.Description)"
  Write-Host "  migrateFrom : $($s.MigrateFrom)"
  Write-Host "  payload     : $($s.Template)"

  aws secretsmanager describe-secret --secret-id $s.Name --region $Region 2>$null | Out-Null
  $exists = ($LASTEXITCODE -eq 0)
  Write-Host "  status      : $(if ($exists) { 'EXISTS' } else { 'MISSING' })"

  if (-not $Execute) {
    Write-Host "  action      : skip (dry-run)"
    continue
  }

  if ($exists) {
    Write-Host "  action      : skip create (already exists)"
    continue
  }

  aws secretsmanager create-secret `
    --name $s.Name `
    --description $s.Description `
    --secret-string $s.Template `
    --region $Region
  if ($LASTEXITCODE -eq 0) {
    Write-Host "  action      : CREATED (rotate REPLACE_ME_* via put-secret-value)"
  } else {
    Write-Host "  action      : CREATE FAILED (exit $LASTEXITCODE)"
  }
}

Write-Host ""
Write-Host "Done."
