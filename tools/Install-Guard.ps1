#Requires -Version 7.0

<#
.SYNOPSIS
    Wires the public safety guard into a git clone: hooks, git config and gitleaks.

.DESCRIPTION
    For the repository that carries the .githooks folder (this one) sets core.hooksPath to
    it. For any other repository copies pre-commit, commit-msg and pre-push into the hooks
    folder of its git directory. Sets git config exoit.denylist and exoit.scanner so the
    hooks find what they need, installs gitleaks through winget when missing, and ends with
    a smoke test of the scanner.

.PARAMETER Repository
    The clone to configure. Defaults to the repository this script lives in.

.PARAMETER DenylistPath
    The private denylist (a psd1 file). Must exist.

.PARAMETER ScannerPath
    Test-PublicSafety.ps1. Defaults to the one next to this script.

.PARAMETER Uninstall
    Remove the hooks and the git config again.

.PARAMETER SkipGitleaksInstall
    Do not try winget when gitleaks is missing. The smoke test then fails, on purpose.

.EXAMPLE
    .\Install-Guard.ps1 -DenylistPath C:\Private\Denylist.psd1

.EXAMPLE
    .\Install-Guard.ps1 -Repository C:\Git\my-site -DenylistPath C:\Private\Denylist.psd1

.NOTES
    Author:     Marcus Mattsson
    Compliance: Level 2; ignore STD-020 (repository tooling, no log files by design); ignore STD-021 (same); ignore STD-022 (same); ignore STD-023 (same)
    Standalone: Yes
    Changes:    Sets core.hooksPath or copies hooks into the git hooks folder, sets git config exoit.denylist and exoit.scanner, installs gitleaks via winget
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$Repository = (Split-Path -Parent $PSScriptRoot),

    [Parameter(Mandatory)]
    [string]$DenylistPath,

    [Parameter()]
    [string]$ScannerPath = (Join-Path $PSScriptRoot 'Test-PublicSafety.ps1'),

    [Parameter()]
    [switch]$Uninstall,

    [Parameter()]
    [switch]$SkipGitleaksInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$hookNames = @('pre-commit', 'commit-msg', 'pre-push')
$sourceHooks = Join-Path (Split-Path -Parent $PSScriptRoot) '.githooks'

$repository = (Resolve-Path -LiteralPath $Repository).Path
$null = git -C $repository rev-parse --git-dir 2>$null
if ($LASTEXITCODE -ne 0) { throw "Not a git repository: $repository" }
$gitDir = (git -C $repository rev-parse --path-format=absolute --git-dir).Trim()
$carriesHooks = Test-Path -LiteralPath (Join-Path $repository '.githooks\pre-commit') -PathType Leaf

if ($Uninstall) {
    if ($PSCmdlet.ShouldProcess($repository, 'Remove guard hooks and git config')) {
        git -C $repository config --unset exoit.denylist 2>$null
        git -C $repository config --unset exoit.scanner 2>$null
        if ($carriesHooks) { git -C $repository config --unset core.hooksPath 2>$null }
        else { foreach ($name in $hookNames) { Remove-Item -LiteralPath (Join-Path $gitDir "hooks\$name") -ErrorAction SilentlyContinue } }
        Write-Host "Guard removed from $repository"
    }
    return
}

if (-not (Test-Path -LiteralPath $DenylistPath -PathType Leaf)) { throw "Denylist not found: $DenylistPath" }
if (-not (Test-Path -LiteralPath $ScannerPath -PathType Leaf)) { throw "Scanner not found: $ScannerPath" }
$denylist = (Resolve-Path -LiteralPath $DenylistPath).Path
$scanner = (Resolve-Path -LiteralPath $ScannerPath).Path

if ($PSCmdlet.ShouldProcess($repository, "Set exoit.denylist=$denylist and exoit.scanner=$scanner")) {
    git -C $repository config exoit.denylist $denylist
    git -C $repository config exoit.scanner $scanner
}

if ($carriesHooks) {
    if ($PSCmdlet.ShouldProcess($repository, 'Set core.hooksPath to .githooks')) {
        git -C $repository config core.hooksPath .githooks
    }
}
else {
    foreach ($name in $hookNames) {
        $source = Join-Path $sourceHooks $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Hook source not found: $source" }
        $target = Join-Path $gitDir "hooks\$name"
        if ($PSCmdlet.ShouldProcess($target, "Copy hook $name")) {
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
            # LF endings: sh refuses a hook with CRLF.
            $content = (Get-Content -LiteralPath $source -Raw) -replace "`r`n", "`n"
            [System.IO.File]::WriteAllText($target, $content, [System.Text.UTF8Encoding]::new($false))
        }
    }
}

if (-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) {
    if ($SkipGitleaksInstall) { Write-Warning 'gitleaks is missing and -SkipGitleaksInstall was given. The scanner will exit 2 until it is installed.' }
    elseif ($PSCmdlet.ShouldProcess('gitleaks', 'Install with winget')) {
        winget install --id Gitleaks.Gitleaks --exact --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0) { throw "winget install Gitleaks.Gitleaks failed with exit code $LASTEXITCODE" }
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $env:PATH = "$machinePath;$userPath;$env:PATH"
        if (-not (Get-Command gitleaks -ErrorAction SilentlyContinue)) { Write-Warning 'gitleaks installed but not on PATH in this session. Open a new shell and run the smoke test again.' }
    }
}

if ($WhatIfPreference) { Write-Host 'WhatIf: smoke test skipped.'; return }

Write-Host 'Smoke test: scanning the text "guard check"'
& pwsh -NoProfile -NonInteractive -File $scanner -Text 'guard check' -DenylistPath $denylist -RepositoryPath $repository
if ($LASTEXITCODE -ne 0) { throw "Smoke test failed with exit code $LASTEXITCODE. The guard is installed but not working; fix that before committing anything." }
Write-Host "Guard installed in $repository" -ForegroundColor Green
