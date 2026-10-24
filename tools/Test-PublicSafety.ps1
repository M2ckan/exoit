#Requires -Version 7.0

<#
.SYNOPSIS
    Scans files, the git index, a revision range or a text for anything that must not be public.

.DESCRIPTION
    The guard of a public repository. Finds three kinds of things:

      1. Secrets, through gitleaks (required, the scan fails without it).
      2. Generic patterns: GUIDs, e-mail addresses, IPv4 and IPv6 addresses, UNC paths,
         onmicrosoft.com tenants, internal host suffixes (.local .lan .corp .internal),
         Windows SIDs, JWTs, private key blocks, credential assignments, connection
         strings, storage account keys and SAS tokens.
      3. A private denylist: words, domains, hosts, networks and GUIDs that identify
         customers, tenants or infrastructure. The denylist is a .psd1 outside the
         repository, found through -DenylistPath or git config exoit.denylist.

    Commit messages and the author and committer identities are scanned too, in -Staged
    mode (the identity git would use for the next commit) and in -Range mode (every
    commit in the range).

    Binary files are not scanned. Files with a guarded extension (scr, dll, exe, msi, msix,
    msu, pfx, p12, cer, crt, der, jks, ppk) fail unless their repository-relative path is
    listed in the file .publicsafety-allow at the repository root. (No line in this help
    block may start with a dot: the help parser would read it as a keyword and drop the topic.)

    The scanner fails closed: a missing denylist, a missing gitleaks or a git error is
    exit code 2 and blocks like a hit. There is no bypass switch. Fix the finding, the
    denylist or the pattern.

.PARAMETER Path
    One or more files or folders to scan. Folders are scanned recursively, .git excluded.

.PARAMETER Staged
    Scan the files staged in the index of the repository at -RepositoryPath (pre-commit),
    plus the author and committer identity git would record.

.PARAMETER Range
    Scan the files changed, the commit messages and the identities in a revision range
    such as origin/main..HEAD (pre-push). A plain revision scans everything reachable from it.

.PARAMETER Text
    Scan a string, for example a commit message.

.PARAMETER TextFile
    Scan the content of a file as a text, for example the commit message file (commit-msg hook).

.PARAMETER DenylistPath
    The denylist .psd1. Defaults to git config exoit.denylist of the repository.

.PARAMETER RepositoryPath
    The repository root. Defaults to the top level of the git working tree around the
    first -Path, or the current directory.

.PARAMETER AllowFile
    The binary allow list. Defaults to <RepositoryPath>\.publicsafety-allow.

.EXAMPLE
    .\Test-PublicSafety.ps1 -Path .\scripts

.EXAMPLE
    .\Test-PublicSafety.ps1 -Range origin/main..HEAD

.NOTES
    Author:     Marcus Mattsson
    Compliance: Level 0
    Standalone: Yes
    Exit codes: 0 clean, 1 hits, 2 scanner error.

    Denylist shape:
        @{
            Words    = @('CustomerA')
            Domains  = @('customera.example')
            Hosts    = @('SRV-CUSTA01')
            Networks = @('192.0.2.0/24')
            Guids    = @('<tenant, app or object id>')
            Allow    = @('contoso.com', 'noreply@anthropic.com')
        }
    (The example network is a documentation range: the scanner scans its own help too.)
#>
[CmdletBinding(DefaultParameterSetName = 'Path')]
param(
    [Parameter(ParameterSetName = 'Path', Mandatory, Position = 0)]
    [string[]]$Path,

    [Parameter(ParameterSetName = 'Staged', Mandatory)]
    [switch]$Staged,

    [Parameter(ParameterSetName = 'Range', Mandatory)]
    [string]$Range,

    [Parameter(ParameterSetName = 'Text', Mandatory)]
    [AllowEmptyString()]
    [string]$Text,

    [Parameter(ParameterSetName = 'TextFile', Mandatory)]
    [string]$TextFile,

    [Parameter()]
    [string]$DenylistPath,

    [Parameter()]
    [string]$RepositoryPath,

    [Parameter()]
    [string]$AllowFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$script:EmptyTree = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
$script:GuardedExtensions = @('.scr', '.dll', '.exe', '.msi', '.msix', '.msu', '.pfx', '.p12', '.cer', '.crt', '.der', '.jks', '.ppk')
$script:SkippedExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.ico', '.webp', '.svg', '.woff', '.woff2', '.ttf', '.otf', '.pdf', '.zip', '.7z', '.intunewin')
$script:ExemptIPv4 = @('^127\.', '^0\.0\.0\.0$', '^255\.255\.255\.255$', '^192\.0\.2\.', '^198\.51\.100\.', '^203\.0\.113\.')
$script:IPv4Pattern = '(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])'

function Stop-Scanner {
    param([int]$Code, [string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit $Code
}

function New-Rule {
    param([string]$Name, [string]$Pattern)
    [pscustomobject]@{ Name = $Name; Regex = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) }
}

function Get-BuiltInRule {
    @(
        New-Rule 'Guid'             '\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b'
        New-Rule 'Email'            '\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b'
        New-Rule 'IPv4'             $script:IPv4Pattern
        New-Rule 'IPv6'             '(?<![\w:])(?:2[0-9a-f]{3}|fd[0-9a-f]{2}):(?:[0-9a-f]{0,4}:){1,6}[0-9a-f]{0,4}(?![\w:])'
        New-Rule 'UncPath'          '\\\\[\w.-]+\\[\w$.-]+'
        New-Rule 'OnMicrosoft'      '\b[\w-]+\.onmicrosoft\.com\b'
        New-Rule 'InternalHost'     '\b[\w-]+(?:\.[\w-]+)*\.(?:local|lan|corp|internal)\b'
        New-Rule 'Sid'              '\bS-1-5-21-\d+-\d+-\d+(?:-\d+)?\b'
        New-Rule 'Jwt'              '\beyJ[\w-]{10,}\.[\w-]{10,}\.[\w-]{10,}\b'
        New-Rule 'PrivateKey'       '-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED |DSA )?PRIVATE KEY-----'
        New-Rule 'Credential'       '\b(?:password|passwd|pwd|secret|token|apikey|api_key|client_secret)\s*[=:]\s*[''"][^''"]{4,}[''"]'
        New-Rule 'ConnectionString' '\b(?:Server|Data Source)=[^;]+;.*\b(?:Password|Pwd)=[^;]+'
        New-Rule 'StorageKey'       '\bAccountKey=[A-Za-z0-9+/]{40,}={0,2}'
        New-Rule 'SasToken'         '[?&]sig=[A-Za-z0-9%+/]{20,}'
    )
}

function Get-DenylistRule {
    param([hashtable]$Denylist)
    $rules = @()
    $sets = @(
        @{ Name = 'Denylist.Word';   Items = $Denylist.Words }
        @{ Name = 'Denylist.Domain'; Items = $Denylist.Domains }
        @{ Name = 'Denylist.Host';   Items = $Denylist.Hosts }
        @{ Name = 'Denylist.Guid';   Items = $Denylist.Guids }
    )
    foreach ($set in $sets) {
        $items = @($set.Items | Where-Object { $_ })
        if ($items.Count -eq 0) { continue }
        $alternation = ($items | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $rules += New-Rule $set.Name "(?<![\w-])(?:$alternation)(?![\w-])"
    }
    return $rules
}

function Resolve-Repository {
    if ($RepositoryPath) { return (Resolve-Path -LiteralPath $RepositoryPath).Path }
    $start = if ($PSCmdlet.ParameterSetName -eq 'Path') { $Path[0] } else { (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $start)) { Stop-Scanner 2 "Path not found: $start" }
    if (Test-Path -LiteralPath $start -PathType Leaf) { $start = [System.IO.Path]::GetDirectoryName((Resolve-Path -LiteralPath $start).Path) }
    $top = git -C $start rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $top) { return (Resolve-Path -LiteralPath $top).Path }
    return (Resolve-Path -LiteralPath $start).Path
}

function Get-Denylist {
    param([string]$Repository)
    $file = $DenylistPath
    if (-not $file) {
        $file = git -C $Repository config --get exoit.denylist 2>$null
        if ($LASTEXITCODE -ne 0) { $file = $null }
    }
    if (-not $file) { Stop-Scanner 2 'No denylist. Pass -DenylistPath or set git config exoit.denylist (tools/Install-Guard.ps1 does).' }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Stop-Scanner 2 "Denylist not found: $file" }
    $data = Import-PowerShellDataFile -LiteralPath $file
    foreach ($key in 'Words', 'Domains', 'Hosts', 'Networks', 'Guids', 'Allow') {
        if (-not $data.ContainsKey($key)) { $data[$key] = @() }
    }
    return $data
}

function Get-AllowedBinary {
    param([string]$Repository)
    $file = if ($AllowFile) { $AllowFile } else { Join-Path $Repository '.publicsafety-allow' }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return @() }
    return @(Get-Content -LiteralPath $file | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}

function ConvertTo-IPv4Number {
    param([string]$Address)
    $bytes = [System.Net.IPAddress]::Parse($Address).GetAddressBytes()
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Test-IPv4Octets {
    param([string]$Address)
    foreach ($octet in $Address -split '\.') { if ([int]$octet -gt 255) { return $false } }
    return $true
}

function Test-ExemptIPv4 {
    param([string]$Address)
    foreach ($pattern in $script:ExemptIPv4) { if ($Address -match $pattern) { return $true } }
    return $false
}

function Test-InNetwork {
    param([string]$Address, [string[]]$Networks)
    $value = ConvertTo-IPv4Number $Address
    foreach ($cidr in $Networks) {
        if (-not $cidr) { continue }
        $network, $bits = $cidr -split '/', 2
        if (-not $bits) { $bits = 32 }
        # 0xFFFFFFFF is parsed as the int32 -1, so the all-ones mask is written in decimal.
        $mask = [uint32]((([uint64]4294967295) -shl (32 - [int]$bits)) -band [uint64]4294967295)
        if (($value -band $mask) -eq ((ConvertTo-IPv4Number $network) -band $mask)) { return $true }
    }
    return $false
}

function Test-Allowed {
    param([string]$Value, [string[]]$Allow)
    foreach ($entry in $Allow) {
        if (-not $entry) { continue }
        if ($Value -ieq $entry -or $Value -ilike "*@$entry" -or $Value -ilike "*.$entry") { return $true }
    }
    return $false
}

function Find-Hit {
    param([string]$Label, [string[]]$Lines, [object[]]$Rules, [hashtable]$Denylist)
    $hits = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ([string]::IsNullOrEmpty($line)) { continue }
        if ($line -match '^\s*Co-Authored-By:') { continue }
        foreach ($rule in $Rules) {
            foreach ($match in $rule.Regex.Matches($line)) {
                $value = $match.Value
                $name = $rule.Name
                if ($name -eq 'IPv4') {
                    if (-not (Test-IPv4Octets $value)) { continue }
                    if (Test-ExemptIPv4 $value) { continue }
                    if (Test-InNetwork -Address $value -Networks $Denylist.Networks) { $name = 'Denylist.Network' }
                }
                if (Test-Allowed -Value $value -Allow $Denylist.Allow) { continue }
                $hits.Add([pscustomobject]@{ Path = $Label; Line = $i + 1; Rule = $name; Match = $value })
            }
        }
    }
    return $hits
}

function Get-FileKind {
    param([string]$RelativePath, [bool]$GitSaysBinary, [byte[]]$Head)
    $extension = [System.IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
    if ($script:GuardedExtensions -contains $extension) { return 'guarded' }
    if ($script:SkippedExtensions -contains $extension) { return 'skip' }
    if ($GitSaysBinary) { return 'skip' }
    if ($null -ne $Head -and $Head -contains [byte]0) { return 'skip' }
    return 'text'
}

function Invoke-Gitleaks {
    param([string[]]$Arguments, [string]$InputText)
    $exe = Get-Command gitleaks -ErrorAction SilentlyContinue
    if (-not $exe) { Stop-Scanner 2 'gitleaks is not installed. Run tools/Install-Guard.ps1 or: winget install --id Gitleaks.Gitleaks' }
    $report = Join-Path ([System.IO.Path]::GetTempPath()) ('publicsafety-{0}.json' -f [guid]::NewGuid().ToString('N'))
    try {
        $common = @('--no-banner', '--exit-code', '1', '--report-format', 'json', '--report-path', $report)
        if ($null -ne $InputText) {
            $null = $InputText | & $exe.Source @Arguments @common 2>&1
        }
        else {
            $null = & $exe.Source @Arguments @common 2>&1
        }
        $code = $LASTEXITCODE
        if ($code -notin 0, 1) { Stop-Scanner 2 "gitleaks failed with exit code $code (arguments: $($Arguments -join ' '))" }
        $hits = @()
        if ($code -eq 1 -and (Test-Path -LiteralPath $report)) {
            $findings = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
            foreach ($finding in @($findings)) {
                $hits += [pscustomobject]@{ Path = $finding.File; Line = $finding.StartLine; Rule = "gitleaks.$($finding.RuleID)"; Match = $finding.Secret }
            }
        }
        elseif ($code -eq 1) {
            $hits += [pscustomobject]@{ Path = '(gitleaks)'; Line = 0; Rule = 'gitleaks'; Match = 'finding reported without a report file' }
        }
        return $hits
    }
    finally {
        Remove-Item -LiteralPath $report -ErrorAction SilentlyContinue
    }
}

function Get-GitLines {
    param([string]$Repository, [string]$Spec)
    $out = git -C $Repository -c core.quotepath=off show $Spec 2>$null
    if ($LASTEXITCODE -ne 0) { Stop-Scanner 2 "git show $Spec failed in $Repository" }
    return @($out)
}

function Get-GitBinaryPath {
    param([string]$Repository, [string[]]$DiffArguments)
    $binary = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $out = git -C $Repository -c core.quotepath=off diff --numstat @DiffArguments 2>$null
    if ($LASTEXITCODE -ne 0) { Stop-Scanner 2 "git diff --numstat $($DiffArguments -join ' ') failed in $Repository" }
    foreach ($line in @($out)) {
        if ($line -match '^-\t-\t(.+)$') { $null = $binary.Add($Matches[1]) }
    }
    # The comma keeps PowerShell from unrolling an empty set into $null.
    return , $binary
}

# ---------------------------------------------------------------------------------------

$repository = Resolve-Repository
$denylist = Get-Denylist -Repository $repository
$rules = @(Get-BuiltInRule) + @(Get-DenylistRule -Denylist $denylist)
$allowedBinaries = Get-AllowedBinary -Repository $repository

$hits = [System.Collections.Generic.List[object]]::new()
$notScanned = [System.Collections.Generic.List[string]]::new()

function Add-FileResult {
    param([string]$Label, [string]$Kind, [string[]]$Lines)
    switch ($Kind) {
        'text'    { foreach ($hit in (Find-Hit -Label $Label -Lines $Lines -Rules $rules -Denylist $denylist)) { $hits.Add($hit) } }
        'skip'    { $notScanned.Add($Label) }
        'guarded' {
            $relative = $Label -replace '\\', '/'
            if ($allowedBinaries -contains $relative) { $notScanned.Add("$Label (allowed)") }
            else { $hits.Add([pscustomobject]@{ Path = $Label; Line = 0; Rule = 'Binary'; Match = 'guarded extension, not in .publicsafety-allow' }) }
        }
    }
}

function Add-TextResult {
    param([string]$Label, [string[]]$Lines)
    foreach ($hit in (Find-Hit -Label $Label -Lines $Lines -Rules $rules -Denylist $denylist)) { $hits.Add($hit) }
}

switch ($PSCmdlet.ParameterSetName) {
    'Path' {
        foreach ($entry in $Path) {
            if (-not (Test-Path -LiteralPath $entry)) { Stop-Scanner 2 "Path not found: $entry" }
            $isLeaf = Test-Path -LiteralPath $entry -PathType Leaf
            $files = if ($isLeaf) { @(Get-Item -LiteralPath $entry) }
                     else { @(Get-ChildItem -LiteralPath $entry -File -Recurse -Force | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }) }
            foreach ($file in $files) {
                $label = [System.IO.Path]::GetRelativePath($repository, $file.FullName)
                $stream = [System.IO.File]::OpenRead($file.FullName)
                try {
                    $head = [byte[]]::new([Math]::Min(8000, $stream.Length))
                    $null = $stream.Read($head, 0, $head.Length)
                }
                finally { $stream.Dispose() }
                $kind = Get-FileKind -RelativePath $label -GitSaysBinary $false -Head $head
                $lines = if ($kind -eq 'text') { @(Get-Content -LiteralPath $file.FullName) } else { @() }
                Add-FileResult -Label $label -Kind $kind -Lines $lines
            }
            foreach ($hit in (Invoke-Gitleaks -Arguments @('dir', (Resolve-Path -LiteralPath $entry).Path))) { $hits.Add($hit) }
        }
    }
    'Staged' {
        $names = @(git -C $repository -c core.quotepath=off diff --cached --name-only --diff-filter=ACMR 2>$null)
        if ($LASTEXITCODE -ne 0) { Stop-Scanner 2 "git diff --cached failed in $repository" }
        $binaries = Get-GitBinaryPath -Repository $repository -DiffArguments @('--cached', '--diff-filter=ACMR')
        foreach ($name in $names) {
            $kind = Get-FileKind -RelativePath $name -GitSaysBinary $binaries.Contains($name) -Head $null
            $lines = if ($kind -eq 'text') { Get-GitLines -Repository $repository -Spec ":$name" } else { @() }
            Add-FileResult -Label $name -Kind $kind -Lines $lines
        }
        $identity = @(
            (git -C $repository var GIT_AUTHOR_IDENT 2>$null)
            (git -C $repository var GIT_COMMITTER_IDENT 2>$null)
        ) | ForEach-Object { [string]$_ -replace '\s+\d+\s+[+-]\d{4}$', '' }
        Add-TextResult -Label 'commit-identity' -Lines $identity
        foreach ($hit in (Invoke-Gitleaks -Arguments @('git', '--pre-commit', '--staged', $repository))) { $hits.Add($hit) }
    }
    'Range' {
        if ($Range -match '\.\.') { $from, $to = $Range -split '\.{2,3}', 2 }
        else { $from = $script:EmptyTree; $to = $Range }
        $names = @(git -C $repository -c core.quotepath=off diff --name-only --diff-filter=ACMR $from $to 2>$null)
        if ($LASTEXITCODE -ne 0) { Stop-Scanner 2 "git diff $from $to failed in $repository. Fetch first if the remote commit is unknown locally." }
        $binaries = Get-GitBinaryPath -Repository $repository -DiffArguments @('--diff-filter=ACMR', $from, $to)
        foreach ($name in $names) {
            $kind = Get-FileKind -RelativePath $name -GitSaysBinary $binaries.Contains($name) -Head $null
            $lines = if ($kind -eq 'text') { Get-GitLines -Repository $repository -Spec "${to}:$name" } else { @() }
            Add-FileResult -Label $name -Kind $kind -Lines $lines
        }
        $messages = @(git -C $repository log --format=%B $Range 2>$null)
        if ($LASTEXITCODE -ne 0) { Stop-Scanner 2 "git log $Range failed in $repository" }
        Add-TextResult -Label 'commit-message' -Lines $messages
        $authors = @(git -C $repository log --format='%an <%ae>%n%cn <%ce>' $Range 2>$null | Sort-Object -Unique)
        Add-TextResult -Label 'commit-author' -Lines $authors
        foreach ($hit in (Invoke-Gitleaks -Arguments @('git', "--log-opts=$Range", $repository))) { $hits.Add($hit) }
    }
    'Text' {
        Add-TextResult -Label 'text' -Lines @($Text -split "`r?`n")
        foreach ($hit in (Invoke-Gitleaks -Arguments @('stdin') -InputText $Text)) { $hits.Add($hit) }
    }
    'TextFile' {
        if (-not (Test-Path -LiteralPath $TextFile -PathType Leaf)) { Stop-Scanner 2 "Text file not found: $TextFile" }
        $content = Get-Content -LiteralPath $TextFile -Raw
        if ($null -eq $content) { $content = '' }
        Add-TextResult -Label (Split-Path -Leaf $TextFile) -Lines @($content -split "`r?`n")
        foreach ($hit in (Invoke-Gitleaks -Arguments @('stdin') -InputText $content)) { $hits.Add($hit) }
    }
}

foreach ($hit in ($hits | Sort-Object Path, Line, Rule)) {
    Write-Host ('{0}:{1}  {2}  {3}' -f $hit.Path, $hit.Line, $hit.Rule, $hit.Match) -ForegroundColor Yellow
}
if ($notScanned.Count -gt 0) {
    Write-Host ('Not scanned (binary): {0}' -f ($notScanned -join ', ')) -ForegroundColor DarkGray
}
if ($hits.Count -gt 0) {
    Write-Host ('FAIL: {0} hit(s). Fix the content, the denylist or the pattern. There is no bypass.' -f $hits.Count) -ForegroundColor Red
    exit 1
}
Write-Host 'Clean.' -ForegroundColor Green
exit 0
