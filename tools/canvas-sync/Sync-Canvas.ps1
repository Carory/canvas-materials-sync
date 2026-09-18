[CmdletBinding()]
param(
    [ValidateSet('5001', '5002', '5003', '6004', '6012', '6013', '6016')]
    [string[]]$Course,
    [switch]$DryRun,
    [switch]$ResetToken
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$configPath = Join-Path $PSScriptRoot 'canvas-sync.config.json'
$stateDirectory = Join-Path $env:LOCALAPPDATA 'DataScienceMaster\CanvasSync'
$logPath = Join-Path $stateDirectory 'last-run.log'
$transcriptStarted = $false

try {
    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    Start-Transcript -LiteralPath $logPath -Force | Out-Null
    $transcriptStarted = $true
    Import-Module (Join-Path $PSScriptRoot 'CanvasSync.psm1') -Force
    $exitCode = Start-CanvasSync -RepositoryRoot $repositoryRoot -ConfigPath $configPath -Course $Course -DryRun:$DryRun -ResetToken:$ResetToken -StateDirectory $stateDirectory
}
catch {
    Write-Host ''
    Write-Host "同步无法继续：$($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
finally {
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
}

[Environment]::ExitCode = $exitCode
