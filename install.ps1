# Install the venom CLI on Windows (beta) from its public releases. In PowerShell:
#
#   irm https://raw.githubusercontent.com/elishahbiz/venom-releases/main/install.ps1 | iex
#
# Downloads only from https://github.com/elishahbiz/venom-releases/releases, checks the zip against
# the release's SHA256SUMS before unpacking anything, and needs no administrator rights. The zip
# carries its own Node.js runtime, so nothing else is installed.
#
#   $env:VENOM_VERSION = '0.1.0'   install that version instead of the latest
#   $env:VENOM_INSTALL_DIR         where releases are unpacked (default ~\.venom; they go in releases\)
#
# venom.cmd lands in <install dir>\bin, which is added to your user PATH.
#
# Windows support is beta: there is no OS sandbox on Windows (venom uses sandbox-exec on macOS and
# bubblewrap on Linux), so venom asks before shell commands that would run sandboxed elsewhere.

function Install-Venom {
	$ErrorActionPreference = 'Stop'
	$ProgressPreference = 'SilentlyContinue'
	$releases = 'https://github.com/elishahbiz/venom-releases/releases'
	# Windows PowerShell 5.1 may default to TLS 1.0, which GitHub refuses.
	try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

	$arch = $env:PROCESSOR_ARCHITECTURE
	if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
	if ($arch -ne 'AMD64' -and $arch -ne 'ARM64') { throw "venom install: no venom build for $arch Windows; there is a build for x64" }
	if ($arch -eq 'ARM64') { Write-Host 'venom: Windows on ARM runs the x64 build under emulation.' }

	$installDir = if ($env:VENOM_INSTALL_DIR) { $env:VENOM_INSTALL_DIR } else { Join-Path $HOME '.venom' }
	if ($env:VENOM_VERSION) {
		$want = $env:VENOM_VERSION -replace '^v', ''
		if ($want -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$') { throw "venom install: VENOM_VERSION '$($env:VENOM_VERSION)' is not a version like 0.1.0" }
		$base = "$releases/download/v$want"
	} else {
		$base = "$releases/latest/download"
	}

	$tmp = Join-Path ([IO.Path]::GetTempPath()) ("venom-install-" + [Guid]::NewGuid().ToString('N'))
	New-Item -ItemType Directory -Path $tmp | Out-Null
	try {
		Write-Host 'venom: finding the release for windows-x64'
		$sumsFile = Join-Path $tmp 'SHA256SUMS'
		Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile $sumsFile
		$line = Get-Content $sumsFile | Where-Object { $_ -match '^([0-9a-f]{64})  (venom-([0-9][0-9A-Za-z.-]*)-windows-x64\.zip)$' } | Select-Object -First 1
		if (-not $line) { throw 'venom install: the release has no archive for windows-x64' }
		$null = $line -match '^([0-9a-f]{64})  (venom-([0-9][0-9A-Za-z.-]*)-windows-x64\.zip)$'
		$sum = $Matches[1]; $asset = $Matches[2]; $version = $Matches[3]
		$name = $asset -replace '\.zip$', ''

		# The archive from its version's own URL, so it matches the SHA256SUMS just read.
		Write-Host "venom: downloading $asset"
		$zip = Join-Path $tmp $asset
		Invoke-WebRequest -UseBasicParsing -Uri "$releases/download/v$version/$asset" -OutFile $zip
		$got = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
		if ($got -ne $sum) { throw "venom install: checksum mismatch for $asset (SHA256 $got, SHA256SUMS says $sum); nothing was installed" }
		Write-Host "venom: SHA256 verified ($sum)"

		$unpack = Join-Path $tmp 'unpack'
		Expand-Archive -LiteralPath $zip -DestinationPath $unpack
		$cmd = Join-Path $unpack "$name\bin\venom.cmd"
		if (-not (Test-Path -LiteralPath $cmd)) { throw "venom install: $asset does not hold $name\bin\venom.cmd" }

		$relDir = Join-Path $installDir 'releases'
		$binDir = Join-Path $installDir 'bin'
		New-Item -ItemType Directory -Force -Path $relDir, $binDir | Out-Null
		$dest = Join-Path $relDir $name
		if (Test-Path -LiteralPath $dest) { Remove-Item -Recurse -Force -LiteralPath $dest }
		Move-Item -LiteralPath (Join-Path $unpack $name) -Destination $dest

		# A small shim on PATH that runs this release's launcher.
		$shim = "@echo off`r`n`"$dest\bin\venom.cmd`" %*`r`nexit /b %ERRORLEVEL%`r`n"
		[IO.File]::WriteAllText((Join-Path $binDir 'venom.cmd'), $shim, (New-Object Text.ASCIIEncoding))

		$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
		$parts = @(); if ($userPath) { $parts = $userPath -split ';' | Where-Object { $_ } }
		if ($parts -notcontains $binDir) {
			[Environment]::SetEnvironmentVariable('Path', (($parts + $binDir) -join ';'), 'User')
			Write-Host "venom: added $binDir to your user PATH (new terminals pick it up)"
		}
		if (($env:Path -split ';') -notcontains $binDir) { $env:Path = "$env:Path;$binDir" }

		$installed = & (Join-Path $binDir 'venom.cmd') --version
		if ($LASTEXITCODE -ne 0) { throw "venom install: the installed venom did not run: $installed" }
		Write-Host ''
		Write-Host "venom $installed installed: $binDir\venom.cmd -> $dest"
		Write-Host ''
		Write-Host 'Windows support is beta. There is no OS sandbox on Windows, so venom asks before'
		Write-Host 'shell commands that would run sandboxed on macOS or Linux (yolo keeps asking, auto is off).'
		Write-Host ''
		Write-Host 'Next: point venom at a model (Venom Cloud, or any OpenAI-compatible endpoint) and start it:'
		Write-Host '  $env:VENOM_BASE_URL = "https://cloud.usevenom.dev/v1"'
		Write-Host '  $env:VENOM_API_KEY = "vck_..."     # from https://cloud.usevenom.dev'
		Write-Host '  venom                             # venom doctor checks the setup'
		Write-Host 'Docs: https://cloud.usevenom.dev/cli'
	} finally {
		Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
	}
}

Install-Venom
