#Requires -Version 5.1
<#
.SYNOPSIS
  Verify ECR has every GitOps image pin from localy-manifests/workloads/image-pins.yaml
  and that each workloads/*/overlays/prod/kustomization.yaml newTag matches.

.EXAMPLE
  .\check-ecr-image-pins.ps1
#>
param(
  [string]$Region = "ap-northeast-2",
  [string]$ManifestsRoot = ""
)

$ErrorActionPreference = "Stop"

if (-not $ManifestsRoot) {
  $ManifestsRoot = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot))) "localy-manifests"
  if (-not (Test-Path $ManifestsRoot)) {
    $ManifestsRoot = "C:\Users\dev\frame3 로드맵 설계용\localy-manifests"
  }
}

$pinsFile = Join-Path $ManifestsRoot "workloads\image-pins.yaml"
if (-not (Test-Path $pinsFile)) { throw "Missing $pinsFile" }

# Minimal YAML map parse for `services:` block (no external module)
$pins = @{}
$inServices = $false
Get-Content $pinsFile | ForEach-Object {
  $line = $_.TrimEnd()
  if ($line -match '^services:\s*$') { $inServices = $true; return }
  if ($inServices) {
    if ($line -match '^\S') { $inServices = $false; return }
    if ($line -match '^\s+([a-z0-9-]+):\s*(\S+)\s*$') {
      $pins[$Matches[1]] = $Matches[2]
    }
  }
}
if ($pins.Count -eq 0) { throw "No services parsed from $pinsFile" }

$fail = 0
Write-Host "Pins file: $pinsFile" -ForegroundColor Cyan
Write-Host "Region: $Region"
Write-Host ""

foreach ($svc in ($pins.Keys | Sort-Object)) {
  $pin = $pins[$svc]
  $kust = Join-Path $ManifestsRoot "workloads\$svc\overlays\prod\kustomization.yaml"
  if (-not (Test-Path $kust)) {
    Write-Host "FAIL $svc : missing $kust" -ForegroundColor Red
    $fail++
    continue
  }
  $kustTag = $null
  $content = Get-Content $kust -Raw
  if ($content -match '(?m)^\s*newTag:\s*(\S+)\s*$') { $kustTag = $Matches[1] }
  if ($kustTag -ne $pin) {
    Write-Host "FAIL $svc : image-pins=$pin kustomization=$kustTag (drift)" -ForegroundColor Red
    $fail++
  } else {
    Write-Host "OK   $svc : pin=$pin matches kustomization" -ForegroundColor Green
  }

  $tagsJson = aws ecr describe-images --repository-name $svc --region $Region --query "imageDetails[].imageTags" --output json 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "FAIL $svc : ECR repo missing or inaccessible" -ForegroundColor Red
    $fail++
    continue
  }
  $flat = @()
  ($tagsJson | ConvertFrom-Json) | ForEach-Object { if ($_ -is [array]) { $flat += $_ } elseif ($_) { $flat += $_ } }
  $flat = $flat | Where-Object { $_ } | Select-Object -Unique
  if ($flat -notcontains $pin) {
    Write-Host "FAIL $svc : ECR missing tag $pin (have: $($flat -join ','))" -ForegroundColor Red
    $fail++
  } else {
    Write-Host "OK   $svc : ECR has $pin" -ForegroundColor Green
  }
}

Write-Host ""
if ($fail -gt 0) {
  Write-Host "FAIL: $fail check(s) failed" -ForegroundColor Red
  exit 1
}
Write-Host "PASS: all image pins present and consistent" -ForegroundColor Green
