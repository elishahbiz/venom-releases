# venom

venom is a coding agent for the terminal that you run on your own machine. It reads and edits your
code, runs commands and works through tasks with you, against whichever model you point it at: a
local server, [Venom Cloud](https://cloud.usevenom.dev), or any OpenAI-compatible endpoint.

- **Permissions you can read.** Four modes, from plan (read-only) to yolo, and shell commands are
  parsed and checked against allow, ask and deny rules before they run.
- **An OS sandbox.** On macOS and Linux, the agent's shell commands in yolo run inside
  `sandbox-exec` or bubblewrap, with writes kept to the workspace and network through an allowlist.
- **Subagents, plan mode, `/undo`.** Delegate to built-in explorer, worker and verifier agents, plan
  before editing, and roll back a turn's file changes.
- **Plugins and hooks.** pi packages and Claude Code plugins load as they are; projects set up for
  Claude Code (CLAUDE.md, skills, agents, commands, hooks, MCP servers) work unchanged.
- **No telemetry.** No analytics and no update checks. With a local model it works offline.

This repository holds the release downloads, their checksums and the install scripts. More at
**https://cloud.usevenom.dev/cli**.

## Install

macOS and Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/elishahbiz/venom-releases/main/install.sh | sh
```

Windows (beta), in PowerShell:

```powershell
irm https://raw.githubusercontent.com/elishahbiz/venom-releases/main/install.ps1 | iex
```

The scripts download from this repository's [releases](https://github.com/elishahbiz/venom-releases/releases)
only, check the archive's SHA256 against the release's `SHA256SUMS` before unpacking it, and need no
root or administrator rights. venom goes to `~/.venom/releases/`, with `venom` linked from
`~/.venom/bin` (Windows: `%USERPROFILE%\.venom\bin\venom.cmd`, added to your user PATH). Set
`VENOM_VERSION=0.1.0` to install a given version, `VENOM_INSTALL_DIR` to install somewhere else,
and on macOS or Linux `VENOM_BIN_DIR=/usr/local/bin` to put the link there.

Each archive carries its own Node.js runtime, so there is nothing else to install.

| Platform | Download |
|---|---|
| macOS, Apple silicon | `venom-<version>-darwin-arm64.tar.gz` |
| macOS, Intel | `venom-<version>-darwin-x64.tar.gz` |
| Linux x64 (glibc) | `venom-<version>-linux-x64.tar.gz` |
| Linux arm64 (glibc) | `venom-<version>-linux-arm64.tar.gz` |
| Windows x64 (beta) | `venom-<version>-windows-x64.zip` |

### By hand

Download the archive for your platform and `SHA256SUMS` from the
[latest release](https://github.com/elishahbiz/venom-releases/releases/latest), then check it:

```sh
shasum -a 256 -c SHA256SUMS --ignore-missing     # Linux: sha256sum -c SHA256SUMS --ignore-missing
```

```powershell
Get-FileHash .\venom-<version>-windows-x64.zip -Algorithm SHA256   # compare with its line in SHA256SUMS
```

Unpack it anywhere and run `bin/venom` (Windows: `bin\venom.cmd`, or `bin\venom.ps1` from
PowerShell). Put `bin/` on your PATH to run `venom` from anywhere.

## First run

venom talks to an OpenAI-compatible endpoint, set with two variables.

With [Venom Cloud](https://cloud.usevenom.dev), which routes to your own GPUs, trusted nodes and
your provider keys (create a `vck_` key in the console under Keys):

```sh
export VENOM_BASE_URL=https://cloud.usevenom.dev/v1
export VENOM_API_KEY=vck_...
venom
```

Offline, with a local model server such as [Ollama](https://ollama.com):

```sh
export VENOM_BASE_URL=http://localhost:11434/v1
export VENOM_MODEL=qwen3:8b
venom
```

`venom doctor` checks the setup and says what to fix. `venom -p "explain this repo"` runs one prompt
and exits.

## Windows (beta)

There is no OS sandbox on Windows. venom says so when it starts, asks before shell commands that
would run sandboxed on macOS or Linux (yolo keeps asking like accept-edits) and does not offer auto
mode. It gets less testing than macOS and Linux; if something breaks, tell us at
joel@elishah.biz.

## License

venom is MIT licensed; see [LICENSE](LICENSE). Each archive also carries the Node.js licence
(`runtime/LICENSE`) and the licences of the packages it bundles (`THIRD_PARTY_NOTICES`). This
repository holds release artifacts only; it contains no source code.
