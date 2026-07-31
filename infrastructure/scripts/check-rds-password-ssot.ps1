# Verifies RDS master password ownership chain without printing secrets.
# Expected SSOT: Terraform random_password -> RDS + SM -> ESO -> K8s Secret
#
# Usage (from anywhere with aws/kubectl creds):
#   pwsh ./infrastructure/scripts/check-rds-password-ssot.ps1

$ErrorActionPreference = "Stop"
$region = "ap-northeast-2"
$secretId = "localy-prod-database-credentials"
$ns = "auth-namespace"
$k8sSecret = "localy-keycloak-secret"

Write-Host "== SM shape =="
$smRaw = aws secretsmanager get-secret-value --secret-id $secretId --region $region --query SecretString --output text
$sm = $smRaw | ConvertFrom-Json
$required = @("engine", "host", "port", "username", "password", "database")
$missing = @($required | Where-Object { -not $sm.PSObject.Properties.Name.Contains($_) })
if ($missing.Count -gt 0) {
  Write-Host "FAIL: SM JSON missing keys: $($missing -join ', ') (manual edit often breaks this)"
  exit 1
}
Write-Host "OK: SM keys present; password_length=$($sm.password.Length)"

Write-Host "== SM tags (ownership) =="
$tags = aws secretsmanager describe-secret --secret-id $secretId --region $region --query Tags --output json | ConvertFrom-Json
$ssot = ($tags | Where-Object { $_.Key -eq "localy.io/password-ssot" }).Value
Write-Host "localy.io/password-ssot=$ssot"
if ($ssot -and $ssot -ne "terraform") {
  Write-Host "WARN: unexpected SSOT tag value"
}

Write-Host "== ESO / K8s =="
kubectl -n $ns get externalsecret keycloak-secrets
$k8sPw = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(
  (kubectl -n $ns get secret $k8sSecret -o jsonpath="{.data.KEYCLOAK_DATABASE_PASSWORD}")
))
$match = ($k8sPw -eq $sm.password)
Write-Host "K8s password length=$($k8sPw.Length) matches_SM=$match"
if (-not $match) {
  Write-Host "FAIL: SM and K8s password diverge. Re-sync via TF rotate, not put-secret-value."
  exit 1
}

Write-Host "== Keycloak pods =="
kubectl -n $ns get pods -l app.kubernetes.io/name=keycloak

Write-Host ""
Write-Host "PASS: SM JSON healthy and ESO Secret matches SM."
Write-Host "Rotate only: terraform apply -replace=random_password.db_password (l3-app-integration)."
Write-Host "Never: put-secret-value / modify-db-instance --master-user-password / hand-edit K8s Secret."
