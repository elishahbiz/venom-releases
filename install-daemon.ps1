# Install the Petawork daemon (`petawork-daemon`, with `venom-daemon` as an alias) on Windows (beta) from
# its public releases, then start it and open its dashboard. In PowerShell:
#
#   irm https://raw.githubusercontent.com/elishahbiz/venom-releases/main/install-daemon.ps1 | iex
#
# Downloads only from https://github.com/elishahbiz/venom-releases/releases, checks the zip against
# the release's SHA256SUMS before unpacking anything, and needs no administrator rights. The zip
# holds the launcher, the orchestrator, the dashboard and the Node.js runtime it runs on. Local
# models need Ollama, which the dashboard links to (you install it yourself).
#
#   $env:PETAWORK_VERSION = '0.2.0'     install that version instead of the latest
#   $env:PETAWORK_INSTALL_DIR           where releases are unpacked (default ~\.venom; they go in releases\)
#   $env:PETAWORK_DAEMON_NO_START = '1' install only
#   $env:PETAWORK_DAEMON_NO_OPEN = '1'  start it, but don't open a browser
# Each also works under its older VENOM_ name; the PETAWORK_ one wins when both are set.
#
# It adds a Start Menu shortcut, Petawork Daemon, and petawork-daemon.cmd and venom-daemon.cmd in
# <install dir>\bin (on your user PATH). The daemon keeps its data in %LOCALAPPDATA%\Venom.
#
# Windows support is beta: stopping the daemon ends it at once (running mesh jobs are cut).

function Install-PetaworkDaemon {
	$ErrorActionPreference = 'Stop'
	$ProgressPreference = 'SilentlyContinue'
	$releases = 'https://github.com/elishahbiz/venom-releases/releases'
	try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

	# PETAWORK_X is the new spelling of each VENOM_X; it wins when both are set.
	function Get-Setting([string]$name) {
		$v = [Environment]::GetEnvironmentVariable("PETAWORK_$name")
		if ($v) { return $v }
		return [Environment]::GetEnvironmentVariable("VENOM_$name")
	}

	$arch = $env:PROCESSOR_ARCHITECTURE
	if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
	if ($arch -ne 'AMD64' -and $arch -ne 'ARM64') { throw "petawork-daemon install: no daemon build for $arch Windows; there is a build for x64" }
	if ($arch -eq 'ARM64') { Write-Host 'petawork-daemon: Windows on ARM runs the x64 build under emulation.' }

	$installDir = Get-Setting 'INSTALL_DIR'
	if (-not $installDir) { $installDir = Join-Path $HOME '.venom' }
	$wantVersion = Get-Setting 'VERSION'
	if ($wantVersion) {
		$want = $wantVersion -replace '^v', ''
		if ($want -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$') { throw "petawork-daemon install: PETAWORK_VERSION '$wantVersion' is not a version like 0.2.0" }
		$base = "$releases/download/v$want"
	} else {
		$base = "$releases/latest/download"
	}

	$tmp = Join-Path ([IO.Path]::GetTempPath()) ("petawork-daemon-install-" + [Guid]::NewGuid().ToString('N'))
	New-Item -ItemType Directory -Path $tmp | Out-Null
	try {
		Write-Host 'petawork-daemon: finding the release for windows-x64'
		$sumsFile = Join-Path $tmp 'SHA256SUMS'
		Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile $sumsFile
		# Releases since the rename ship petawork-daemon-<v>-windows-x64.zip; older ones venom-daemon-….
		$re = '^([0-9a-f]{64})  ((petawork|venom)-daemon-([0-9][0-9A-Za-z.-]*)-windows-x64\.zip)$'
		$lines = @(Get-Content $sumsFile | Where-Object { $_ -match $re })
		$line = $lines | Where-Object { $_ -match '  petawork-daemon-' } | Select-Object -First 1
		if (-not $line) { $line = $lines | Select-Object -First 1 }
		if (-not $line) { throw 'petawork-daemon install: the release has no daemon archive for windows-x64' }
		$null = $line -match $re
		$sum = $Matches[1]; $asset = $Matches[2]; $version = $Matches[4]
		$name = $asset -replace '\.zip$', ''

		Write-Host "petawork-daemon: downloading $asset"
		$zip = Join-Path $tmp $asset
		Invoke-WebRequest -UseBasicParsing -Uri "$releases/download/v$version/$asset" -OutFile $zip
		$got = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
		if ($got -ne $sum) { throw "petawork-daemon install: checksum mismatch for $asset (SHA256 $got, SHA256SUMS says $sum); nothing was installed" }
		Write-Host "petawork-daemon: SHA256 verified ($sum)"

		$unpack = Join-Path $tmp 'unpack'
		Expand-Archive -LiteralPath $zip -DestinationPath $unpack
		# The tree: petawork-daemon\ (bin\petawork-daemon.exe, with venom-daemon.exe beside it) since the
		# rename, venom-daemon\ (bin\venom-daemon.exe) before it.
		$tree = $null; $exeName = $null
		foreach ($top in @('petawork-daemon', 'venom-daemon')) {
			foreach ($e in @('petawork-daemon.exe', 'venom-daemon.exe')) {
				if (-not $tree -and (Test-Path -LiteralPath (Join-Path $unpack "$top\bin\$e"))) { $tree = $top; $exeName = $e }
			}
		}
		if (-not $tree) { throw "petawork-daemon install: $asset does not hold petawork-daemon\bin\petawork-daemon.exe" }

		$relDir = Join-Path $installDir 'releases'
		$binDir = Join-Path $installDir 'bin'
		New-Item -ItemType Directory -Force -Path $relDir, $binDir | Out-Null
		$shimPath = Join-Path $binDir 'petawork-daemon.cmd'
		$oldShimPath = Join-Path $binDir 'venom-daemon.cmd'
		# A running daemon (an older version, under either name) stops first.
		if (Test-Path -LiteralPath $shimPath) { & $shimPath stop *> $null }
		elseif (Test-Path -LiteralPath $oldShimPath) { & $oldShimPath stop *> $null }
		$dest = Join-Path $relDir $name
		if (Test-Path -LiteralPath $dest) { Remove-Item -Recurse -Force -LiteralPath $dest }
		Move-Item -LiteralPath (Join-Path $unpack $tree) -Destination $dest
		Get-ChildItem -LiteralPath $relDir -Directory | Where-Object {
			($_.Name -like 'petawork-daemon-*' -or $_.Name -like 'venom-daemon-*') -and
			$_.FullName -ne $dest -and (Test-Path -LiteralPath (Join-Path $_.FullName '.venom-daemon-home'))
		} | ForEach-Object { Remove-Item -Recurse -Force -LiteralPath $_.FullName -ErrorAction SilentlyContinue }

		$daemon = Join-Path $dest "bin\$exeName"
		# petawork-daemon.cmd is the command; venom-daemon.cmd the same one under its old name.
		$shim = "@echo off`r`n`"$daemon`" %*`r`nexit /b %ERRORLEVEL%`r`n"
		foreach ($p in @($shimPath, $oldShimPath)) { [IO.File]::WriteAllText($p, $shim, (New-Object Text.ASCIIEncoding)) }
		$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
		$parts = @(); if ($userPath) { $parts = $userPath -split ';' | Where-Object { $_ } }
		if ($parts -notcontains $binDir) {
			[Environment]::SetEnvironmentVariable('Path', (($parts + $binDir) -join ';'), 'User')
			Write-Host "petawork-daemon: added $binDir to your user PATH (new terminals pick it up)"
		}

		$installed = & $daemon version
		if ($LASTEXITCODE -ne 0) { throw "petawork-daemon install: the installed petawork-daemon did not run: $installed" }
		& $daemon shortcut
		if ((& $daemon autostart status) -match 'true') { & $daemon autostart on *> $null }
		Write-Host ''
		Write-Host "Petawork daemon $installed installed: $shimPath -> $dest (venom-daemon.cmd works too)"
		Write-Host 'Launch it any time from the Start Menu: Petawork Daemon.'
		Write-Host 'Windows support is beta: stopping the daemon ends it at once (running mesh jobs are cut).'

		if ((Get-Setting 'DAEMON_NO_START') -eq '1') { Write-Host "Start it with: petawork-daemon"; return }
		Write-Host ''
		if ((Get-Setting 'DAEMON_NO_OPEN') -eq '1') { & $daemon start --no-open } else { & $daemon start }
		if ($LASTEXITCODE -ne 0) { throw 'petawork-daemon install: the daemon did not start; see petawork-daemon logs' }
		Write-Host ''
		Write-Host 'Next, in the dashboard: install Ollama if it asks, then Connect to Petawork Cloud with a join token'
		Write-Host 'from https://cloud.petawork.ai (Daemons, Connect a daemon). Docs: https://cloud.petawork.ai/daemon'
	} finally {
		Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
	}
}

# The installer's old name, kept so scripts that call Install-VenomDaemon still work.
function Install-VenomDaemon { Install-PetaworkDaemon @args }

Install-PetaworkDaemon
