param(
  [Parameter(Mandatory = $true)]
  [string]$DittoRoot,

  [Parameter(Mandatory = $true)]
  [string]$Url,

  [string]$Output = "output/runtime-clone",
  [string]$Viewports = "375,768,1280,1920",
  [switch]$Serve,
  [switch]$Open
)

$ErrorActionPreference = "Stop"
$resolvedRoot = (Resolve-Path -LiteralPath $DittoRoot).Path
$captureModule = Join-Path $resolvedRoot "compiler\src\capture\runtimeMirror.ts"
$generateModule = Join-Path $resolvedRoot "compiler\src\generate\runtimeMirror.ts"

if (-not (Test-Path -LiteralPath $captureModule) -or -not (Test-Path -LiteralPath $generateModule)) {
  throw "This checkout does not contain runtime mirror support. Read references/runtime-mirror-architecture.md."
}

$arguments = @(
  "run",
  "clone",
  "--",
  $Url,
  "--out=$Output",
  "--viewports=$Viewports"
)

if ($Serve) {
  $arguments += "--serve"
}
if ($Open) {
  $arguments += "--open"
}

Push-Location -LiteralPath $resolvedRoot
try {
  & npm @arguments
  if ($LASTEXITCODE -ne 0) {
    throw "ditto.site clone exited with code $LASTEXITCODE"
  }
} finally {
  Pop-Location
}

