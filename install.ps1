# bff installer for native Windows (PowerShell 5.1 and 7, no admin). Public; it downloads the bff release from the
# private triunai/bff repository through the GitHub CLI (gh), verifies SHA256SUMS, installs under
# %LOCALAPPDATA%\bff (a bff.cmd shim in %LOCALAPPDATA%\bff\bin), offers to add it to your user PATH, and runs
# `bff osiris setup`.
#   irm https://raw.githubusercontent.com/triunai/bff-install/main/install.ps1 | iex
# Options through environment variables (set them first, e.g. $env:BFF_YES = '1'):
#   BFF_YES=1  BFF_NO_SETUP=1  BFF_NO_MODIFY_PATH=1  BFF_PREFIX=<dir>  BFF_VERSION=x.y.z (default: latest release)
#   BFF_RELEASE_DIR=<dir holding bff-X.Y.Z.tar.gz and SHA256SUMS>  installs from that folder instead of gh (CI, offline);
#       the SHA256 check and the archive checks are the same as for a download.
#   BFF_RESULT_FILE=<file>  also writes install.py's JSON result there (the console also gets it).
# Everything runs inside a function and never calls `exit`, so piping into iex cannot close your terminal.
# Kept ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.

function Install-Bff {
    param(
        [switch]$Yes,
        [switch]$NoSetup,
        [switch]$NoModifyPath,
        [string]$Prefix,
        [string]$Version,
        [string]$ReleaseDir,
        [string]$ResultFile
    )
    $ErrorActionPreference = 'Stop'
    $repo = 'triunai/bff'
    $pythonHelp = "bff needs Python 3.9 or newer. Install it, then run this installer again:`n  winget install Python.Python.3.12"

    # One argument, quoted for CreateProcess (spaces, quotes, trailing backslashes).
    function ConvertTo-ArgString {
        param([string[]]$Items)
        $parts = @()
        foreach ($item in $Items) {
            $a = [string]$item
            if ($a -eq '') { $parts += '""' }
            elseif ($a -notmatch '[\s"]') { $parts += $a }
            else { $parts += ('"' + (($a -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"') }
        }
        return ($parts -join ' ')
    }

    # Runs a program with stdout and stderr captured SEPARATELY (no ErrorRecord wrapping, so 'Stop' cannot trip on
    # stderr text and install.py's JSON stays clean). Returns Code, Out, Err. TimeoutSec 0 means wait forever.
    function Invoke-Captured {
        param([string]$Exe, [string[]]$Arguments, [int]$TimeoutSec = 0)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = ConvertTo-ArgString $Arguments
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.EnvironmentVariables['PYTHONUTF8'] = '1'
        $proc = [System.Diagnostics.Process]::Start($psi)
        try {
            $proc.StandardInput.Close()
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $errTask = $proc.StandardError.ReadToEndAsync()
            $waitMs = -1
            if ($TimeoutSec -gt 0) { $waitMs = $TimeoutSec * 1000 }
            if (-not $proc.WaitForExit($waitMs)) {
                try { $proc.Kill() } catch { }
                return [pscustomobject]@{ Code = 124; Out = ''; Err = "timed out after $TimeoutSec seconds: $Exe" }
            }
            $proc.WaitForExit()
            return [pscustomobject]@{ Code = $proc.ExitCode; Out = [string]$outTask.Result; Err = [string]$errTask.Result }
        } finally {
            $proc.Dispose()
        }
    }

    # A usable Python is one that RUNS and is 3.9+. The Microsoft Store alias stub is a zero-byte file that exits
    # non-zero when given arguments, so it fails this probe; a real Store or winget Python passes it.
    function Find-Python {
        foreach ($candidate in @(@('py', '-3'), @('python'), @('python3'))) {
            $extra = @($candidate | Select-Object -Skip 1)
            $found = @(Get-Command $candidate[0] -CommandType Application -All -ErrorAction SilentlyContinue)
            foreach ($app in $found) {
                $probe = $null
                try { $probe = Invoke-Captured $app.Source ($extra + @('-c', 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 3)')) 60 } catch { continue }
                if ($probe.Code -eq 0) { return @($app.Source) + $extra }
            }
        }
        throw $pythonHelp
    }

    # Interactive means a person can answer. When run from a web one-liner stdin is usually the console, so also honour CI markers,
    # a hidden console and -NonInteractive; Read-Host is wrapped anyway.
    function Test-Interactive {
        if ($env:CI -or $env:GITHUB_ACTIONS -or $env:TF_BUILD) { return $false }
        if (-not [Environment]::UserInteractive) { return $false }
        try { if ([Console]::IsInputRedirected) { return $false } } catch { return $false }
        foreach ($arg in [Environment]::GetCommandLineArgs()) { if ($arg -imatch '^[-/]noni') { return $false } }
        return $true
    }

    $python = @(Find-Python)
    $pythonExe = $python[0]
    $pythonArgs = @($python | Select-Object -Skip 1)

    if ($Version -and $Version -notmatch '^[0-9]+(\.[0-9]+)*$') { throw 'BFF_VERSION must look like 1.2.3.' }

    $useGh = -not $ReleaseDir
    $gh = $null
    if ($useGh) {
        $gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $gh) {
            throw ("bff lives in a private repository, so this installer needs the GitHub CLI (gh).`n" +
                "  winget install --id GitHub.cli -e   (or https://cli.github.com)`n" +
                "Then run: gh auth login   (the account needs read access to $repo) and run this installer again.")
        }
        $auth = Invoke-Captured $gh.Source @('auth', 'status') 60
        if ($auth.Code -ne 0) { throw "The GitHub CLI is not signed in. Run: gh auth login   (the account needs read access to $repo), then run this installer again." }
    } elseif (-not (Test-Path -LiteralPath $ReleaseDir -PathType Container)) {
        throw "BFF_RELEASE_DIR is not a folder: $ReleaseDir"
    }

    $stage = Join-Path ([IO.Path]::GetTempPath()) ('bff-install-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage | Out-Null
    try {
        if ($useGh) {
            $downloadArgs = @('release', 'download')
            if ($Version) { $downloadArgs += "v$Version" }
            $downloadArgs += @('--repo', $repo, '--pattern', 'bff-*.tar.gz', '--pattern', 'SHA256SUMS', '--dir', $stage, '--clobber')
            $dl = Invoke-Captured $gh.Source $downloadArgs
            if ($dl.Code -ne 0) {
                if ($dl.Err) { Write-Host $dl.Err.Trim() }
                throw "Download failed. Check that this gh account can read $repo (gh release list --repo $repo) and that a release is published, then run this installer again."
            }
        } else {
            $pattern = 'bff-*.tar.gz'
            if ($Version) { $pattern = "bff-$Version.tar.gz" }
            $local = @(Get-ChildItem -LiteralPath $ReleaseDir -Filter $pattern -File)
            if ($local.Count -ne 1) { throw ("Expected one bff release archive in BFF_RELEASE_DIR, found " + $local.Count + ".") }
            $localSums = Join-Path $ReleaseDir 'SHA256SUMS'
            if (-not (Test-Path -LiteralPath $localSums -PathType Leaf)) { throw 'BFF_RELEASE_DIR has no SHA256SUMS file; refusing to install an unverified archive.' }
            Copy-Item -LiteralPath $local[0].FullName -Destination (Join-Path $stage $local[0].Name)
            Copy-Item -LiteralPath $localSums -Destination (Join-Path $stage 'SHA256SUMS')
            Write-Host "release source: $ReleaseDir"
        }

        $archives = @(Get-ChildItem -LiteralPath $stage -Filter 'bff-*.tar.gz' -File)
        if ($archives.Count -ne 1) { throw ("Expected one bff release archive, found " + $archives.Count + ". Run this installer again.") }
        $ver = $archives[0].Name -replace '^bff-', '' -replace '\.tar\.gz$', ''
        if ($ver -notmatch '^[0-9]+(\.[0-9]+)+$') { throw ("Unexpected release archive name: " + $archives[0].Name) }
        $sums = Join-Path $stage 'SHA256SUMS'
        if (-not (Test-Path -LiteralPath $sums)) { throw 'The release has no SHA256SUMS file; refusing to install an unverified archive.' }
        $tarball = Join-Path $stage 'release.tar.gz'
        Move-Item -Force -LiteralPath $archives[0].FullName -Destination $tarball

        $wanted = "bff-$ver.tar.gz"
        $rows = @(Get-Content -LiteralPath $sums | Where-Object { $_.Trim() } | ForEach-Object { , ($_.Trim() -split '\s+') } |
            Where-Object { $_.Count -eq 2 -and $_[1] -eq $wanted })
        if ($rows.Count -ne 1) { throw 'BFF archive checksum mismatch; installation stopped. Run the installer again; if it keeps failing, download it by hand from https://github.com/triunai/bff/releases.' }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $tarball).Hash.ToLower()
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
        $ex = Invoke-Captured $pythonExe ($pythonArgs + @($extractFile, $stage, $ver))
        if ($ex.Code -ne 0) {
            if ($ex.Err) { Write-Host $ex.Err.Trim() }
            throw 'BFF archive verification failed; installation stopped. The reason is printed above this line; run this installer again, or download the release by hand from https://github.com/triunai/bff/releases.'
        }

        $installer = Join-Path $stage "bff-$ver\install.py"
        if (-not (Test-Path -LiteralPath $installer)) { throw 'The release has no install.py; refusing to continue.' }
        $installArgs = @($installer)
        if ($Prefix) { $installArgs += @('--prefix', $Prefix) }
        $installArgs += '--no-modify-path'   # PATH is offered below, the PowerShell way
        $run = Invoke-Captured $pythonExe ($pythonArgs + $installArgs)
        if ($run.Err) { Write-Host $run.Err.Trim() }
        if ($run.Code -ne 0) { throw 'bff install failed; the reason is printed above this line. Fix it, then run this installer again.' }
        $json = $run.Out.Trim()
        $result = $null
        try { $result = $json | ConvertFrom-Json } catch { throw 'bff install printed something that is not JSON; run this installer again.' }
        $command = $result.command
        if (-not $command) { throw 'Could not find the bff command after installing. Run this installer again.' }
        Write-Output $json
        if ($ResultFile) { Set-Content -Path $ResultFile -Value $json -Encoding ASCII }
        $binDir = Split-Path -Parent $command
        Write-Host "bff $ver installed: $command"

        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $onPath = @($userPath -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ieq $binDir.TrimEnd('\')) }).Count -gt 0
        $interactive = Test-Interactive
        if (-not $onPath) {
            $answer = $null
            if ($interactive -and -not $Yes -and -not $NoModifyPath) {
                try { $answer = Read-Host "Add $binDir to your user PATH? [Y/n]" } catch { $answer = $null }
            }
            if ($null -ne $answer) {
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
        if (-not $Yes -and -not $interactive) {
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

Install-Bff -Yes:($env:BFF_YES -eq '1') -NoSetup:($env:BFF_NO_SETUP -eq '1') -NoModifyPath:($env:BFF_NO_MODIFY_PATH -eq '1') -Prefix $env:BFF_PREFIX -Version $env:BFF_VERSION -ReleaseDir $env:BFF_RELEASE_DIR -ResultFile $env:BFF_RESULT_FILE
