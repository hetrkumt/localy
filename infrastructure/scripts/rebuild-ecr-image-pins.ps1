#Requires -Version 5.1
<#
.SYNOPSIS
  Emergency / redeploy: build+push amd64 images for every GitOps pin.
  Prefer GitHub Actions workflow_dispatch when OIDC works.
  DEFAULT IS DRY-RUN.

.EXAMPLE
  .\rebuild-ecr-image-pins.ps1
  .\rebuild-ecr-image-pins.ps1 -Execute
  .\rebuild-ecr-image-pins.ps1 -Execute -Service order-service
#>
param(
  [switch]$Execute,
  [string]$Service = "all",
  [string]$Region = "ap-northeast-2",
  [string]$BackendRoot = "",
  [string]$ManifestsRoot = ""
)

$ErrorActionPreference = "Stop"

if (-not $BackendRoot) {
  $BackendRoot = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot))) "localy-backend"
  if (-not (Test-Path $BackendRoot)) {
    $BackendRoot = "C:\Users\dev\frame3 로드맵 설계용\localy-backend"
  }
}
if (-not $ManifestsRoot) {
  $ManifestsRoot = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot))) "localy-manifests"
  if (-not (Test-Path $ManifestsRoot)) {
    $ManifestsRoot = "C:\Users\dev\frame3 로드맵 설계용\localy-manifests"
  }
}

$pinsFile = Join-Path $ManifestsRoot "workloads\image-pins.yaml"
$pins = @{}
$registry = "533003975005.dkr.ecr.ap-northeast-2.amazonaws.com"
$inServices = $false
Get-Content $pinsFile | ForEach-Object {
  $line = $_.TrimEnd()
  if ($line -match '^registry:\s*(\S+)\s*$') { $registry = $Matches[1]; return }
  if ($line -match '^services:\s*$') { $inServices = $true; return }
  if ($inServices) {
    if ($line -match '^\S') { $inServices = $false; return }
    if ($line -match '^\s+([a-z0-9-]+):\s*(\S+)\s*$') { $pins[$Matches[1]] = $Matches[2] }
  }
}

$targets = if ($Service -eq "all") { $pins.Keys | Sort-Object } else { @($Service) }
foreach ($s in $targets) {
  if (-not $pins.ContainsKey($s)) { throw "Unknown service: $s" }
}

Write-Host "Mode: $(if ($Execute) { 'EXECUTE' } else { 'DRY-RUN' })"
Write-Host "Registry: $registry"
Write-Host "Backend: $BackendRoot"
foreach ($s in $targets) {
  Write-Host ("  {0} → {1} (+ latest)" -f $s, $pins[$s])
}

if (-not $Execute) {
  Write-Host "Re-run with -Execute to build/push (linux/amd64)."
  exit 0
}

aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin $registry
if ($LASTEXITCODE -ne 0) { throw "ECR login failed" }

foreach ($s in $targets) {
  $tag = $pins[$s]
  $ctx = Join-Path $BackendRoot "Localy\$s"
  if (-not (Test-Path (Join-Path $ctx "Dockerfile"))) { throw "Missing Dockerfile: $ctx" }
  Write-Host "==== build $s :$tag ====" -ForegroundColor Cyan
  $imgPin = "${registry}/${s}:${tag}"
  $imgLatest = "${registry}/${s}:latest"
  docker buildx build --platform linux/amd64 --provenance=false -t $imgPin -t $imgLatest --push $ctx
  if ($LASTEXITCODE -ne 0) { throw "build/push failed for $s" }
}

Write-Host "Done. Run check-ecr-image-pins.ps1 next." -ForegroundColor Green
