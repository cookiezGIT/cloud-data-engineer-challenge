Param(
  [switch]$Rebuild = $true,
  [switch]$Apply = $true,
  [switch]$Upload = $true,
  [switch]$TailLogs = $true,
  [string]$Profile = "nanlabs-dev",
  [string]$Region = "us-east-1",
  [string]$CsvPath = ".\examples\airbnb_listings_sample.csv",
  [int]$Limit = 100,
  [string]$City = ""
)

$ErrorActionPreference = "Stop"

function Fail($msg) { Write-Error $msg; exit 1 }
function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Info($msg) { Write-Host "   $msg" -ForegroundColor Gray }

# Ensure we're at repo root
if (-not (Test-Path ".\docker-compose.yml")) {
  Fail "Please run this script from the repository root (where docker-compose.yml is)."
}

# Tool checks
Step "Checking required tools"
$tools = @(
  @{name="aws"; cmd="aws --version"},
  @{name="terraform"; cmd="terraform -version"},
  @{name="docker"; cmd="docker --version"}
)
foreach ($t in $tools) {
  try { Invoke-Expression $t.cmd | Out-Null; Info "$($t.name): OK" }
  catch { Fail "Missing or not on PATH: $($t.name). Install and retry." }
}

# Optional 'make'
$HasMake = $true
try { make -v | Out-Null } catch { $HasMake = $false }

# AWS env
Step "Setting AWS profile/region"
$env:AWS_SDK_LOAD_CONFIG = "1"
$env:AWS_PROFILE = $Profile
$env:AWS_REGION  = $Region

try {
  $id = aws sts get-caller-identity --output text 2>$null
  if (-not $id) { Fail "AWS credentials not found for profile '$Profile'. Run: aws configure --profile $Profile" }
  else { Info "Caller identity: $id" }
} catch {
  Fail "AWS CLI failed to use profile '$Profile'. Error: $($_.Exception.Message)"
}

# Build lambda zips
if ($Rebuild) {
  Step "Building Lambda deployment zips (Linux wheels via Lambda Docker image)"
  if ($HasMake) {
    make clean
    if ($LASTEXITCODE -ne 0) { Fail "make clean failed" }
    make build-linux-all
    if ($LASTEXITCODE -ne 0) { Fail "make build-linux-all failed" }
  } else {
    $img = "public.ecr.aws/lambda/python:3.10"
    docker run --rm -v "${PWD}:/var/task" -w /var/task $img `
      /bin/sh -lc "rm -rf build/api/package && mkdir -p build/api/package && pip install -r lambda/api/requirements.txt -t build/api/package && cp -r lambda/api/* build/api/package/ && cd build/api/package && zip -r ../../api.zip ."
    if ($LASTEXITCODE -ne 0) { Fail "Docker build for API failed" }

    docker run --rm -v "${PWD}:/var/task" -w /var/task $img `
      /bin/sh -lc "rm -rf build/ingest/package && mkdir -p build/ingest/package && pip install -r lambda/ingest/requirements.txt -t build/ingest/package && cp -r lambda/ingest/* build/ingest/package/ && cd build/ingest/package && zip -r ../../ingest.zip ."
    if ($LASTEXITCODE -ne 0) { Fail "Docker build for Ingest failed" }
  }
  if (-not (Test-Path ".\build\api.zip") -or -not (Test-Path ".\build\ingest.zip")) {
    Fail "Build failed: build\api.zip or build\ingest.zip not found."
  } else {
    Info "Zips ready: build\api.zip, build\ingest.zip"
  }
}

# Terraform apply / outputs
Push-Location "terraform\envs\dev"
try {
  if ($Apply) {
    Step "Terraform init/apply (profile=$Profile, region=$Region)"
    terraform init -upgrade
    if ($LASTEXITCODE -ne 0) { Fail "terraform init failed" }

    terraform apply -var="prefix=renzob-nanlabs" -var="env=dev" -auto-approve
    if ($LASTEXITCODE -ne 0) { Fail "terraform apply failed" }
  } else {
    Step "Terraform outputs (skipping apply)"
  }

  $BUCKET = (terraform output -raw s3_bucket).Trim()
  $API    = (terraform output -raw api_base_url).Trim()
  if (-not $BUCKET -or -not $API) { Fail "Could not read terraform outputs (s3_bucket/api_base_url)." }
  Info "Bucket: $BUCKET"
  Info "API:    $API"
} finally {
  Pop-Location
}

# Upload CSV
if ($Upload) {
  if (-not (Test-Path $CsvPath)) { Fail "CSV not found: $CsvPath" }
  Step "Uploading CSV to s3://$BUCKET/incoming/"
  aws s3 cp $CsvPath "s3://$BUCKET/incoming/$(Split-Path $CsvPath -Leaf)" --content-type text/csv | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail "CSV upload failed" }
  Info "Upload complete."
}

# Tail logs (background job)
if ($TailLogs) {
  Step "Tailing ingest logs; press Ctrl+C to stop"
  try {
    Start-Job -Name "tail-ingest" -ScriptBlock {
      aws logs tail "/aws/lambda/renzob-nanlabs-dev-ingest" --follow
    } | Out-Null
    Start-Sleep -Seconds 2
  } catch {
    Write-Warning "Could not start background log tail: $($_.Exception.Message)"
  }
}

# Query API
Step "Querying API /healthz and /aggregated-data"
try {
  $health = Invoke-WebRequest "$API/healthz" -UseBasicParsing | Select-Object -ExpandProperty Content
  Info "healthz: $health"
} catch {
  Write-Warning "healthz request failed: $($_.Exception.Message)"
}

$qs = if ($City -and $City.Trim().Length -gt 0) { "?city=$([uri]::EscapeDataString($City))&limit=$Limit" } else { "?limit=$Limit" }
try {
  $data = Invoke-WebRequest "$API/aggregated-data$qs" -UseBasicParsing | Select-Object -ExpandProperty Content
  Write-Host $data
} catch {
  Write-Warning "/aggregated-data request failed: $($_.Exception.Message)"
}

Step "Done."
if ($TailLogs) {
  Write-Host "`n(Background job 'tail-ingest' is running. Stop it via: Stop-Job tail-ingest; Remove-Job tail-ingest)" -ForegroundColor Yellow
}
