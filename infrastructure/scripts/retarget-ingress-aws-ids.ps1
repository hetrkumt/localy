#Requires -Version 5.1
<#
.SYNOPSIS
  Retarget alb-controller vpcId + Ingress/KPS ACM/WAF ARNs from live SSM (post-rebuild).

.DESCRIPTION
  SSOT for these IDs is Terraform → SSM:
    /localy/prod/network/vpc_id
    /localy/prod/apps/acm/cert_arn
    /localy/prod/apps/waf/arn
  This script copies those values into Git manifests under localy-manifests.
  Commit + push so Argo selfHeal does not revert live patches.

.EXAMPLE
  .\retarget-ingress-aws-ids.ps1
  .\retarget-ingress-aws-ids.ps1 -ApplyLive
#>
[CmdletBinding()]
param(
    [string]$Region = "ap-northeast-2",
    [string]$ManifestsRoot = "",
    [switch]$ApplyLive
)

$ErrorActionPreference = "Stop"
$env:AWS_DEFAULT_REGION = $Region

if (-not $ManifestsRoot) {
    $ManifestsRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "localy-manifests"
    if (-not (Test-Path $ManifestsRoot)) {
        $ManifestsRoot = "C:\Users\dev\frame3 로드맵 설계용\localy-manifests"
    }
}

function Get-Ssm([string]$Name) {
    $v = aws ssm get-parameter --name $Name --region $Region --query Parameter.Value --output text
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($v)) {
        throw "SSM parameter missing or empty: $Name"
    }
    return $v.Trim()
}

$vpcId = Get-Ssm "/localy/prod/network/vpc_id"
$acmArn = Get-Ssm "/localy/prod/apps/acm/cert_arn"
$wafArn = Get-Ssm "/localy/prod/apps/waf/arn"

Write-Host "vpcId = $vpcId"
Write-Host "acm   = $acmArn"
Write-Host "waf   = $wafArn"

$files = @(
    (Join-Path $ManifestsRoot "apps\alb-controller\values-prod.yaml"),
    (Join-Path $ManifestsRoot "apps\ingress-core\base\ingress.yaml"),
    (Join-Path $ManifestsRoot "apps\ingress-core\base\external-keycloak-ingress.yaml"),
    (Join-Path $ManifestsRoot "apps\ingress-core\base\internal-edge-ingress.yaml"),
    (Join-Path $ManifestsRoot "apps\ingress-core\overlays\prod\patch-ingress.yaml"),
    (Join-Path $ManifestsRoot "apps\kube-prometheus-stack\values-prod.yaml")
)

foreach ($f in $files) {
    if (-not (Test-Path $f)) {
        Write-Warning "skip missing: $f"
        continue
    }
    $raw = Get-Content -Path $f -Raw -Encoding utf8
    $updated = $raw
    $updated = [regex]::Replace($updated, 'vpcId:\s*"[^"]+"', "vpcId: `"$vpcId`"")
    $updated = [regex]::Replace(
        $updated,
        'alb\.ingress\.kubernetes\.io/certificate-arn:\s*"[^"]+"',
        "alb.ingress.kubernetes.io/certificate-arn: `"$acmArn`""
    )
    $updated = [regex]::Replace(
        $updated,
        'alb\.ingress\.kubernetes\.io/wafv2-acl-arn:\s*"[^"]+"',
        "alb.ingress.kubernetes.io/wafv2-acl-arn: `"$wafArn`""
    )
    if ($updated -ne $raw) {
        Set-Content -Path $f -Value $updated -Encoding utf8 -NoNewline
        Write-Host "updated $f"
    } else {
        Write-Host "unchanged $f"
    }
}

if ($ApplyLive) {
    Write-Host "Applying live vpcId to aws-load-balancer-controller..."
    $deploy = kubectl -n kube-system get deploy aws-load-balancer-controller -o json | ConvertFrom-Json
    $args = @($deploy.spec.template.spec.containers[0].args)
    $newArgs = foreach ($a in $args) {
        if ($a -like '--aws-vpc-id=*') { "--aws-vpc-id=$vpcId" } else { $a }
    }
    $patch = @{
        spec = @{
            template = @{
                spec = @{
                    containers = @(
                        @{
                            name = $deploy.spec.template.spec.containers[0].name
                            args = @($newArgs)
                        }
                    )
                }
            }
        }
    } | ConvertTo-Json -Depth 10 -Compress
    $tmp = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $tmp -Value $patch -Encoding utf8
    kubectl -n kube-system patch deploy aws-load-balancer-controller --type strategic --patch-file $tmp
    Remove-Item $tmp -Force

    $ingresses = @(
        @{ Ns = "auth-namespace"; Name = "localy-external-alb-keycloak"; Waf = $true },
        @{ Ns = "edge-service"; Name = "localy-external-alb-edge"; Waf = $true },
        @{ Ns = "edge-service"; Name = "localy-internal-alb-edge"; Waf = $false }
    )
    foreach ($ing in $ingresses) {
        $exists = kubectl get ingress $ing.Name -n $ing.Ns 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "ingress missing: $($ing.Ns)/$($ing.Name)"
            continue
        }
        kubectl annotate ingress $ing.Name -n $ing.Ns --overwrite `
            "alb.ingress.kubernetes.io/certificate-arn=$acmArn" | Out-Null
        if ($ing.Waf) {
            kubectl annotate ingress $ing.Name -n $ing.Ns --overwrite `
                "alb.ingress.kubernetes.io/wafv2-acl-arn=$wafArn" | Out-Null
        }
        Write-Host "annotated $($ing.Ns)/$($ing.Name)"
    }
}

Write-Host "Done. Commit + push localy-manifests so Argo selfHeal keeps these values."
