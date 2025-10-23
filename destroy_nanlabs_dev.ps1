Param(
  [switch]$Force = $false,
  [string]$Profile = "nanlabs-dev",
  [string]$Region = "us-east-1"
)

$ErrorActionPreference = "Stop"

function Fail($msg) { Write-Error $msg; exit 1 }
function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Info($msg) { Write-Host "   $msg" -ForegroundColor Gray }

# Ensure repo root (terraform/envs/dev exists)
if (-not (Test-Path ".\terraform\envs\dev")) {
  Fail "Run this script from the repository root (terraform\envs\dev must exist)."
}

# Confirm
if (-not $Force) {
  Write-Host "This will permanently delete AWS resources deployed by Terraform in env 'dev'." -ForegroundColor Yellow
  $ans = Read-Host "Type 'DESTROY' to continue"
  if ($ans -ne "DESTROY") { Fail "Aborted by user." }
}

# AWS env
Step "Setting AWS profile/region"
$env:AWS_SDK_LOAD_CONFIG = "1"
$env:AWS_PROFILE = $Profile
$env:AWS_REGION  = $Region

try {
  $id = aws sts get-caller-identity --output text 2>$null
  if (-not $id) { Fail "AWS credentials not found for profile '$Profile'." }
  else { Info "Caller identity: $id" }
} catch {
  Fail "AWS CLI failed to use profile '$Profile'. Error: $($_.Exception.Message)"
}

# Helper: empty S3 bucket including versions and delete markers
function Empty-S3BucketVersioned {
  Param([Parameter(Mandatory=$true)][string]$Bucket)

  Step "Emptying S3 bucket s3://$Bucket (including versions)"
  try {
    # Remove all object versions
    $versions = aws s3api list-object-versions --bucket $Bucket --output json | ConvertFrom-Json
    if ($versions.Versions) {
      $toDel = @()
      foreach ($v in $versions.Versions) {
        $toDel += @{ Key = $v.Key; VersionId = $v.VersionId }
      }
      if ($toDel.Count -gt 0) {
        $payload = @{ Objects = $toDel; Quiet = $true } | ConvertTo-Json -Depth 5 -Compress
        $tmp = New-TemporaryFile
        Set-Content -Path $tmp -Value $payload -Encoding ascii
        aws s3api delete-objects --bucket $Bucket --delete file://$tmp | Out-Null
        Remove-Item $tmp -Force
      }
    }
    # Remove delete markers
    if ($versions.DeleteMarkers) {
      $toDel2 = @()
      foreach ($m in $versions.DeleteMarkers) {
        $toDel2 += @{ Key = $m.Key; VersionId = $m.VersionId }
      }
      if ($toDel2.Count -gt 0) {
        $payload2 = @{ Objects = $toDel2; Quiet = $true } | ConvertTo-Json -Depth 5 -Compress
        $tmp2 = New-TemporaryFile
        Set-Content -Path $tmp2 -Value $payload2 -Encoding ascii
        aws s3api delete-objects --bucket $Bucket --delete file://$tmp2 | Out-Null
        Remove-Item $tmp2 -Force
      }
    }
    # Safety: try standard recursive delete (handles unversioned or remnants)
    aws s3 rm "s3://$Bucket" --recursive | Out-Null
    Info "Bucket emptied."
  } catch {
    Write-Warning "Failed to fully empty bucket: $($_.Exception.Message)"
  }
}

# Get terraform outputs (bucket name, api, etc.) to clean dependencies before destroy
Push-Location "terraform\envs\dev"
try {
  Step "Reading Terraform outputs"
  $BUCKET = ""
  try { $BUCKET = (terraform output -raw s3_bucket).Trim() } catch {}
  if ($BUCKET) { Info "Bucket: $BUCKET" } else { Info "Bucket output not found (may not exist yet)." }

  # Empty bucket to allow terraform destroy (if force_destroy=false)
  if ($BUCKET) { Empty-S3BucketVersioned -Bucket $BUCKET }

  # Optional: delete CloudWatch log groups created by Lambda if not managed by TF
  Step "Cleaning Lambda log groups (best-effort)"
  $lgIngest = "/aws/lambda/renzob-nanlabs-dev-ingest"
  $lgApi    = "/aws/lambda/renzob-nanlabs-dev-api"
  foreach ($lg in @($lgIngest,$lgApi)) {
    try {
      $exists = aws logs describe-log-groups --log-group-name-prefix $lg --query "logGroups[?logGroupName=='`"$lg`"'].logGroupName" --output text
      if ($exists -eq $lg) {
        Info "Deleting log group $lg"
        aws logs delete-log-group --log-group-name $lg | Out-Null
      } else { Info "Log group not present: $lg" }
    } catch {
      Write-Warning "Could not delete log group $lg: $($_.Exception.Message)"
    }
  }

  # Finally: terraform destroy
  Step "Running terraform destroy"
  terraform destroy -var="prefix=renzob-nanlabs" -var="env=dev" -auto-approve
  if ($LASTEXITCODE -ne 0) { Fail "terraform destroy failed" }
  else { Info "Terraform destroy completed." }
} finally {
  Pop-Location
}

Step "All done. Verify in AWS console if desired."
