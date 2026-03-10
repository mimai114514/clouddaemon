Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$agentDir = Join-Path $repoRoot "agent"
$outputDir = Join-Path $agentDir "dist"
$outputPath = Join-Path $outputDir "clouddaemon-agent-linux-amd64"

if (-not (Test-Path $agentDir)) {
    throw "Agent directory not found: $agentDir"
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

$previousGoos = $env:GOOS
$previousGoarch = $env:GOARCH
$previousCgoEnabled = $env:CGO_ENABLED

try {
    $env:GOOS = "linux"
    $env:GOARCH = "amd64"
    $env:CGO_ENABLED = "0"

    Push-Location $agentDir
    try {
        Write-Host "Building Linux amd64 agent..."
        go build -trimpath -ldflags="-s -w" -o $outputPath .\cmd\clouddaemon-agent
    }
    finally {
        Pop-Location
    }
}
finally {
    if ($null -eq $previousGoos) {
        Remove-Item Env:GOOS -ErrorAction SilentlyContinue
    }
    else {
        $env:GOOS = $previousGoos
    }

    if ($null -eq $previousGoarch) {
        Remove-Item Env:GOARCH -ErrorAction SilentlyContinue
    }
    else {
        $env:GOARCH = $previousGoarch
    }

    if ($null -eq $previousCgoEnabled) {
        Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue
    }
    else {
        $env:CGO_ENABLED = $previousCgoEnabled
    }
}

Write-Host "Done: $outputPath"
