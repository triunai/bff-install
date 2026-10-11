# bff-install

## Why the name

**BFF stands for Built Fucking Fast.** Speed here doesn't mean how quickly an agent types out code. It means not re-deriving decisions that were already made, not losing context when a chat ends, and not finding out days later that the tests never ran the path that broke. The full story is in [the bff README](https://github.com/triunai/bff#why-the-name).

## What this repo is

Short installers for [bff](https://github.com/triunai/bff). This repository holds only the two install scripts; the product lives in the public `triunai/bff` repository and is downloaded over plain HTTPS, verified against its `SHA256SUMS`. No login is needed; if the GitHub CLI (`gh`) is installed and signed in it is used instead.

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

You don't need npm, nvm or Node to install bff. The only hard requirement is Python.

| Tool | Needed for | Required? |
| --- | --- | --- |
| **Python 3.9+** | bff itself, and the installer's checksum check | **Yes.** macOS/Linux: `python3`. Windows: `py -3` or `python` (the Microsoft Store stub is refused); `winget install Python.Python.3.12` if missing. The installer stops and tells you the exact command if it's absent. |
| `curl` or `wget` | the download on macOS/Linux | Already on every Mac and almost every Linux. Windows uses PowerShell's own downloader. |
| Git | adopting a repo (`bff` reads your repo's history) | Only for repo features. |
| Node 22.6+ | the terminal apps (`bff osiris factory`, `worktrees`, `prune`) | No. Only when you use those. Any normal install is found: nodejs.org, Homebrew, nvm, fnm, volta or mise (Windows: Program Files, winget, scoop, fnm, nvm-windows, volta). On Windows install the real `node.exe`; `node.cmd` wrappers are refused. |
| BB | Osiris, the dashboard inside BB | No. BB is a separate app with its own installer, and it brings its own Node requirement (22.19+). If BB is missing, setup tells you what to install and bff still works. |
| GitHub CLI (`gh`) | nothing | No. Nothing to sign in to: the release is public and downloads over plain HTTPS. If `gh` is installed and signed in, it's used instead (`BFF_DOWNLOAD=https` forces the plain download, `BFF_DOWNLOAD=gh` forces `gh`). |

npm and nvm only matter if you're developing bff or Osiris (running the Osiris tests or rebuilding the plugin), and then you need Node 24.

## What it does

1. Checks Python; if it is missing it prints the exact command to fix it.
2. Downloads the latest bff release (archive plus `SHA256SUMS`) from `https://github.com/triunai/bff/releases/latest/download/` (or with `gh release download` when `gh` is signed in) into a temporary folder.
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

Windows reads environment variables, set before the one-liner: `$env:BFF_YES='1'`, `$env:BFF_NO_SETUP='1'`, `$env:BFF_NO_MODIFY_PATH='1'`, `$env:BFF_PREFIX='D:\tools\bff'`. Both platforms accept `BFF_VERSION=x.y.z` to install a specific release instead of the latest. On Windows, `BFF_RELEASE_DIR=<folder with bff-X.Y.Z.tar.gz and SHA256SUMS>` installs from that folder instead of downloading (CI, offline); the SHA-256 check is the same.

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

Piping a download into a shell runs whatever the URL serves. Read the script first, it is short: [install.sh](install.sh), [install.ps1](install.ps1). They do not contain bff itself; they fetch it from `triunai/bff` and refuse to install anything whose SHA-256 does not match the release's `SHA256SUMS`. They never use sudo or admin rights, never write outside the install folder and the PATH entry you approve, and never send credentials anywhere (the plain download sends none; with `gh`, authentication stays inside `gh`).

`check.sh` scans this repository for personal paths, emails, tokens and stray internal names. `test/pipe-test.sh` exercises `install.sh` end to end with a fake `gh`.

## Windows status

The native Windows path (the `bff.cmd` shim, the `%LOCALAPPDATA%` layout and the PowerShell installer) runs on GitHub's real `windows-latest` machines under PowerShell 5.1 and 7, with Python 3.9 and 3.12. The real `irm ... | iex` one-liner installs the published release there, and `bff doctor` and `bff osiris prune` pass. It hasn't been tried on a personal Windows laptop yet. Herdr and the macOS keep-awake helper have no Windows build. If something fails, the message says why; WSL2 with the macOS/Linux command is the fallback.

## License

MIT, see [LICENSE](LICENSE).
