#Requires -Version 5.1
<#
.SYNOPSIS
  Emergency / redeploy: build+push amd64 images for GitOps pins.
  Prefer GitHub Actions workflow_dispatch when OIDC works.
  DEFAULT IS DRY-RUN.

  After ECR IMMUTABLE (Wave 1): never pushes `latest`.
  Rebuilding an existing pin tag with a new digest will FAIL — pass -NewTag.

.EXAMPLE
  .\rebuild-ecr-image-pins.ps1
  .\rebuild-ecr-image-pins.ps1 -Execute -NewTag sha-manual001
  .\rebuild-ecr-image-pins.ps1 -Execute -Service order-service -NewTag sha-manual001
#>
param(
  [switch]$Execute,
  [string]$Service = "all",
  [string]$NewTag = "",
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
if ($NewTag) {
  Write-Host "NewTag override: $NewTag (update image-pins.yaml + kustomization newTag after push)" -ForegroundColor Yellow
}
foreach ($s in $targets) {
  $tag = if ($NewTag) { $NewTag } else { $pins[$s] }
  Write-Host ("  {0} → {1}" -f $s, $tag)
}

if (-not $Execute) {
  Write-Host "Re-run with -Execute to build/push (linux/amd64, single immutable tag)."
  Write-Host "If pin already exists in ECR, use -NewTag sha-<unique>."
  exit 0
}

if (-not $NewTag) {
  Write-Host "WARNING: Pushing existing pin tags under IMMUTABLE will fail if digest changed." -ForegroundColor Yellow
  Write-Host "Prefer -NewTag sha-<unique> then update manifests." -ForegroundColor Yellow
}

aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin $registry
if ($LASTEXITCODE -ne 0) { throw "ECR login failed" }

foreach ($s in $targets) {
  $tag = if ($NewTag) { $NewTag } else { $pins[$s] }
  if ($tag -eq "latest") { throw "Refusing to push banned tag 'latest' (ECR IMMUTABLE contract)." }
  $ctx = Join-Path $BackendRoot "Localy\$s"
  if (-not (Test-Path (Join-Path $ctx "Dockerfile"))) { throw "Missing Dockerfile: $ctx" }
  Write-Host "==== build $s :$tag ====" -ForegroundColor Cyan
  $imgPin = "${registry}/${s}:${tag}"
  docker buildx build --platform linux/amd64 --provenance=false -t $imgPin --push $ctx
  if ($LASTEXITCODE -ne 0) { throw "build/push failed for $s" }
}

Write-Host "Done. If -NewTag was used, update image-pins.yaml + overlay newTag, then check-ecr-image-pins.ps1." -ForegroundColor Green
