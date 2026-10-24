#Requires -Version 5.1

<#
.SYNOPSIS
    Builds AcidFlow.scr on Windows using the C# compiler that ships with .NET Framework 4.x.

.DESCRIPTION
    No Visual Studio or SDK required. Uses csc.exe from the .NET Framework install folder and embeds the
    WebView2 assemblies, the native loader and AcidFlow.html as resources. Run from this folder.

    The script changes the current location to its own folder, copies ..\AcidFlow.html and
    ..\settings.json into lib\, and writes AcidFlow.scr next to itself. It prints the name,
    size and time stamp of the built file.

    csc.exe is looked up in the runtime directory of the running PowerShell. Only Windows
    PowerShell 5.1 runs on .NET Framework, so run the build from powershell.exe; under
    pwsh the runtime directory is .NET's and the script stops with "csc.exe not found".

.EXAMPLE
    .\build.ps1
    Builds AcidFlow.scr in this folder.

.NOTES
    Author:     Marcus Mattsson
    Compliance: Level 0
    Standalone: No
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
$csc = Join-Path ([System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw "csc.exe not found at $csc" }
Copy-Item -LiteralPath '..\AcidFlow.html' -Destination 'lib\AcidFlow.html' -Force
Copy-Item -LiteralPath '..\settings.json' -Destination 'lib\settings.json' -Force
& $csc /nologo /target:winexe /platform:x64 /optimize+ /out:AcidFlow.scr `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll `
    /r:lib\Microsoft.Web.WebView2.Core.dll /r:lib\Microsoft.Web.WebView2.WinForms.dll `
    /res:lib\Microsoft.Web.WebView2.Core.dll,Microsoft.Web.WebView2.Core.dll `
    /res:lib\Microsoft.Web.WebView2.WinForms.dll,Microsoft.Web.WebView2.WinForms.dll `
    /res:lib\WebView2Loader.dll,WebView2Loader.dll `
    /res:lib\AcidFlow.html,AcidFlow.html `
    /res:lib\settings.json,settings.json `
    AcidFlowSaver.cs
if ($LASTEXITCODE -ne 0) { throw "csc.exe failed with exit code $LASTEXITCODE" }
Get-Item -LiteralPath 'AcidFlow.scr' | Select-Object Name, Length, LastWriteTime
