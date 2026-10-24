# exoit

Code from [exoit.se](https://exoit.se): a GPU screensaver, and PowerShell for Microsoft 365,
Entra ID, Intune, Exchange and Windows administration. Written with an AI pair, reviewed
and run for real, published when they have earned it.

## What is here

| Folder | Contents |
|---|---|
| `screensaver/AcidFlow` | Psychedelic flow field screensaver. One HTML file plus a Windows `.scr` host |
| `scripts/<Category>` | Administration scripts, grouped the way the private source repository groups them |
| `tools` | The guard that keeps this repository clean (below) |

Every script has comment-based help: `Get-Help .\Script.ps1 -Full`. Scripts that change
anything support `-WhatIf`.

## The guard

Nothing in this repository names a customer, a tenant, a user, a host or a network, and
nothing holds a secret. That is not a promise, it is a pipeline:

1. `tools/Test-PublicSafety.ps1` scans for secrets (via [gitleaks](https://github.com/gitleaks/gitleaks)),
   for generic patterns (GUIDs, e-mail addresses, IP addresses, UNC paths, SIDs, tokens,
   connection strings) and for a private denylist of names that never leaves the author's
   machines.
2. Git hooks (`.githooks/`) run the scanner on every commit, commit message and push.
   `tools/Install-Guard.ps1` wires them up.
3. A GitHub Action runs gitleaks on every push.

The scanner fails closed: a missing denylist or a missing gitleaks blocks, it never passes.

### Use the scanner on your own repository

```powershell
# Once per clone: hooks, git config, gitleaks via winget
.\tools\Install-Guard.ps1 -DenylistPath C:\path\to\your\Denylist.psd1

# Any time
.\tools\Test-PublicSafety.ps1 -Path .\src
.\tools\Test-PublicSafety.ps1 -Staged
.\tools\Test-PublicSafety.ps1 -Range origin/main..HEAD
```

The denylist is a `.psd1` with the keys `Words`, `Domains`, `Hosts`, `Networks`, `Guids`
and `Allow`; the scanner's help shows the shape.

## Licence

MIT. See `LICENSE`.
