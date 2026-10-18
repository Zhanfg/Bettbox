# Smart V11 bundled Lite LightGBM asset — pinned, reproducible build input.
# Origin: https://github.com/vernesong/mihomo/releases/tag/LightGBM-Model
# Asset: Model.bin (smallest published LightGBM model, 9,345,218 bytes)
# The release SHA-256 digest was verified through GitHub release metadata.
$ErrorActionPreference = 'Stop'
$expectedSha = '23633022a815fb34e510befe1c176ba50af3ced48f08b172454f4cd6b8327788'
$expectedSize = 9345218
$uri = 'https://github.com/vernesong/mihomo/releases/download/LightGBM-Model/Model.bin'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$destination = Join-Path $projectRoot 'assets/data/Model-Lite.bin'
New-Item -Path (Split-Path $destination) -ItemType Directory -Force | Out-Null

function Test-Model {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  $file = Get-Item -LiteralPath $Path
  if ($file.Length -ne $expectedSize) { return $false }
  $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  return $actual -eq $expectedSha
}

if (Test-Model -Path $destination) {
  Write-Host "Verified preexisting Lite model: $destination"
  exit 0
}

$temp = "$destination.download"
try {
  if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
  Write-Host 'Fetching verified Lite model for offline package...'
  & curl.exe --fail --location --retry 4 --retry-delay 3 --connect-timeout 20 --max-time 240 --output $temp $uri
  if ($LASTEXITCODE -ne 0) { throw "curl exited with code $LASTEXITCODE" }
  if (-not (Test-Model -Path $temp)) {
    throw "Lite model release SHA-256/size mismatch; refusing to create an unverified package."
  }
  Move-Item -LiteralPath $temp -Destination $destination -Force
  Write-Host "Bundled Lite model SHA256: $expectedSha ($expectedSize bytes)"
} finally {
  if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
}
