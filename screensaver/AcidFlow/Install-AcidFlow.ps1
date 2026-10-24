#Requires -Version 5.1

<#
.SYNOPSIS
    Installs or removes the AcidFlow screensaver for the current user.

.DESCRIPTION
    Copies AcidFlow.scr to %LOCALAPPDATA%\AcidFlow (no admin rights, nothing written to System32) and points
    HKCU\Control Panel\Desktop\SCRNSAVE.EXE at it. Optionally sets the idle timeout and whether the
    logon screen is shown on resume. Changes are applied immediately via SystemParametersInfo.

    Prerequisites on the target machine: .NET Framework 4.8 (built into Windows 10/11) and the
    WebView2 Runtime (built into Windows 11, present on most Windows 10 machines with Edge).

    Note: if a screen saver is enforced by Group Policy / Intune (HKCU\Software\Policies\Microsoft\Windows\
    Control Panel\Desktop), the policy wins and this script warns about it.

.PARAMETER Path
    Path to AcidFlow.scr. Defaults to AcidFlow.scr next to this script.

.PARAMETER TimeoutSeconds
    Idle time before the screensaver starts, 60-86400. Default 600.

.PARAMETER RequirePasswordOnResume
    Show the logon screen when the screensaver ends (ScreenSaverIsSecure=1). Default: leave as is.

.PARAMETER Uninstall
    Removes the registration and the files under %LOCALAPPDATA%\AcidFlow.

.PARAMETER LogRoot
    Root for log files. The log is written to <LogRoot>\Install-AcidFlow\yyyyMMdd\.

.PARAMETER ExportRoot
    Root for exports. The script exports nothing; the parameter exists for the standard.

.PARAMETER ReportRoot
    Root for reports. The script writes no reports; the parameter exists for the standard.

.EXAMPLE
    .\Install-AcidFlow.ps1
    Installs the screensaver for the current user with a 600 second timeout.

.EXAMPLE
    .\Install-AcidFlow.ps1 -TimeoutSeconds 300 -RequirePasswordOnResume -WhatIf
    Shows what a five minute, password-on-resume install would change, without changing it.

.EXAMPLE
    .\Install-AcidFlow.ps1 -Uninstall
    Removes the registration and the installed files.

.NOTES
    Author:     Marcus Mattsson
    Compliance: Level 2; ignore STD-043 (the only early abort is a missing AcidFlow.scr, which a dry run must report too)
    Standalone: Yes
    Changes:    Copies AcidFlow.scr to %LOCALAPPDATA%\AcidFlow and sets the screensaver values
                (SCRNSAVE.EXE, ScreenSaveActive, ScreenSaveTimeOut, optionally ScreenSaverIsSecure)
                under HKCU\Control Panel\Desktop; -Uninstall removes them and the folder

    Standalone because the Screensaver folder is a self-contained package (the .scr plus
    this installer) that can be copied to a machine without this repository.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Path = (Join-Path $PSScriptRoot 'AcidFlow.scr'),
    [ValidateRange(60, 86400)]
    [int]$TimeoutSeconds = 600,
    [switch]$RequirePasswordOnResume,
    [switch]$Uninstall,

    [string]$LogRoot    = 'C:\ProgramData\Scripts\Logs',
    [string]$ExportRoot = 'C:\ProgramData\Scripts\Exports',
    [string]$ReportRoot = 'C:\ProgramData\Scripts\Reports'
)

#region Infra.Logging v1 - GENERATED, DO NOT EDIT - see docs/SCRIPT_STANDARD.md
function Initialize-ScriptPaths {
    <#
    .SYNOPSIS
        Creates the log, export and report directories for the calling script and returns them.

    .DESCRIPTION
        Builds <Root>\<ScriptName>\yyyyMMdd\ under each of the three roots, creates them if
        missing, and returns an object holding every path plus the log file name.

        Also sets $script:LogFile in the calling script's scope, so Write-Log needs no
        -LogFile argument. That is what lets the roughly 6 300 existing Write-Log calls,
        almost none of which pass a log file, keep working unchanged.

    .PARAMETER LogRoot
        Root directory for log files.

    .PARAMETER ExportRoot
        Root directory for data exports.

    .PARAMETER ReportRoot
        Root directory for reports.

    .PARAMETER StateRoot
        Root directory for state kept between runs. The returned StateDir is
        <StateRoot>\<ScriptName>\, with no day folder because state outlives a single run.
        Not created here; a script that keeps state creates it when it first writes.

    .PARAMETER InputRoot
        Root directory for input files. The returned InputDir is <InputRoot>\<ScriptName>\.
        Not created here.

    .EXAMPLE
        $paths = Initialize-ScriptPaths -LogRoot $LogRoot -ExportRoot $ExportRoot -ReportRoot $ReportRoot
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$LogRoot,

        [Parameter(Mandatory)]
        [string]$ExportRoot,

        [Parameter(Mandatory)]
        [string]$ReportRoot,

        [string]$StateRoot = 'C:\ProgramData\Scripts\State',

        [string]$InputRoot = 'C:\ProgramData\Scripts\Input'
    )

    $callerPath = $MyInvocation.PSCommandPath
    if ([string]::IsNullOrWhiteSpace($callerPath)) {
        $scriptName = 'InteractiveSession'
    }
    else {
        $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($callerPath)
    }

    $dayFolder = (Get-Date).ToString('yyyyMMdd')
    $timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')

    $logDir    = Join-Path -Path $LogRoot    -ChildPath (Join-Path -Path $scriptName -ChildPath $dayFolder)
    $exportDir = Join-Path -Path $ExportRoot -ChildPath (Join-Path -Path $scriptName -ChildPath $dayFolder)
    $reportDir = Join-Path -Path $ReportRoot -ChildPath (Join-Path -Path $scriptName -ChildPath $dayFolder)

    foreach ($directory in @($logDir, $exportDir, $reportDir)) {
        if (-not (Test-Path -LiteralPath $directory)) {
            $null = New-Item -Path $directory -ItemType Directory -Force -WhatIf:$false
        }
    }

    $logFile = Join-Path -Path $logDir -ChildPath ('{0}_{1}.log' -f $scriptName, $timestamp)
    $script:LogFile = $logFile

    [pscustomobject]@{
        ScriptName = $scriptName
        DayFolder  = $dayFolder
        Timestamp  = $timestamp
        LogRoot    = $LogRoot
        ExportRoot = $ExportRoot
        ReportRoot = $ReportRoot
        LogDir     = $logDir
        ExportDir  = $exportDir
        ReportDir  = $reportDir
        StateDir   = Join-Path -Path $StateRoot -ChildPath $scriptName
        InputDir   = Join-Path -Path $InputRoot -ChildPath $scriptName
        LogFile    = $logFile
    }
}

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped, colour-coded line to the console and to the script's log file.

    .DESCRIPTION
        The parameter shape is deliberate and must not be changed without a version bump.
        -Message is position 0 and accepts an empty string; -Level is optional and defaults
        to Info; -LogFile is optional and falls back to $script:LogFile. Those three
        decisions are what make roughly 6 300 existing call sites work unchanged.

        Add-Content is called with -WhatIf:$false. In a SupportsShouldProcess script the
        caller's -WhatIf propagates into every downstream cmdlet that supports it, so
        without this a dry run emits one "What if: Performing the operation Add Content"
        line per log entry and buries the actual plan.

    .PARAMETER Message
        The line to write. May be empty: 255 existing call sites pass an empty string to
        produce a blank separator line.

    .PARAMETER Level
        Info, Success, Warning, Warn, Error or Debug. Warn is normalised to Warning, and
        -Severity is accepted as an alias for backward compatibility.

    .PARAMETER LogFile
        Target log file. Defaults to $script:LogFile, set by Initialize-ScriptPaths.
        When neither is set the line goes to the console only.

    .EXAMPLE
        Write-Log 'Connected to Microsoft Graph' -Level Success
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Position = 1)]
        [Alias('Severity')]
        [ValidateSet('Info', 'Success', 'Warning', 'Warn', 'Error', 'Debug')]
        [string]$Level = 'Info',

        [string]$LogFile
    )

    # ValidateSet is case-insensitive and passes the caller's casing through, so normalise
    # before formatting: -Level INFO must not produce '[INFO]' where every other line says
    # '[Info]'.
    $normalised = @{
        'info'    = 'Info'
        'success' = 'Success'
        'warning' = 'Warning'
        'warn'    = 'Warning'
        'error'   = 'Error'
        'debug'   = 'Debug'
    }
    $Level = $normalised[$Level.ToLowerInvariant()]

    if (-not $PSBoundParameters.ContainsKey('LogFile')) {
        # Get-Variable rather than reading $script:LogFile directly: under
        # Set-StrictMode -Version Latest an undefined variable is a terminating error, and
        # every compliant script sets strict mode.
        $scriptScoped = Get-Variable -Name 'LogFile' -Scope Script -ErrorAction SilentlyContinue
        $LogFile = if ($null -ne $scriptScoped) { [string]$scriptScoped.Value } else { '' }
    }

    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    $colour = switch ($Level) {
        'Info'    { 'Cyan' }
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Debug'   { 'DarkGray' }
        default   { 'Cyan' }
    }
    Write-Host $line -ForegroundColor $colour

    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        try {
            Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8 -ErrorAction Stop -WhatIf:$false
        }
        catch {
            Write-Host ('[{0}] [Warning] Failed to write to log file: {1}' -f
                (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}
#endregion Infra.Logging v1 sha256:648bd56761f4c978c4f01e2907d2642cefff5a89a6d53238abc011d22eea0d26


$ErrorActionPreference = 'Stop'

$installDir = Join-Path $env:LOCALAPPDATA 'AcidFlow'
$target     = Join-Path $installDir 'AcidFlow.scr'
$desktopKey = 'HKCU:\Control Panel\Desktop'
$policyKey  = 'HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop'



function Invoke-ScreenSaverRefresh {
    # Tell Windows to re-read the screensaver settings without a logoff.
    if (-not ('AcidFlow.NativeMethods' -as [type])) {
        Add-Type -Namespace AcidFlow -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);
'@
    }
    $SPI_SETSCREENSAVETIMEOUT = 0x000F
    $SPI_SETSCREENSAVEACTIVE  = 0x0011
    $SPIF_UPDATEINIFILE       = 0x0001
    $SPIF_SENDCHANGE          = 0x0002
    $flags = $SPIF_UPDATEINIFILE -bor $SPIF_SENDCHANGE
    [void][AcidFlow.NativeMethods]::SystemParametersInfo($SPI_SETSCREENSAVETIMEOUT, [uint32]$TimeoutSeconds, [IntPtr]::Zero, $flags)
    [void][AcidFlow.NativeMethods]::SystemParametersInfo($SPI_SETSCREENSAVEACTIVE, [uint32](-not $Uninstall), [IntPtr]::Zero, $flags)
}

$paths = $null
try {
    $paths = Initialize-ScriptPaths -LogRoot $LogRoot -ExportRoot $ExportRoot -ReportRoot $ReportRoot
    Write-Log "Starting $($MyInvocation.MyCommand.Path)"

    if (Test-Path -LiteralPath $policyKey) {
        $pol = Get-ItemProperty -LiteralPath $policyKey
        if ($pol.'SCRNSAVE.EXE' -or $pol.ScreenSaveActive) {
            Write-Log 'A screen saver policy (GPO/Intune) is present under HKCU\Software\Policies. It overrides user settings.' -Level Warning
        }
    }

    if ($Uninstall) {
        if ($PSCmdlet.ShouldProcess($desktopKey, 'Remove SCRNSAVE.EXE registration')) {
            Remove-ItemProperty -LiteralPath $desktopKey -Name 'SCRNSAVE.EXE' -ErrorAction SilentlyContinue
            Set-ItemProperty -LiteralPath $desktopKey -Name 'ScreenSaveActive' -Value '0'
            Invoke-ScreenSaverRefresh
        }
        if ((Test-Path -LiteralPath $installDir) -and $PSCmdlet.ShouldProcess($installDir, 'Delete install folder')) {
            Get-Process -Name 'AcidFlow' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $installDir -Recurse -Force
        }
        Write-Log 'AcidFlow removed.' -Level Success
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) { throw "AcidFlow.scr not found: $Path" }

    $webview2 = @(@(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    ) | Where-Object { Test-Path -LiteralPath $_ })
    if (-not $webview2) {
        Write-Log 'WebView2 Runtime not detected. Install it from https://developer.microsoft.com/microsoft-edge/webview2/ (Evergreen Bootstrapper) or the screensaver will exit immediately.' -Level Warning
    } else {
        $ver = (Get-ItemProperty -LiteralPath $webview2[0]).pv
        Write-Log "WebView2 Runtime $ver detected."
    }

    if ($PSCmdlet.ShouldProcess($target, 'Copy AcidFlow.scr')) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        Get-Process -Name 'AcidFlow' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $Path -Destination $target -Force
        Unblock-File -LiteralPath $target -ErrorAction SilentlyContinue
    }

    if ($PSCmdlet.ShouldProcess($desktopKey, "Set SCRNSAVE.EXE=$target, timeout ${TimeoutSeconds}s")) {
        Set-ItemProperty -LiteralPath $desktopKey -Name 'SCRNSAVE.EXE' -Value $target
        Set-ItemProperty -LiteralPath $desktopKey -Name 'ScreenSaveActive' -Value '1'
        Set-ItemProperty -LiteralPath $desktopKey -Name 'ScreenSaveTimeOut' -Value ([string]$TimeoutSeconds)
        if ($RequirePasswordOnResume) {
            Set-ItemProperty -LiteralPath $desktopKey -Name 'ScreenSaverIsSecure' -Value '1'
        }
        Invoke-ScreenSaverRefresh
    }

    Write-Log "Installed: $target (timeout ${TimeoutSeconds}s)." -Level Success
    Write-Log 'Settings dialog: Windows "Change screen saver" > Settings..., or run: AcidFlow.scr /c'
    Write-Log ('Screensaver log file: ' + (Join-Path $installDir 'AcidFlow.log'))
}
catch {
    $errorMessage = "FATAL: Script execution failed - $($_.Exception.Message)"
    if ($null -ne $paths -and $null -ne $paths.LogFile) {
        Write-Log $errorMessage -Level Error
        Write-Log ('Error at line: {0}' -f $_.InvocationInfo.ScriptLineNumber) -Level Error
        Write-Log ('Stack trace: {0}' -f $_.ScriptStackTrace) -Level Error
    }
    else {
        Write-Host "$(Get-Date -Format o) [Error] $errorMessage" -ForegroundColor Red
    }
    throw
}
