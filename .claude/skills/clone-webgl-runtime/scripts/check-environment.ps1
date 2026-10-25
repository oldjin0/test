param(
  [Parameter(Mandatory = $true)]
  [string]$DittoRoot
)

$ErrorActionPreference = "Stop"
$resolvedRoot = (Resolve-Path -LiteralPath $DittoRoot).Path
$issues = [System.Collections.Generic.List[string]]::new()

function Resolve-CommandVersion {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Command,
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $entry = Get-Command $Command -ErrorAction SilentlyContinue
  if (-not $entry) {
    $issues.Add("$Command is not installed or is not on PATH")
    return $null
  }
  return (& $Command @Arguments 2>&1 | Select-Object -First 1).ToString().Trim()
}

$nodeVersion = Resolve-CommandVersion -Command "node" -Arguments @("--version")
$npmVersion = Resolve-CommandVersion -Command "npm" -Arguments @("--version")
$gitVersion = Resolve-CommandVersion -Command "git" -Arguments @("--version")

$packagePath = Join-Path $resolvedRoot "package.json"
if (-not (Test-Path -LiteralPath $packagePath)) {
  $issues.Add("package.json was not found at the ditto.site root")
}

$captureModule = Join-Path $resolvedRoot "compiler\src\capture\runtimeMirror.ts"
$generateModule = Join-Path $resolvedRoot "compiler\src\generate\runtimeMirror.ts"
$runtimeMirrorReady =
  (Test-Path -LiteralPath $captureModule) -and
  (Test-Path -LiteralPath $generateModule)

if (-not $runtimeMirrorReady) {
  $issues.Add("runtime mirror modules are missing; port references/runtime-mirror-architecture.md first")
}

$result = [ordered]@{
  dittoRoot = $resolvedRoot
  node = $nodeVersion
  npm = $npmVersion
  git = $gitVersion
  runtimeMirrorReady = $runtimeMirrorReady
  packageJsonPresent = Test-Path -LiteralPath $packagePath
  issues = @($issues)
}

$result | ConvertTo-Json -Depth 4
if ($issues.Count -gt 0) {
  exit 1
}

