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
  - Loki Object-Lock preserve set — bucket + CMK(s) state-rm (no ScheduleKeyDeletion);
    alias deleted in AWS so next apply can recreate alias on a new CMK;
    PendingDeletion keys cancel+enable; writes loki-preserve-set.auto.tfvars
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

function Get-KmsKeyMetadata {
    param([Parameter(Mandatory)][string]$KeyId)
    $json = & aws kms describe-key --region $Region --key-id $KeyId --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return $null }
    return ($json | ConvertFrom-Json).KeyMetadata
}

function Assert-LokiCmkUsable {
    param([Parameter(Mandatory)][string]$KeyId)
    $meta = Get-KmsKeyMetadata -KeyId $KeyId
    if (-not $meta) {
        Write-Warning "Loki CMK not found or inaccessible: $KeyId"
        return $false
    }
    $kid = $meta.KeyId
    $state = $meta.KeyState
    Write-Host "  CMK $kid KeyState=$state"
    if ($state -eq "PendingDeletion") {
        Write-Host "  cancel-key-deletion + enable-key (Object-Lock preserve set)" -ForegroundColor Yellow
        & aws kms cancel-key-deletion --region $Region --key-id $kid 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to cancel-key-deletion for $kid — abort teardown (Object-Lock ciphertext would become undecryptable)."
        }
        & aws kms enable-key --region $Region --key-id $kid 2>&1 | Out-Null
        $meta = Get-KmsKeyMetadata -KeyId $kid
        if (-not $meta -or $meta.KeyState -ne "Enabled") {
            throw "CMK $kid is not Enabled after cancel/enable — abort teardown."
        }
        Write-Host "  CMK $kid restored to Enabled"
    } elseif ($state -ne "Enabled") {
        throw "CMK $kid KeyState=$state (need Enabled for Object-Lock preserve) — abort teardown."
    }
    & aws kms tag-resource --region $Region --key-id $kid --tags `
        "TagKey=ProtectedBy,TagValue=object-lock" `
        "TagKey=PreserveWith,TagValue=${EnvName}-eks-loki-logs-vault" `
        "TagKey=Purpose,TagValue=loki-object-lock-legacy" 2>$null | Out-Null
    return $true
}

function Get-LokiPreserveKeyIds {
    param([string]$LayerPath)
    $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    $aliasName = "alias/${EnvName}-loki-s3-key"
    $aliasTarget = & aws kms list-aliases --region $Region --output json 2>$null | ConvertFrom-Json
    if ($aliasTarget -and $aliasTarget.Aliases) {
        $hit = $aliasTarget.Aliases | Where-Object { $_.AliasName -eq $aliasName } | Select-Object -First 1
        if ($hit -and $hit.TargetKeyId) { [void]$ids.Add($hit.TargetKeyId) }
    }

    # Seed from prior preserve tfvars / TF default when AWS alias already gone
    $preserveTfvars = Join-Path $LayerPath "loki-preserve-set.auto.tfvars"
    if (Test-Path $preserveTfvars) {
        foreach ($line in Get-Content $preserveTfvars) {
            if ($line -match '"([0-9a-fA-F-]{36})"') { [void]$ids.Add($Matches[1]) }
        }
    }
    # Known historical legacy CMK (kms_loki_legacy.tf default)
    [void]$ids.Add("c4e097ff-d777-4c9b-9098-e3d467a15f95")

    return @($ids)
}

function Write-LokiPreserveTfvars {
    param(
        [Parameter(Mandatory)][string]$LayerPath,
        [Parameter(Mandatory)][string[]]$KeyIds
    )
    $sorted = @($KeyIds | Where-Object { $_ } | Sort-Object -Unique)
    if ($sorted.Count -eq 0) { return }
    $path = Join-Path $LayerPath "loki-preserve-set.auto.tfvars"
    $lines = @(
        "# Generated by teardown.ps1 — Loki Object-Lock preserve set",
        "# Do not ScheduleKeyDeletion until retention expires and objects are gone.",
        "# Next L3 apply rebinds AllowLokiIRSACrypto via kms_loki_legacy.tf.",
        "loki_legacy_kms_key_ids = ["
    )
    foreach ($id in $sorted) {
        $lines += "  `"$id`","
    }
    $lines += "]"
    Set-Content -Path $path -Value ($lines -join "`n") -Encoding utf8
    Write-Host "Wrote $path ($($sorted.Count) key id(s))" -ForegroundColor Green
}

function Remove-LokiPreserveSetFromState {
    param([Parameter(Mandatory)][string]$LayerPath)
    if (-not (Test-Path $LayerPath)) { return }
    $prefixes = @(
        "aws_kms_key.loki_s3",
        "aws_kms_alias.loki_s3",
        "aws_kms_key_policy.loki_legacy",
        "data.aws_kms_key.loki_legacy",
        "aws_s3_bucket_policy.loki_logs",
        "aws_s3_bucket_lifecycle_configuration.loki_logs_lifecycle",
        "aws_s3_bucket_server_side_encryption_configuration.loki_logs",
        "aws_s3_bucket_public_access_block.loki_logs",
        "aws_s3_bucket_object_lock_configuration.loki_logs",
        "aws_s3_bucket_versioning.loki_logs",
        "aws_s3_bucket.loki_logs"
    )
    Push-Location $LayerPath
    try {
        & terraform init -input=false -upgrade 2>&1 | Out-Null
        $listed = & terraform state list 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $listed) {
            Write-Host "  (no state list — falling back to fixed addresses)"
            Remove-TfStateResources -LayerPath $LayerPath -Addresses @(
                "aws_kms_alias.loki_s3",
                "aws_kms_key.loki_s3",
                "aws_kms_key_policy.loki_legacy[0]",
                "aws_s3_bucket_policy.loki_logs",
                "aws_s3_bucket_lifecycle_configuration.loki_logs_lifecycle",
                "aws_s3_bucket_server_side_encryption_configuration.loki_logs",
                "aws_s3_bucket_public_access_block.loki_logs",
                "aws_s3_bucket_object_lock_configuration.loki_logs",
                "aws_s3_bucket_versioning.loki_logs",
                "aws_s3_bucket.loki_logs"
            )
            return
        }
        foreach ($addr in $listed) {
            foreach ($p in $prefixes) {
                if ($addr -eq $p -or $addr.StartsWith("$p[")) {
                    Write-Host "  terraform state rm $addr"
                    & terraform state rm $addr 2>$null | Out-Null
                    break
                }
            }
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
# Loki vault: Object Lock COMPLIANCE — never empty; preserve set in step 5

# ---------- [5] Loki Object-Lock preserve set (bucket + CMKs) ----------
Write-Step "[5/7] PRE-CLEANUP: Loki preserve set (bucket + CMK, no ScheduleKeyDeletion)"
$l3 = Join-Path $RootPath "l3-app-integration"
$lokiBucket = "${EnvName}-eks-loki-logs-vault"
$lokiAlias = "alias/${EnvName}-loki-s3-key"

Write-Host "Preserve set:"
Write-Host "  - s3://$lokiBucket (COMPLIANCE Object Lock)"
Write-Host "  - Loki CMK(s) that encrypt locked object versions (Enabled, no deletion schedule)"
Write-Host "  - Next apply: kms_loki_legacy.tf rebinds IRSA on listed key ids"
Write-Host "  - New writes after rebuild: new aws_kms_key.loki_s3 + recreated alias"

$preserveIds = Get-LokiPreserveKeyIds -LayerPath $l3
Write-Host "Candidate CMK ids: $(if ($preserveIds.Count) { $preserveIds -join ', ' } else { '(none yet)' })"

$usableIds = [System.Collections.Generic.List[string]]::new()
foreach ($kid in $preserveIds) {
    try {
        if (Assert-LokiCmkUsable -KeyId $kid) {
            $meta = Get-KmsKeyMetadata -KeyId $kid
            if ($meta) { [void]$usableIds.Add($meta.KeyId) }
        }
    } catch {
        # Missing historical id is OK; PendingDeletion/unusable of a found key aborts
        if ($_.Exception.Message -match "abort teardown") { throw }
        Write-Warning $_.Exception.Message
    }
}

# Free alias name for next apply (keep CMK orphan Enabled)
Write-Host "Deleting KMS alias $lokiAlias (CMK retained)..."
& aws kms delete-alias --region $Region --alias-name $lokiAlias 2>$null | Out-Null

Write-LokiPreserveTfvars -LayerPath $l3 -KeyIds @($usableIds)
Write-Host "terraform state rm Loki preserve-set addresses (bucket + loki CMK + legacy policies)..."
Remove-LokiPreserveSetFromState -LayerPath $l3
Write-Host "Loki preserve set removed from TF state — destroy will not ScheduleKeyDeletion on those CMKs."

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
Write-Host " NOTE: Loki Object-Lock preserve set may remain:"
Write-Host "   s3://${EnvName}-eks-loki-logs-vault (COMPLIANCE retention)"
Write-Host "   Orphan Loki CMK(s) — see l3-app-integration/loki-preserve-set.auto.tfvars"
Write-Host "   Do NOT ScheduleKeyDeletion until retention expires."
Write-Host "   Next apply: import/reuse vault as needed; legacy key policies rebind IRSA."
Write-Host "=========================================" -ForegroundColor Green
