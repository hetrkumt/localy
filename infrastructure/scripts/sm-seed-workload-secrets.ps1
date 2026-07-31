#Requires -Version 5.1
<#
.SYNOPSIS
  LEGACY / emergency only.

  Workload SM paths (/localy/prod/workload/*) are owned by Terraform L3:
    infrastructure/environments/prod/l3-app-integration/secrets_workload.tf

  Prefer:
    terraform -chdir=.../l3-app-integration apply

  Use this script only if TF state cannot be applied and you must unblock ESO.
  DEFAULT IS DRY-RUN.

.EXAMPLE
  .\sm-seed-workload-secrets.ps1
  .\sm-seed-workload-secrets.ps1 -Execute
#>
param(
  [switch]$Execute,
  [string]$Region = "ap-northeast-2"
)

$ErrorActionPreference = "Stop"

function Test-SecretExists([string]$Name) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  aws secretsmanager describe-secret --secret-id $Name --region $Region 2>$null | Out-Null
  $ok = ($LASTEXITCODE -eq 0)
  $ErrorActionPreference = $prev
  return $ok
}

function Ensure-Secret([string]$Name, [string]$Description, [hashtable]$Payload) {
  Write-Host "---- $Name ----"
  $exists = Test-SecretExists $Name
  Write-Host "  status : $(if ($exists) { 'EXISTS' } else { 'MISSING' })"
  if (-not $Execute) {
    Write-Host "  action : skip (dry-run)"
    return
  }
  # Write JSON via file:// to avoid PowerShell arg-splitting of --secret-string
  $tmp = Join-Path $env:TEMP ("sm-seed-" + [Guid]::NewGuid().ToString() + ".json")
  $json = ($Payload | ConvertTo-Json -Compress)
  [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
  $fileUri = "file://" + ($tmp -replace '\\', '/')
  try {
    if ($exists) {
      Write-Host "  action : put-secret-value (overwrite)"
      aws secretsmanager put-secret-value --secret-id $Name --secret-string $fileUri --region $Region | Out-Null
    } else {
      Write-Host "  action : create-secret"
      aws secretsmanager create-secret --name $Name --description $Description --secret-string $fileUri --region $Region | Out-Null
    }
    if ($LASTEXITCODE -ne 0) { throw "Failed to write $Name (exit $LASTEXITCODE)" }
    # Verify JSON keys only
    $verify = aws secretsmanager get-secret-value --secret-id $Name --region $Region --query SecretString --output text
    $obj = $verify | ConvertFrom-Json
    $keys = @($obj.PSObject.Properties.Name) -join ","
    Write-Host "  action : OK (keys=$keys)"
  } finally {
    Remove-Item -Force $tmp -ErrorAction SilentlyContinue
  }
}

function New-RandomSecret {
  $bytes = New-Object byte[] 32
  [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  return [Convert]::ToBase64String($bytes)
}

function Get-OrEnsure-KeycloakClientSecret([string]$ClientId) {
  # Uses kcadm inside keycloak-0. Prints only status lines, never the secret.
  $script = @'
set -e
PASS=$(cat /opt/bitnami/keycloak/secrets/KEYCLOAK_ADMIN_PASSWORD)
/opt/bitnami/keycloak/bin/kcadm.sh config credentials --server http://127.0.0.1:8080 --realm master --user admin --password "$PASS" >/dev/null
CID=$(/opt/bitnami/keycloak/bin/kcadm.sh get clients -r localy -q clientId=CLIENT_ID_PLACEHOLDER --fields id --format csv --noquotes 2>/dev/null | head -1)
if [ -z "$CID" ] || [ "$CID" = "id" ]; then
  echo "CREATE_CLIENT" >&2
  /opt/bitnami/keycloak/bin/kcadm.sh create clients -r localy -s clientId=CLIENT_ID_PLACEHOLDER -s enabled=true -s publicClient=false -s serviceAccountsEnabled=true -s standardFlowEnabled=true -s directAccessGrantsEnabled=true -s clientAuthenticatorType=client-secret >/dev/null
  CID=$(/opt/bitnami/keycloak/bin/kcadm.sh get clients -r localy -q clientId=CLIENT_ID_PLACEHOLDER --fields id --format csv --noquotes | head -1)
fi
SECRET=$(/opt/bitnami/keycloak/bin/kcadm.sh get clients/$CID/client-secret -r localy --fields value --format csv --noquotes 2>/dev/null | tail -1)
if [ -z "$SECRET" ] || [ "$SECRET" = "value" ]; then
  echo "SECRET_EMPTY" >&2
  exit 3
fi
printf '%s' "$SECRET"
'@
  $script = $script.Replace("CLIENT_ID_PLACEHOLDER", $ClientId)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $out = kubectl -n auth-namespace exec keycloak-0 -c keycloak -- sh -c $script 2>$null
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -ne 0 -or [string]::IsNullOrWhiteSpace($out)) {
    return $null
  }
  $lines = @($out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  if ($lines.Count -eq 0) { return $null }
  return $lines[-1]
}

Write-Host "Mode: $(if ($Execute) { 'EXECUTE' } else { 'DRY-RUN' })"
Write-Host "Region: $Region"
Write-Host ""

$masterRaw = aws secretsmanager get-secret-value --secret-id localy-prod-database-credentials --region $Region --query SecretString --output text
if ($LASTEXITCODE -ne 0) { throw "Failed to read localy-prod-database-credentials" }
$master = $masterRaw | ConvertFrom-Json
foreach ($k in @("host", "port", "username", "password")) {
  if (-not $master.PSObject.Properties.Name.Contains($k)) { throw "Master secret missing key: $k" }
}
Write-Host "Master SM: required keys present (password_length=$($master.password.Length))"

$msk = aws ssm get-parameter --name /localy/prod/apps/msk/bootstrap_servers --region $Region --query Parameter.Value --output text
$bucket = aws ssm get-parameter --name /localy/prod/apps/s3/store_bucket_name --region $Region --query Parameter.Value --output text
$kmsArn = aws ssm get-parameter --name /localy/prod/apps/kms/store_key_arn --region $Region --query Parameter.Value --output text
Write-Host "SSM: msk/bucket/kms resolved"
Write-Host ""

$orderPayload = @{
  host = $master.host; port = "$($master.port)"; username = $master.username
  password = $master.password; msk_bootstrap_servers = $msk
}
$paymentPayload = @{
  host = $master.host; port = "$($master.port)"; username = $master.username
  password = $master.password; msk_bootstrap_servers = $msk
}
$storePayload = @{
  username = $master.username; password = $master.password
  s3_bucket_name = $bucket; kms_key_arn = $kmsArn
}
# Redis AuthTokenEnabled=false — empty password is correct
$cartPayload = @{ password = "" }

Ensure-Secret "/localy/prod/workload/order-db" "order-service RDS+MSK connection" $orderPayload
Ensure-Secret "/localy/prod/workload/payment-db" "payment-service RDS+MSK connection" $paymentPayload
Ensure-Secret "/localy/prod/workload/store-db" "store-service RDS+S3+KMS connection" $storePayload
Ensure-Secret "/localy/prod/workload/cart-redis" "cart-service Redis password (blank when auth disabled)" $cartPayload

Write-Host ""
Write-Host "Keycloak client secrets..."
$userSecret = $null
$edgeSecret = $null
try { $userSecret = Get-OrEnsure-KeycloakClientSecret "user-service" } catch { Write-Host "  user-service: $($_.Exception.Message)" }
try { $edgeSecret = Get-OrEnsure-KeycloakClientSecret "edge-service" } catch { Write-Host "  edge-service: $($_.Exception.Message)" }

if ($userSecret) { Write-Host "  user-service: ok (len=$($userSecret.Length))" }
else {
  $userSecret = New-RandomSecret
  Write-Host "  user-service: fallback random (len=$($userSecret.Length))"
}
if ($edgeSecret) { Write-Host "  edge-service: ok (len=$($edgeSecret.Length))" }
else {
  $edgeSecret = New-RandomSecret
  Write-Host "  edge-service: fallback random (len=$($edgeSecret.Length))"
}

Ensure-Secret "/localy/prod/workload/user-oauth" "user-service Keycloak client secret" @{ clientSecret = $userSecret }
Ensure-Secret "/localy/prod/workload/edge-oauth" "edge-service Keycloak client secret" @{ clientSecret = $edgeSecret }

Write-Host ""
Write-Host "Done."
if (-not $Execute) { Write-Host "Re-run with -Execute to write Secrets Manager." }
