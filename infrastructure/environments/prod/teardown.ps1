#Requires -Version 5.1
<#
.SYNOPSIS
  Localy prod infrastructure teardown (reverse of l1→l2→l3→l4 apply).

.DESCRIPTION
  Pre-cleans ECR / Karpenter / k8s ALBs / sticky S3, then terraform destroy:
    l4-bootstrap → l3-app-integration → l2-eks → l1-network

  For layers with required vars (l2-eks), uses apply.local.tfvars when present;
  otherwise passes destroy-only placeholders.

  Known blockers handled:
  - ECR repos with images (force delete before TF, or TF fails)
  - Karpenter EC2 left after control-plane gone
  - ALB/NLB created by AWS LB Controller (k8s-*) holding ENIs/subnets
  - Loki S3 Object Lock (COMPLIANCE) — remove from TF state (orphan intentionally)
  - store/cloudtrail S3 force_destroy=false — empty objects+versions first

.PARAMETER SkipConfirm
  Skip interactive "DESTROY" confirmation.

.PARAMETER Region
  AWS region (default ap-northeast-2).

.PARAMETER EnvName
  Environment prefix used in resource names (default prod).

.EXAMPLE
  .\teardown.ps1
  .\teardown.ps1 -SkipConfirm
#>
[CmdletBinding()]
param(
    [switch]$SkipConfirm,
    [string]$Region = "ap-northeast-2",
    [string]$EnvName = "prod"
)

$ErrorActionPreference = "Continue"
$RootPath = $PSScriptRoot
if (-not $RootPath) {
    $RootPath = "C:\Users\dev\frame3 로드맵 설계용\localy\infrastructure\environments\prod"
}

$env:AWS_DEFAULT_REGION = $Region
$env:AWS_REGION = $Region

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==== $Message ====" -ForegroundColor Cyan
}

function Invoke-Aws {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AwsArgs)
    & aws @AwsArgs 2>&1
    return $LASTEXITCODE
}

function Get-AwsText {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AwsArgs)
    $out = & aws @AwsArgs 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($out)) { return @() }
    return ($out -split '\s+' | Where-Object { $_ -and $_.Trim() })
}

function Empty-S3Bucket {
    param([Parameter(Mandatory)][string]$Bucket)
    Write-Host "Emptying s3://$Bucket (objects + versions)..."
    $exists = & aws s3api head-bucket --bucket $Bucket 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  bucket not found / no access — skip"
        return
    }
    # Best-effort recursive delete (current objects)
    & aws s3 rm "s3://$Bucket" --recursive 2>$null | Out-Null
    # Versioned delete (store/cloudtrail may be versioned)
    try {
        $versions = & aws s3api list-object-versions --bucket $Bucket --output json 2>$null | ConvertFrom-Json
        $toDelete = @()
        if ($versions.Versions) {
            foreach ($v in $versions.Versions) {
                $toDelete += @{ Key = $v.Key; VersionId = $v.VersionId }
            }
        }
        if ($versions.DeleteMarkers) {
            foreach ($m in $versions.DeleteMarkers) {
                $toDelete += @{ Key = $m.Key; VersionId = $m.VersionId }
            }
        }
        for ($i = 0; $i -lt $toDelete.Count; $i += 900) {
            $chunk = $toDelete[$i..([Math]::Min($i + 899, $toDelete.Count - 1))]
            $payload = @{ Objects = @($chunk); Quiet = $true } | ConvertTo-Json -Compress -Depth 5
            $tmp = [System.IO.Path]::GetTempFileName()
            # AWS CLI expects Objects array shape
            $json = @{ Objects = @(); Quiet = $true }
            foreach ($o in $chunk) { $json.Objects += $o }
            ($json | ConvertTo-Json -Compress -Depth 5) | Set-Content -Path $tmp -Encoding utf8
            & aws s3api delete-objects --bucket $Bucket --delete "file://$tmp" 2>$null | Out-Null
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
        Write-Host "  emptied ($($toDelete.Count) versioned entries)"
    } catch {
        Write-Host "  version cleanup skipped: $($_.Exception.Message)"
    }
}

function Remove-TfStateResources {
    param(
        [Parameter(Mandatory)][string]$LayerPath,
        [Parameter(Mandatory)][string[]]$Addresses
    )
    if (-not (Test-Path $LayerPath)) { return }
    Push-Location $LayerPath
    try {
        & terraform init -input=false -upgrade 2>&1 | Out-Null
        foreach ($addr in $Addresses) {
            Write-Host "  terraform state rm $addr"
            & terraform state rm $addr 2>$null | Out-Null
        }
    } finally {
        Pop-Location
    }
}

# ---------- Confirm ----------
Write-Host "=========================================" -ForegroundColor Yellow
Write-Host " Localy Infrastructure Teardown"
Write-Host " Root   : $RootPath"
Write-Host " Region : $Region"
Write-Host " Env    : $EnvName"
Write-Host " Order  : l4-bootstrap → l3-app-integration → l2-eks → l1-network"
Write-Host "=========================================" -ForegroundColor Yellow

if (-not $SkipConfirm) {
    $answer = Read-Host "Type DESTROY to permanently delete prod infra"
    if ($answer -ne "DESTROY") {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 1
    }
}

# ---------- [1] ECR force delete (images block terraform destroy) ----------
Write-Step "[1/7] PRE-CLEANUP: Force-delete ECR repositories"
$ecrRepos = @(
    "cart-service",
    "store-service",
    "order-service",
    "edge-service",
    "payment-service",
    "user-service"
)
foreach ($repo in $ecrRepos) {
    Write-Host "Deleting ECR repo: $repo"
    & aws ecr delete-repository --repository-name $repo --force --region $Region 2>$null | Out-Null
}

# ---------- [2] Karpenter / EKS worker EC2 ----------
Write-Step "[2/7] PRE-CLEANUP: Terminate Karpenter / EKS worker EC2 instances"
# Karpenter tags vary by version: nodepool, nodeclaim, managed-by, ec2nodeclass
$tagKeys = @(
    "karpenter.sh/nodepool",
    "karpenter.sh/nodeclaim",
    "karpenter.sh/managed-by",
    "karpenter.k8s.aws/ec2nodeclass"
)
$idSet = [System.Collections.Generic.HashSet[string]]::new()
foreach ($tk in $tagKeys) {
    $ids = Get-AwsText ec2 describe-instances `
        --region $Region `
        --filters "Name=instance-state-name,Values=running,pending,stopping" "Name=tag-key,Values=$tk" `
        --query "Reservations[*].Instances[*].InstanceId" `
        --output text
    foreach ($id in $ids) { [void]$idSet.Add($id) }
}
$eksNodeIds = Get-AwsText ec2 describe-instances `
    --region $Region `
    --filters "Name=instance-state-name,Values=running,pending,stopping" "Name=tag:eks:cluster-name,Values=${EnvName}-eks" `
    --query "Reservations[*].Instances[*].InstanceId" `
    --output text
foreach ($id in $eksNodeIds) { [void]$idSet.Add($id) }

$allIds = @($idSet)
if ($allIds.Count -gt 0) {
    Write-Host "Terminating ($($allIds.Count)): $($allIds -join ', ')"
    & aws ec2 terminate-instances --region $Region --instance-ids @allIds | Out-Null
    Write-Host "Waiting until instances are terminated (max 5 min)..."
    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 15
        $still = Get-AwsText ec2 describe-instances `
            --region $Region `
            --instance-ids @allIds `
            --query "Reservations[*].Instances[?State.Name!='terminated'].InstanceId" `
            --output text
        Write-Host "  remaining: $(if ($still.Count) { $still -join ',' } else { 'none' })"
        if ($still.Count -eq 0) { break }
    } while ((Get-Date) -lt $deadline)
    # Extra settle time for ENIs / SG detach
    Start-Sleep -Seconds 30
} else {
    Write-Host "No Karpenter/EKS worker instances found."
}

# ---------- [3] k8s ALB/NLB + orphan target groups ----------
Write-Step "[3/7] PRE-CLEANUP: Delete k8s-* load balancers and leftover TGs"
$lbArns = Get-AwsText elbv2 describe-load-balancers `
    --region $Region `
    --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-')].LoadBalancerArn" `
    --output text
foreach ($arn in $lbArns) {
    Write-Host "Deleting LB: $arn"
    & aws elbv2 delete-load-balancer --region $Region --load-balancer-arn $arn 2>$null | Out-Null
}
if ($lbArns.Count -gt 0) {
    Write-Host "Waiting 20s for LB ENIs..."
    Start-Sleep -Seconds 20
}

# Orphan target groups often named k8s-*
$tgArns = Get-AwsText elbv2 describe-target-groups `
    --region $Region `
    --query "TargetGroups[?starts_with(TargetGroupName, 'k8s-')].TargetGroupArn" `
    --output text
foreach ($tg in $tgArns) {
    Write-Host "Deleting TG: $tg"
    & aws elbv2 delete-target-group --region $Region --target-group-arn $tg 2>$null | Out-Null
}

# ---------- [4] Empty S3 buckets that block destroy (force_destroy=false) ----------
Write-Step "[4/7] PRE-CLEANUP: Empty sticky S3 buckets"
Empty-S3Bucket -Bucket "${EnvName}-eks-cloudtrail-audit-logs"
Empty-S3Bucket -Bucket "localy-store-images-${EnvName}"
# Loki has Object Lock COMPLIANCE — do NOT try to empty; remove from state instead
Write-Host "Loki vault (${EnvName}-eks-loki-logs-vault) uses Object Lock COMPLIANCE — will state-rm (orphan)."
Write-Host "Keep legacy Loki CMK Enabled (Object-Lock objects); policy SSOT: kms_loki_legacy.tf — do NOT schedule-key-deletion until retention expires."

# ---------- [5] Remove Object-Lock Loki resources from TF state ----------
Write-Step "[5/7] PRE-CLEANUP: terraform state rm Loki Object Lock bucket graph"
$l3 = Join-Path $RootPath "l3-app-integration"
$lokiStateAddrs = @(
    "aws_kms_key_policy.loki_legacy[0]",
    "aws_s3_bucket_policy.loki_logs",
    "aws_s3_bucket_lifecycle_configuration.loki_logs_lifecycle",
    "aws_s3_bucket_server_side_encryption_configuration.loki_logs",
    "aws_s3_bucket_public_access_block.loki_logs",
    "aws_s3_bucket_object_lock_configuration.loki_logs",
    "aws_s3_bucket_versioning.loki_logs",
    "aws_s3_bucket.loki_logs"
)
Remove-TfStateResources -LayerPath $l3 -Addresses $lokiStateAddrs

# ---------- [6] Optional: disable Argo sync / delete apps if cluster still up ----------
Write-Step "[6/7] PRE-CLEANUP: Best-effort kube cleanup (if cluster reachable)"
$clusterName = "${EnvName}-eks"
& aws eks update-kubeconfig --region $Region --name $clusterName 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    # Stop Argo from recreating while we tear LB controllers
    kubectl delete applications.argoproj.io --all -n argocd --wait=false 2>$null | Out-Null
    kubectl delete ingress --all -A --wait=false 2>$null | Out-Null
    kubectl delete targetgroupbindings.elbv2.k8s.aws --all -A --wait=false 2>$null | Out-Null
    Start-Sleep -Seconds 10
} else {
    Write-Host "Cluster kubeconfig unavailable — skip kubectl pre-clean."
}

# ---------- [7] Terraform destroy (reverse apply order) ----------
Write-Step "[7/7] Terraform destroy sequence"
$ErrorActionPreference = "Stop"
$layers = @("l4-bootstrap", "l3-app-integration", "l2-eks", "l1-network")

foreach ($layer in $layers) {
    $layerPath = Join-Path $RootPath $layer
    Write-Host ""
    Write-Host "---> Destroying $layer" -ForegroundColor Green
    if (-not (Test-Path $layerPath)) {
        Write-Warning "Directory missing, skip: $layerPath"
        continue
    }

    Push-Location $layerPath
    try {
        & terraform init -input=false -upgrade
        if ($LASTEXITCODE -ne 0) { throw "terraform init failed for $layer" }

        # Required vars without defaults (l2) live in gitignored apply.local.tfvars.
        # Destroy still needs them for config load even though values won't change remote state.
        $destroyArgs = @("destroy", "-auto-approve", "-input=false")
        $localTfvars = Join-Path $layerPath "apply.local.tfvars"
        if (Test-Path $localTfvars) {
            Write-Host "Using -var-file=apply.local.tfvars"
            # Quote required: PowerShell parses apply.local.tfvars as property access otherwise
            $destroyArgs += "-var-file=$localTfvars"
        } elseif ($layer -eq "l2-eks") {
            Write-Host "No apply.local.tfvars — passing destroy placeholders for required vars"
            $destroyArgs += "-var=admin_ip=127.0.0.1/32"
            $destroyArgs += "-var=chatops_sre_slack_user_ids=[`"U00000000`"]"
        }

        # Before l2: workers may have been recreated during long l3 destroy
        if ($layer -eq "l2-eks") {
            Write-Host "Pre-l2 re-scavenge: terminate any Karpenter/EKS workers still running..."
            $preIds = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($tk in @("karpenter.sh/nodepool", "karpenter.sh/nodeclaim", "karpenter.sh/managed-by", "karpenter.k8s.aws/ec2nodeclass")) {
                foreach ($id in (Get-AwsText ec2 describe-instances --region $Region --filters "Name=instance-state-name,Values=running,pending,stopping" "Name=tag-key,Values=$tk" --query "Reservations[*].Instances[*].InstanceId" --output text)) {
                    [void]$preIds.Add($id)
                }
            }
            foreach ($id in (Get-AwsText ec2 describe-instances --region $Region --filters "Name=instance-state-name,Values=running,pending,stopping" "Name=tag:eks:cluster-name,Values=${EnvName}-eks" --query "Reservations[*].Instances[*].InstanceId" --output text)) {
                [void]$preIds.Add($id)
            }
            if ($preIds.Count -gt 0) {
                Write-Host "Pre-l2 terminate: $($preIds -join ', ')"
                & aws ec2 terminate-instances --region $Region --instance-ids @($preIds) 2>$null | Out-Null
                Start-Sleep -Seconds 45
            }
        }

        Write-Host ("terraform " + ($destroyArgs -join ' '))
        & terraform @destroyArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "terraform destroy failed for $layer (exit $LASTEXITCODE). Re-scavenging workers/LBs then retry..."
            # Re-run Karpenter/EKS instance termination (common l2 blocker)
            $retryIds = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($tk in @("karpenter.sh/nodepool", "karpenter.sh/nodeclaim", "karpenter.sh/managed-by", "karpenter.k8s.aws/ec2nodeclass")) {
                foreach ($id in (Get-AwsText ec2 describe-instances --region $Region --filters "Name=instance-state-name,Values=running,pending,stopping" "Name=tag-key,Values=$tk" --query "Reservations[*].Instances[*].InstanceId" --output text)) {
                    [void]$retryIds.Add($id)
                }
            }
            foreach ($id in (Get-AwsText ec2 describe-instances --region $Region --filters "Name=instance-state-name,Values=running,pending,stopping" "Name=tag:eks:cluster-name,Values=${EnvName}-eks" --query "Reservations[*].Instances[*].InstanceId" --output text)) {
                [void]$retryIds.Add($id)
            }
            if ($retryIds.Count -gt 0) {
                Write-Host "Retry terminate: $($retryIds -join ', ')"
                & aws ec2 terminate-instances --region $Region --instance-ids @($retryIds) 2>$null | Out-Null
            }
            foreach ($arn in (Get-AwsText elbv2 describe-load-balancers --region $Region --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-')].LoadBalancerArn" --output text)) {
                & aws elbv2 delete-load-balancer --region $Region --load-balancer-arn $arn 2>$null | Out-Null
            }
            Start-Sleep -Seconds 60
            & terraform @destroyArgs
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to destroy layer $layer. Aborting remaining layers."
            }
        }
        Write-Host "OK: $layer destroyed" -ForegroundColor Green
    } finally {
        Pop-Location
    }
}

# ---------- Post: orphan sweep ----------
Write-Step "POST: Orphan sweep (best-effort)"
# Any remaining k8s LBs
$lbArns2 = Get-AwsText elbv2 describe-load-balancers `
    --region $Region `
    --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-')].LoadBalancerArn" `
    --output text
foreach ($arn in $lbArns2) {
    & aws elbv2 delete-load-balancer --region $Region --load-balancer-arn $arn 2>$null | Out-Null
}

# Remaining karpenter/eks instances
$left = Get-AwsText ec2 describe-instances `
    --region $Region `
    --filters "Name=instance-state-name,Values=running,pending" "Name=tag:eks:cluster-name,Values=${EnvName}-eks" `
    --query "Reservations[*].Instances[*].InstanceId" `
    --output text
if ($left.Count -gt 0) {
    & aws ec2 terminate-instances --region $Region --instance-ids @left 2>$null | Out-Null
}

Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host " Infrastructure Teardown Completed"
Write-Host " NOTE: Orphan Object-Lock bucket may remain:"
Write-Host "   s3://${EnvName}-eks-loki-logs-vault (COMPLIANCE retention)"
Write-Host " Delete manually after retention expires, or leave empty."
Write-Host "=========================================" -ForegroundColor Green
