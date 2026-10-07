# bff-install

Short installers for [bff](https://github.com/triunai/bff). This repository holds only the two install scripts; the product lives in the private `triunai/bff` repository and is downloaded through your own GitHub login.

## Install

macOS and Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/triunai/bff-install/main/install.sh | sh
```

Windows (PowerShell 5.1 or 7, no admin rights needed):

```powershell
irm https://raw.githubusercontent.com/triunai/bff-install/main/install.ps1 | iex
```

Run either from any directory. Re-running is safe: it installs the same verified release again or moves to a newer one.

## Before you run it

- **GitHub CLI (`gh`)**, signed in: `gh auth login`. The account must have read access to `triunai/bff`. If it does not, the download step fails and says so.
- **Python 3.9 or newer** (`python3` on macOS/Linux, `py -3` or `python` on Windows; the Microsoft Store stub is refused).
- **BB** is needed for Osiris, not for bff itself. If it is missing, setup tells you what to install and bff still works.

## What it does

1. Checks Python, `gh` and `gh auth status`; if something is missing it prints the exact command to fix it.
2. Downloads the latest bff release (archive plus `SHA256SUMS`) with `gh release download --repo triunai/bff` into a temporary folder.
3. Verifies the archive against `SHA256SUMS`, bounds its size, refuses unsafe archive entries, and only then extracts it.
4. Installs for your user only, with no sudo and no admin: macOS/Linux under `~/.local` (command `~/.local/bin/bff`), Windows under `%LOCALAPPDATA%\bff` (command `bin\bff.cmd`).
5. Offers once to add the command directory to your PATH (a marked line in your shell startup file, or your user PATH on Windows). It never edits anything without asking, and never in `--yes` or non-interactive runs.
6. Runs `bff osiris setup`.
7. Deletes its temporary folder on exit.

Questions are read from your terminal (`/dev/tty`), never from the pipe. With no terminal and no `--yes`, the installer asks nothing and skips setup, telling you the command to run later.

### Options

macOS/Linux (pass them after `sh -s --`, for example `... | sh -s -- --no-setup`):

| Option | Effect |
| --- | --- |
| `--yes` | never ask; answer yes to setup, do not edit PATH |
| `--no-setup` | install only; skip `bff osiris setup` |
| `--no-modify-path` | never edit a shell startup file |
| `--prefix DIR` | install under DIR instead of `~/.local` |

Windows reads environment variables, set before the one-liner: `$env:BFF_YES='1'`, `$env:BFF_NO_SETUP='1'`, `$env:BFF_NO_MODIFY_PATH='1'`, `$env:BFF_PREFIX='D:\tools\bff'`. Both platforms accept `BFF_VERSION=x.y.z` to install a specific release instead of the latest.

## Uninstall

macOS/Linux:

```sh
rm -f ~/.local/bin/bff
rm -rf ~/.local/share/bff
```

Then delete the two lines the installer added to your shell startup file (`~/.zprofile`, `~/.bash_profile`, `~/.bashrc`, `~/.profile` or `~/.config/fish/conf.d/bff.fish`): the `# added by the bff installer` comment and the `export PATH=...` line under it.

Windows (PowerShell):

```powershell
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\bff"
$bin = "$env:LOCALAPPDATA\bff\bin"
$path = [Environment]::GetEnvironmentVariable('Path', 'User') -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ine $bin }
[Environment]::SetEnvironmentVariable('Path', ($path -join ';'), 'User')
```

## Security

Piping a download into a shell runs whatever the URL serves. Read the script first, it is short: [install.sh](install.sh), [install.ps1](install.ps1). They do not contain bff itself; they fetch it from `triunai/bff` using your GitHub login and refuse to install anything whose SHA-256 does not match the release's `SHA256SUMS`. They never use sudo or admin rights, never write outside the install folder and the PATH entry you approve, and never send your credentials anywhere (authentication stays inside `gh`).

`check.sh` scans this repository for personal paths, emails, tokens and stray internal names. `test/pipe-test.sh` exercises `install.sh` end to end with a fake `gh`.

## Windows status

The native Windows path (the `bff.cmd` shim, `%LOCALAPPDATA%` layout, PowerShell installer) is new. It is covered by tests that simulate Windows paths, but it has not yet been run on a real Windows machine. If it fails, the message says why; WSL2 with the macOS/Linux command is the fallback.

## License

MIT, see [LICENSE](LICENSE).
