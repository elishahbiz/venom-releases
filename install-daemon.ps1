# Install the Venom daemon on Windows (beta) from its public releases, then start it and open its
# dashboard. In PowerShell:
#
#   irm https://raw.githubusercontent.com/elishahbiz/venom-releases/main/install-daemon.ps1 | iex
#
# Downloads only from https://github.com/elishahbiz/venom-releases/releases, checks the zip against
# the release's SHA256SUMS before unpacking anything, and needs no administrator rights. The zip
# holds the launcher, the orchestrator, the dashboard and the Node.js runtime it runs on. Local
# models need Ollama, which the dashboard links to (you install it yourself).
#
#   $env:VENOM_VERSION = '0.2.0'     install that version instead of the latest
#   $env:VENOM_INSTALL_DIR           where releases are unpacked (default ~\.venom; they go in releases\)
#   $env:VENOM_DAEMON_NO_START = '1' install only
#   $env:VENOM_DAEMON_NO_OPEN = '1'  start it, but don't open a browser
#
# It adds a Start Menu shortcut, Venom Daemon, and venom-daemon.cmd in <install dir>\bin (on your
# user PATH). The daemon keeps its data in %LOCALAPPDATA%\Venom.
#
# Windows support is beta: stopping the daemon ends it at once (running mesh jobs are cut).

function Install-VenomDaemon {
	$ErrorActionPreference = 'Stop'
	$ProgressPreference = 'SilentlyContinue'
	$releases = 'https://github.com/elishahbiz/venom-releases/releases'
	try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

	$arch = $env:PROCESSOR_ARCHITECTURE
	if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
	if ($arch -ne 'AMD64' -and $arch -ne 'ARM64') { throw "venom-daemon install: no daemon build for $arch Windows; there is a build for x64" }
	if ($arch -eq 'ARM64') { Write-Host 'venom-daemon: Windows on ARM runs the x64 build under emulation.' }

	$installDir = if ($env:VENOM_INSTALL_DIR) { $env:VENOM_INSTALL_DIR } else { Join-Path $HOME '.venom' }
	if ($env:VENOM_VERSION) {
		$want = $env:VENOM_VERSION -replace '^v', ''
		if ($want -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$') { throw "venom-daemon install: VENOM_VERSION '$($env:VENOM_VERSION)' is not a version like 0.2.0" }
		$base = "$releases/download/v$want"
	} else {
		$base = "$releases/latest/download"
	}

	$tmp = Join-Path ([IO.Path]::GetTempPath()) ("venom-daemon-install-" + [Guid]::NewGuid().ToString('N'))
	New-Item -ItemType Directory -Path $tmp | Out-Null
	try {
		Write-Host 'venom-daemon: finding the release for windows-x64'
		$sumsFile = Join-Path $tmp 'SHA256SUMS'
		Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile $sumsFile
		$re = '^([0-9a-f]{64})  (venom-daemon-([0-9][0-9A-Za-z.-]*)-windows-x64\.zip)$'
		$line = Get-Content $sumsFile | Where-Object { $_ -match $re } | Select-Object -First 1
		if (-not $line) { throw 'venom-daemon install: the release has no daemon archive for windows-x64' }
		$null = $line -match $re
		$sum = $Matches[1]; $asset = $Matches[2]; $version = $Matches[3]
		$name = $asset -replace '\.zip$', ''

		Write-Host "venom-daemon: downloading $asset"
		$zip = Join-Path $tmp $asset
		Invoke-WebRequest -UseBasicParsing -Uri "$releases/download/v$version/$asset" -OutFile $zip
		$got = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
		if ($got -ne $sum) { throw "venom-daemon install: checksum mismatch for $asset (SHA256 $got, SHA256SUMS says $sum); nothing was installed" }
		Write-Host "venom-daemon: SHA256 verified ($sum)"

		$unpack = Join-Path $tmp 'unpack'
		Expand-Archive -LiteralPath $zip -DestinationPath $unpack
		$exe = Join-Path $unpack 'venom-daemon\bin\venom-daemon.exe'
		if (-not (Test-Path -LiteralPath $exe)) { throw "venom-daemon install: $asset does not hold venom-daemon\bin\venom-daemon.exe" }

		$relDir = Join-Path $installDir 'releases'
		$binDir = Join-Path $installDir 'bin'
		New-Item -ItemType Directory -Force -Path $relDir, $binDir | Out-Null
		$shimPath = Join-Path $binDir 'venom-daemon.cmd'
		if (Test-Path -LiteralPath $shimPath) { & $shimPath stop *> $null }
		$dest = Join-Path $relDir $name
		if (Test-Path -LiteralPath $dest) { Remove-Item -Recurse -Force -LiteralPath $dest }
		Move-Item -LiteralPath (Join-Path $unpack 'venom-daemon') -Destination $dest
		Get-ChildItem -LiteralPath $relDir -Directory -Filter 'venom-daemon-*' | Where-Object {
			$_.FullName -ne $dest -and (Test-Path -LiteralPath (Join-Path $_.FullName '.venom-daemon-home'))
		} | ForEach-Object { Remove-Item -Recurse -Force -LiteralPath $_.FullName -ErrorAction SilentlyContinue }

		$daemon = Join-Path $dest 'bin\venom-daemon.exe'
		$shim = "@echo off`r`n`"$daemon`" %*`r`nexit /b %ERRORLEVEL%`r`n"
		[IO.File]::WriteAllText($shimPath, $shim, (New-Object Text.ASCIIEncoding))
		$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
		$parts = @(); if ($userPath) { $parts = $userPath -split ';' | Where-Object { $_ } }
		if ($parts -notcontains $binDir) {
			[Environment]::SetEnvironmentVariable('Path', (($parts + $binDir) -join ';'), 'User')
			Write-Host "venom-daemon: added $binDir to your user PATH (new terminals pick it up)"
		}

		$installed = & $daemon version
		if ($LASTEXITCODE -ne 0) { throw "venom-daemon install: the installed venom-daemon did not run: $installed" }
		& $daemon shortcut
		if ((& $daemon autostart status) -match 'true') { & $daemon autostart on *> $null }
		Write-Host ''
		Write-Host "Venom daemon $installed installed: $shimPath -> $dest"
		Write-Host 'Launch it any time from the Start Menu: Venom Daemon.'
		Write-Host 'Windows support is beta: stopping the daemon ends it at once (running mesh jobs are cut).'

		if ($env:VENOM_DAEMON_NO_START -eq '1') { Write-Host "Start it with: venom-daemon"; return }
		Write-Host ''
		if ($env:VENOM_DAEMON_NO_OPEN -eq '1') { & $daemon start --no-open } else { & $daemon start }
		if ($LASTEXITCODE -ne 0) { throw 'venom-daemon install: the daemon did not start; see venom-daemon logs' }
		Write-Host ''
		Write-Host 'Next, in the dashboard: install Ollama if it asks, then Connect to Venom Cloud with a join token'
		Write-Host 'from https://cloud.usevenom.dev (Daemons, Connect a daemon). Docs: https://cloud.usevenom.dev/daemon'
	} finally {
		Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
	}
}

Install-VenomDaemon
