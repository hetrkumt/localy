#Requires -Version 5.1
<#
.SYNOPSIS
  Restore Keycloak admin SSOT (recreate keycloak DB so bootstrap password = SM),
  then align user-service / edge-service client secrets to workload SM paths.
  Does not print secret values.

.EXAMPLE
  .\keycloak-align-oauth.ps1 -Execute
#>
param(
  [switch]$Execute,
  [string]$Region = "ap-northeast-2"
)

$ErrorActionPreference = "Stop"
$ns = "auth-namespace"

function Write-Step([string]$Msg) { Write-Host "==== $Msg ====" -ForegroundColor Cyan }

if (-not $Execute) {
  Write-Host "DRY-RUN: would recreate keycloak DB, restart STS, align client secrets from SM."
  Write-Host "Re-run with -Execute to apply."
  exit 0
}

Write-Step "1) Scale Keycloak to 0"
kubectl -n $ns scale sts keycloak --replicas=0
kubectl -n $ns rollout status sts/keycloak --timeout=180s

Write-Step "2) Recreate database keycloak (idempotent drop/create)"
$job = @"
apiVersion: batch/v1
kind: Job
metadata:
  name: keycloak-recreate-db
  namespace: auth-namespace
spec:
  ttlSecondsAfterFinished: 300
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        karpenter.sh/nodepool: workload
      tolerations:
        - key: workload-only
          operator: Equal
          value: "true"
          effect: NoSchedule
      volumes:
        - name: secret-volume
          secret:
            secretName: localy-keycloak-secret
            items:
              - key: KEYCLOAK_DATABASE_HOST
                path: host
              - key: KEYCLOAK_DATABASE_PASSWORD
                path: password
      containers:
        - name: psql
          image: postgres:15-alpine
          env:
            - name: PGUSER
              value: postgres
            - name: PGDATABASE
              value: localy
          volumeMounts:
            - name: secret-volume
              mountPath: /etc/secrets
              readOnly: true
          command: ["sh","-c"]
          args:
            - |
              set -eu
              export PGHOST="`$(cat /etc/secrets/host)"
              export PGPASSWORD="`$(cat /etc/secrets/password)"
              echo "Terminating sessions on keycloak DB..."
              psql -v ON_ERROR_STOP=1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'keycloak' AND pid <> pg_backend_pid();" || true
              echo "Dropping keycloak..."
              psql -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS keycloak"
              echo "Creating keycloak..."
              psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE keycloak OWNER postgres"
              echo "Done"
"@
$jobFile = Join-Path $env:TEMP "keycloak-recreate-db.yaml"
# Fix PowerShell escaping - write without backtick mess
$jobPlain = @'
apiVersion: batch/v1
kind: Job
metadata:
  name: keycloak-recreate-db
  namespace: auth-namespace
spec:
  ttlSecondsAfterFinished: 300
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        karpenter.sh/nodepool: workload
      tolerations:
        - key: workload-only
          operator: Equal
          value: "true"
          effect: NoSchedule
      volumes:
        - name: secret-volume
          secret:
            secretName: localy-keycloak-secret
            items:
              - key: KEYCLOAK_DATABASE_HOST
                path: host
              - key: KEYCLOAK_DATABASE_PASSWORD
                path: password
      containers:
        - name: psql
          image: postgres:15-alpine
          env:
            - name: PGUSER
              value: postgres
            - name: PGDATABASE
              value: localy
          volumeMounts:
            - name: secret-volume
              mountPath: /etc/secrets
              readOnly: true
          command: ["sh","-c"]
          args:
            - |
              set -eu
              export PGHOST="$(cat /etc/secrets/host)"
              export PGPASSWORD="$(cat /etc/secrets/password)"
              echo "Terminating sessions on keycloak DB..."
              psql -v ON_ERROR_STOP=1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'keycloak' AND pid <> pg_backend_pid();" || true
              echo "Dropping keycloak..."
              psql -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS keycloak"
              echo "Creating keycloak..."
              psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE keycloak OWNER postgres"
              echo "Done"
'@
[IO.File]::WriteAllText($jobFile, $jobPlain.Replace("`r`n","`n"))
kubectl -n $ns delete job keycloak-recreate-db --ignore-not-found | Out-Null
kubectl apply -f $jobFile
kubectl -n $ns wait --for=condition=complete job/keycloak-recreate-db --timeout=180s
kubectl -n $ns logs job/keycloak-recreate-db

Write-Step "3) Scale Keycloak back to 3 (bootstrap admin from SM)"
kubectl -n $ns scale sts keycloak --replicas=3
kubectl -n $ns rollout status sts/keycloak --timeout=300s

Write-Step "4) Wait for admin token (SM password)"
$deadline = (Get-Date).AddMinutes(5)
$tokenOk = $false
while ((Get-Date) -lt $deadline) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $out = kubectl -n $ns exec keycloak-0 -c keycloak -- sh -c 'PASS=$(cat /opt/bitnami/keycloak/secrets/KEYCLOAK_ADMIN_PASSWORD); /opt/bitnami/keycloak/bin/kcadm.sh config credentials --server http://127.0.0.1:8080 --realm master --user admin --password "$PASS" >/tmp/kcadm.out 2>/tmp/kcadm.err; echo EXIT:$?; head -c 120 /tmp/kcadm.err' 2>$null
  $ErrorActionPreference = $prev
  Write-Host $out
  if ($out -match "EXIT:0") { $tokenOk = $true; break }
  Start-Sleep -Seconds 10
}
if (-not $tokenOk) { throw "Admin login still failing after DB recreate" }
Write-Host "Admin SSOT: OK (kcadm login with SM password)"

Write-Step "5) Load workload OAuth secrets from SM (values not printed)"
$userOauth = aws secretsmanager get-secret-value --secret-id /localy/prod/workload/user-oauth --region $Region --query SecretString --output text | ConvertFrom-Json
$edgeOauth = aws secretsmanager get-secret-value --secret-id /localy/prod/workload/edge-oauth --region $Region --query SecretString --output text | ConvertFrom-Json
if (-not $userOauth.clientSecret) { throw "user-oauth missing clientSecret" }
if (-not $edgeOauth.clientSecret) { throw "edge-oauth missing clientSecret" }
Write-Host "user-oauth len=$($userOauth.clientSecret.Length) edge-oauth len=$($edgeOauth.clientSecret.Length)"

Write-Step "6) Ensure clients exist and set secrets via kcadm"
# Pass secrets as env to avoid shell history in files on disk long-term - still brief exposure in argv
$alignScript = @"
set -e
PASS=`$(cat /opt/bitnami/keycloak/secrets/KEYCLOAK_ADMIN_PASSWORD)
/opt/bitnami/keycloak/bin/kcadm.sh config credentials --server http://127.0.0.1:8080 --realm master --user admin --password "`$PASS" >/dev/null

ensure_client() {
  CID=`$(/opt/bitnami/keycloak/bin/kcadm.sh get clients -r localy -q clientId=`$1 --fields id --format csv --noquotes 2>/dev/null | head -1)
  if [ -z "`$CID" ] || [ "`$CID" = "id" ]; then
    echo "CREATE `$1"
    /opt/bitnami/keycloak/bin/kcadm.sh create clients -r localy \
      -s clientId=`$1 -s enabled=true -s publicClient=false \
      -s serviceAccountsEnabled=true -s standardFlowEnabled=true \
      -s directAccessGrantsEnabled=true -s clientAuthenticatorType=client-secret >/dev/null
    CID=`$(/opt/bitnami/keycloak/bin/kcadm.sh get clients -r localy -q clientId=`$1 --fields id --format csv --noquotes | head -1)
  else
    echo "EXISTS `$1"
  fi
  /opt/bitnami/keycloak/bin/kcadm.sh update clients/`$CID -r localy -s secret=`$2 >/dev/null
  echo "SECRET_SET `$1"
}

ensure_client user-service "$($userOauth.clientSecret)"
ensure_client edge-service "$($edgeOauth.clientSecret)"
echo CLIENTS:
/opt/bitnami/keycloak/bin/kcadm.sh get clients -r localy --fields clientId --format csv --noquotes
"@

$prev = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$alignOut = kubectl -n $ns exec keycloak-0 -c keycloak -- sh -c $alignScript 2>$null
$ErrorActionPreference = $prev
Write-Host ($alignOut -replace [regex]::Escape($userOauth.clientSecret), "<redacted>" -replace [regex]::Escape($edgeOauth.clientSecret), "<redacted>")

Write-Step "7) Smoke: client_credentials for user-service"
$smoke = @"
set +e
SECRET='$($userOauth.clientSecret)'
CODE=`$(wget -qO /tmp/cc --server-response --post-data="grant_type=client_credentials&client_id=user-service&client_secret=`$SECRET" \
  http://127.0.0.1:8080/realms/localy/protocol/openid-connect/token 2>&1 | awk '/HTTP\//{print `$2}' | tail -1)
# busybox wget may not support --server-response the same; use kcadm path instead
/opt/bitnami/keycloak/bin/kcadm.sh get users -r localy --fields username --format csv --noquotes 2>/dev/null | head -5
echo SMOKE_USERS_EXIT:`$?
"@
# Simpler smoke with curl from a short-lived approach using kcadm get (already authed)
$ErrorActionPreference = "Continue"
$smokeOut = kubectl -n $ns exec keycloak-0 -c keycloak -- sh -c 'PASS=$(cat /opt/bitnami/keycloak/secrets/KEYCLOAK_ADMIN_PASSWORD); /opt/bitnami/keycloak/bin/kcadm.sh config credentials --server http://127.0.0.1:8080 --realm master --user admin --password "$PASS" >/dev/null; /opt/bitnami/keycloak/bin/kcadm.sh get clients -r localy -q clientId=user-service --fields clientId,id --format csv --noquotes; /opt/bitnami/keycloak/bin/kcadm.sh get clients -r localy -q clientId=edge-service --fields clientId,id --format csv --noquotes' 2>$null
$ErrorActionPreference = $prev
Write-Host "clients:"
Write-Host $smokeOut

# Token smoke via in-pod sh without printing token
$tokenSmoke = @"
set -e
PASS=`$(cat /opt/bitnami/keycloak/secrets/KEYCLOAK_ADMIN_PASSWORD)
# use java/curl if present - try wget POST
SECRET_U='$($userOauth.clientSecret)'
SECRET_E='$($edgeOauth.clientSecret)'
post_token() {
  wget -qO- --post-data="grant_type=client_credentials&client_id=`$1&client_secret=`$2" \
    http://127.0.0.1:8080/realms/localy/protocol/openid-connect/token 2>/dev/null | \
    sed -n 's/.*"access_token":"\([^"]*\)".*/GOT_TOKEN/p' | head -1
}
echo -n "user-service: "; post_token user-service "`$SECRET_U"
echo -n "edge-service: "; post_token edge-service "`$SECRET_E"
"@
$ErrorActionPreference = "Continue"
$tokOut = kubectl -n $ns exec keycloak-0 -c keycloak -- sh -c $tokenSmoke 2>$null
$ErrorActionPreference = $prev
Write-Host ($tokOut -replace [regex]::Escape($userOauth.clientSecret), "<redacted>" -replace [regex]::Escape($edgeOauth.clientSecret), "<redacted>")

if ($tokOut -notmatch "user-service: GOT_TOKEN") { throw "user-service client_credentials smoke failed" }
if ($tokOut -notmatch "edge-service: GOT_TOKEN") { throw "edge-service client_credentials smoke failed" }

Write-Host ""
Write-Host "PASS: admin SSOT restored; OAuth clients aligned; client_credentials smoke OK." -ForegroundColor Green
