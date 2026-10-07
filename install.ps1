# bff installer for native Windows (PowerShell 5.1 and 7, no admin). Public; it downloads the bff release from the
# private triunai/bff repository through the GitHub CLI (gh), verifies SHA256SUMS, installs under
# %LOCALAPPDATA%\bff (a bff.cmd shim in %LOCALAPPDATA%\bff\bin), offers to add it to your user PATH, and runs
# `bff osiris setup`.
#   irm https://raw.githubusercontent.com/triunai/bff-install/main/install.ps1 | iex
# Options through environment variables (set them first, e.g. $env:BFF_YES = '1'):
#   BFF_YES=1  BFF_NO_SETUP=1  BFF_NO_MODIFY_PATH=1  BFF_PREFIX=<dir>  BFF_VERSION=x.y.z (default: latest release)
# Everything runs inside a function and never calls `exit`, so piping into iex cannot close your terminal.
# Kept ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.

function Install-Bff {
    param(
        [switch]$Yes,
        [switch]$NoSetup,
        [switch]$NoModifyPath,
        [string]$Prefix,
        [string]$Version
    )
    $ErrorActionPreference = 'Stop'
    $repo = 'triunai/bff'
    $pythonHelp = "bff needs Python 3.9 or newer. Install it, then run this installer again:`n  winget install Python.Python.3.12"

    # Native commands may write to stderr; that must not become a terminating error under 'Stop'.
    function Invoke-Native {
        param([string]$Exe, [string[]]$Arguments, [switch]$Quiet)
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & $Exe @Arguments 2>&1 | ForEach-Object { if (-not $Quiet) { Write-Host $_ } } } finally { $ErrorActionPreference = $saved }
        return $LASTEXITCODE
    }

    function Find-Python {
        foreach ($candidate in @(@('py', '-3'), @('python'))) {
            $found = Get-Command $candidate[0] -ErrorAction SilentlyContinue
            if (-not $found) { continue }
            if ($found.Source -match '\\WindowsApps\\') {
                throw ("Refusing the Microsoft Store Python stub at " + $found.Source + ". " + $pythonHelp)
            }
            return @($found.Source) + @($candidate | Select-Object -Skip 1)
        }
        throw $pythonHelp
    }

    $python = @(Find-Python)
    $pythonExe = $python[0]
    $pythonArgs = @($python | Select-Object -Skip 1)
    & $pythonExe @pythonArgs -c "import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)"
    if ($LASTEXITCODE -ne 0) { throw $pythonHelp }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw ("bff lives in a private repository, so this installer needs the GitHub CLI (gh).`n" +
            "  winget install --id GitHub.cli -e   (or https://cli.github.com)`n" +
            "Then run: gh auth login   (the account needs read access to $repo) and run this installer again.")
    }
    $authCode = Invoke-Native 'gh' @('auth', 'status') -Quiet
    if ($authCode -ne 0) { throw "The GitHub CLI is not signed in. Run: gh auth login   (the account needs read access to $repo), then run this installer again." }

    $stage = Join-Path ([IO.Path]::GetTempPath()) ('bff-install-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        $downloadArgs = @('release', 'download')
        if ($Version) {
            if ($Version -notmatch '^[0-9]+(\.[0-9]+)*$') { throw 'BFF_VERSION must look like 1.2.3.' }
            $downloadArgs += "v$Version"
        }
        $downloadArgs += @('--repo', $repo, '--pattern', 'bff-*.tar.gz', '--pattern', 'SHA256SUMS', '--dir', $stage, '--clobber')
        $code = Invoke-Native 'gh' $downloadArgs
        if ($code -ne 0) { throw "Download failed. Check that this gh account can read $repo (gh release list --repo $repo) and that a release is published, then run this installer again." }

        $archives = @(Get-ChildItem -Path $stage -Filter 'bff-*.tar.gz' -File)
        if ($archives.Count -ne 1) { throw ("Expected one bff release archive, found " + $archives.Count + ". Run this installer again.") }
        $ver = $archives[0].Name -replace '^bff-', '' -replace '\.tar\.gz$', ''
        if ($ver -notmatch '^[0-9]+(\.[0-9]+)+$') { throw ("Unexpected release archive name: " + $archives[0].Name) }
        $sums = Join-Path $stage 'SHA256SUMS'
        if (-not (Test-Path $sums)) { throw 'The release has no SHA256SUMS file; refusing to install an unverified archive.' }
        $tarball = Join-Path $stage 'release.tar.gz'
        Move-Item -Force -Path $archives[0].FullName -Destination $tarball

        $wanted = "bff-$ver.tar.gz"
        $rows = @(Get-Content $sums | Where-Object { $_.Trim() } | ForEach-Object { , ($_.Trim() -split '\s+') } |
            Where-Object { $_.Count -eq 2 -and $_[1] -eq $wanted })
        if ($rows.Count -ne 1) { throw 'BFF archive checksum mismatch; installation stopped. Run the installer again; if it keeps failing, download it by hand from https://github.com/triunai/bff/releases.' }
        $actual = (Get-FileHash -Algorithm SHA256 -Path $tarball).Hash.ToLower()
        if ($actual -ne $rows[0][0].ToLower()) { throw 'BFF archive checksum mismatch; installation stopped. Run the installer again; if it keeps failing, download it by hand from https://github.com/triunai/bff/releases.' }

        # Same entry checks and extraction program as install.sh (a test keeps the two texts identical).
        $extract = @'
import hashlib, pathlib, sys, tarfile
stage, version = pathlib.Path(sys.argv[1]), sys.argv[2]
archive = stage / 'release.tar.gz'
rows = [r.split() for r in (stage / 'SHA256SUMS').read_text().splitlines() if r.strip()]
expected = [r[0] for r in rows if len(r) == 2 and r[1] == 'bff-' + version + '.tar.gz']
if len(expected) != 1 or hashlib.sha256(archive.read_bytes()).hexdigest() != expected[0]:
    raise SystemExit('BFF archive checksum mismatch; installation stopped. Run the installer again; if it keeps failing, download it by hand from https://github.com/triunai/bff/releases.')
root = 'bff-' + version
with tarfile.open(archive, 'r:gz') as tf:
    members = tf.getmembers()
    if len(members) > 5000 or sum(m.size for m in members) > 100 * 1024 * 1024:
        raise SystemExit('BFF archive exceeds bounded release limits. This should not happen with an official release; download it by hand from https://github.com/triunai/bff/releases.')
    seen = set()
    for m in members:
        path = pathlib.PurePosixPath(m.name)
        if (path.is_absolute() or '..' in path.parts or not path.parts or
                path.parts[0] != root or not (m.isfile() or m.isdir()) or
                m.name != path.as_posix() or path.as_posix() in seen):
            raise SystemExit('BFF archive contains an unsafe entry. This should not happen with an official release; download it by hand from https://github.com/triunai/bff/releases.')
        seen.add(path.as_posix())
    for m in members:
        target = stage / m.name
        if m.isdir():
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(tf.extractfile(m).read())
            target.chmod(0o755 if m.name.endswith('/install.sh') else 0o644)

'@
        $extractFile = Join-Path $stage 'extract.py'
        Set-Content -Path $extractFile -Value $extract -Encoding ASCII
        & $pythonExe @pythonArgs $extractFile $stage $ver
        if ($LASTEXITCODE -ne 0) { throw 'BFF archive verification failed; installation stopped. The reason is printed above this line; run this installer again, or download the release by hand from https://github.com/triunai/bff/releases.' }

        $installer = Join-Path $stage "bff-$ver\install.py"
        if (-not (Test-Path $installer)) { throw 'The release has no install.py; refusing to continue.' }
        $installArgs = @()
        if ($Prefix) { $installArgs += @('--prefix', $Prefix) }
        $installArgs += '--no-modify-path'   # PATH is offered below, the PowerShell way
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $output = & $pythonExe @pythonArgs $installer @installArgs } finally { $ErrorActionPreference = $saved }
        if ($LASTEXITCODE -ne 0) { throw 'bff install failed; the reason is printed above this line. Fix it, then run this installer again.' }
        $output | ForEach-Object { Write-Host $_ }
        $result = ($output -join "`n") | ConvertFrom-Json
        $command = $result.command
        if (-not $command) { throw 'Could not find the bff command after installing. Run this installer again.' }
        $binDir = Split-Path -Parent $command
        Write-Host "bff $ver installed: $command"

        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $onPath = @($userPath -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ieq $binDir.TrimEnd('\')) }).Count -gt 0
        if (-not $onPath) {
            $interactive = -not $Yes -and -not $NoModifyPath -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
            if ($interactive) {
                $answer = Read-Host "Add $binDir to your user PATH? [Y/n]"
                if ($answer -eq '' -or $answer -match '^(y|yes)$') {
                    $new = if ($userPath) { $userPath.TrimEnd(';') + ';' + $binDir } else { $binDir }
                    [Environment]::SetEnvironmentVariable('Path', $new, 'User')
                    Write-Host 'Added to your user PATH. Open a new terminal to pick it up.'
                } else {
                    Write-Host "Add $binDir to your user PATH to run bff by name."
                }
            } else {
                Write-Host "Add $binDir to your user PATH to run bff by name (not edited: BFF_YES, BFF_NO_MODIFY_PATH or no console)."
            }
        }

        if ($NoSetup) {
            Write-Host 'Skipped Osiris setup (BFF_NO_SETUP). Later: bff osiris setup'
            return
        }
        $interactiveSetup = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
        if (-not $Yes -and -not $interactiveSetup) {
            Write-Host 'No console to ask questions on, so Osiris setup was skipped. Later, in a terminal: bff osiris setup'
            return
        }
        $setupArgs = @('osiris', 'setup')
        if ($Yes) { $setupArgs += '--yes' }
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { & $command @setupArgs } finally { $ErrorActionPreference = $saved }
        $setupCode = $LASTEXITCODE
        if ($setupCode -eq 3) { Write-Host 'bff is installed; Osiris setup is waiting on the prerequisites listed above. Install them, then run: bff osiris setup'; return }
        if ($setupCode -eq 4) { Write-Host 'bff is installed. Osiris is not publicly released yet, so there is nothing more to set up; run: bff --help'; return }
        if ($setupCode -ne 0) { throw "bff osiris setup exited with code $setupCode (bff itself is installed)." }
    } finally {
        Remove-Item -Recurse -Force -Path $stage -ErrorAction SilentlyContinue
    }
}

Install-Bff -Yes:($env:BFF_YES -eq '1') -NoSetup:($env:BFF_NO_SETUP -eq '1') -NoModifyPath:($env:BFF_NO_MODIFY_PATH -eq '1') -Prefix $env:BFF_PREFIX -Version $env:BFF_VERSION
