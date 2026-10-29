# Requires Windows PowerShell 5.1 or PowerShell 7 on Windows.
param([string]$Version)

function Get-ScanRelease {
	param($Manifest, [string]$RequestedVersion)

	if ($Manifest.schemaVersion -ne 1) { throw 'Unsupported or missing release manifest schema.' }
	$selectedVersion = if ($RequestedVersion) { $RequestedVersion } else { $Manifest.stable }
	if ($selectedVersion -cnotmatch '^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
		throw 'The requested release must be a stable version such as v2.1.0.'
	}
	$matches = @($Manifest.releases | Where-Object { $_.version -ceq $selectedVersion })
	if ($matches.Count -ne 1) { throw "Release '$selectedVersion' is missing or duplicated in the manifest." }
	$release = $matches[0]
	$expectedUrl = "https://github.com/printmaster-org/scans/releases/download/$selectedVersion/scans.ps1"
	if ($release.url -cne $expectedUrl -or $release.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
		throw "Release '$selectedVersion' has an invalid download URL or SHA-256."
	}
	return $release
}

function Invoke-ScanRelease {
	param([string]$RequestedVersion)

	if ($PSVersionTable.PSVersion -lt [version]'5.1' -or $env:OS -ne 'Windows_NT') {
		throw 'Scans requires Windows and Windows PowerShell 5.1 or PowerShell 7.'
	}
	[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
	$manifest = Invoke-RestMethod -Uri 'https://scans.printmaster.work/releases.json' -TimeoutSec 30 -ErrorAction Stop
	$release = Get-ScanRelease -Manifest $manifest -RequestedVersion $RequestedVersion
	$downloadDirectory = Join-Path ([IO.Path]::GetTempPath()) ("printmaster-scans-" + [guid]::NewGuid().ToString('N'))
	$downloadPath = Join-Path $downloadDirectory 'scans.ps1'
	[IO.Directory]::CreateDirectory($downloadDirectory) | Out-Null
	try {
		Invoke-WebRequest -Uri $release.url -OutFile $downloadPath -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
		$actualHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256 -ErrorAction Stop).Hash
		if ($actualHash -ine $release.sha256) {
			throw "SHA-256 verification failed for $($release.version). Nothing was executed. Try again or contact the maintainer."
		}
		Start-ScanScript -Path $downloadPath -Sha256 $release.sha256 -ReleaseVersion $release.version | Out-Null
	}
	finally {
		if (Test-Path -LiteralPath $downloadPath) { Remove-Item -LiteralPath $downloadPath -Force -ErrorAction Stop }
		[IO.Directory]::Delete($downloadDirectory)
	}
}

function New-ScanLaunchCommand {
	<#
	.SYNOPSIS
	Builds the child PowerShell command that re-verifies and runs the downloaded utility.
	.DESCRIPTION
	The child reads the file once, hashes those exact bytes, and executes the same
	in-memory text. Nothing re-reads the file after the check, so swapping it in %TEMP%
	between the loader's verification and UAC approval cannot inject elevated code.
	Running from memory also avoids depending on the machine's execution policy.
	#>
	param([string]$Path, [string]$Sha256, [switch]$Elevated)
	$verifyFailedExitCode = Get-ScanVerifyFailedExitCode
	$quotedPath = "'" + $Path.Replace("'", "''") + "'"
	$elevatedArgument = if ($Elevated) { ' -Elevated' } else { '' }
	$command = @"
`$ErrorActionPreference = 'Stop'
try {
	`$bytes = [IO.File]::ReadAllBytes($quotedPath)
	`$sha = [Security.Cryptography.SHA256]::Create()
	`$hash = [BitConverter]::ToString(`$sha.ComputeHash(`$bytes)).Replace('-', '')
	if (`$hash -ine '$Sha256') { [Console]::Error.WriteLine('Scans SHA-256 re-check failed; nothing was executed.'); exit $verifyFailedExitCode }
	`$text = [Text.UTF8Encoding]::new(`$false).GetString(`$bytes).TrimStart([char]0xFEFF)
	& ([scriptblock]::Create(`$text))$elevatedArgument
	exit 0
}
catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 1 }
"@
	return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
}

function Get-ScanVerifyFailedExitCode {
	# Reserved for the child's in-memory SHA-256 re-check; the utility itself exits 0 or 1.
	return 86
}

function Test-ScanAdministrator {
	$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
	return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-ScanUacCanceled {
	param([Exception]$Exception)
	for ($e = $Exception; $e; $e = $e.InnerException) {
		# 1223 is Win32 ERROR_CANCELLED: the user declined the UAC consent prompt.
		if ($e -is [ComponentModel.Win32Exception] -and $e.NativeErrorCode -eq 1223) { return $true }
	}
	return $false
}

function Start-ScanElevatedProcess {
	param([string]$FilePath, [string]$EncodedCommand)
	# Start-Process discards the Win32Exception (including ERROR_CANCELLED).
	# Use the process API so cancellation remains distinguishable from launch failures.
	$process = New-Object System.Diagnostics.Process
	try {
		$process.StartInfo = [Diagnostics.ProcessStartInfo]::new()
		$process.StartInfo.FileName = $FilePath
		$process.StartInfo.Arguments = "-NoProfile -STA -EncodedCommand $EncodedCommand"
		$process.StartInfo.UseShellExecute = $true
		$process.StartInfo.Verb = 'runas'
		[void]$process.Start()
		# Keep the verified temporary file until the elevated utility has closed.
		$process.WaitForExit()
		return $process.ExitCode
	}
	finally {
		$process.Dispose()
	}
}

function Start-ScanScript {
	<#
	.SYNOPSIS
	Runs the verified utility, requesting UAC elevation when the session is not elevated.
	.OUTPUTS
	$true when setup ran, $false when the user canceled the UAC prompt.
	#>
	param([string]$Path, [string]$Sha256, [string]$ReleaseVersion)
	$hostExecutable = Join-Path $PSHOME $(if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh.exe' } else { 'powershell.exe' })

	if (Test-ScanAdministrator) {
		Write-Host "Starting PrintMaster Scans $ReleaseVersion (SHA-256 verified)."
		$encoded = New-ScanLaunchCommand -Path $Path -Sha256 $Sha256
		& $hostExecutable -NoProfile -STA -EncodedCommand $encoded
		$exitCode = $LASTEXITCODE
	}
	else {
		Write-Host "Requesting administrator approval to run PrintMaster Scans $ReleaseVersion (SHA-256 verified)."
		$encoded = New-ScanLaunchCommand -Path $Path -Sha256 $Sha256 -Elevated
		try {
			$exitCode = Start-ScanElevatedProcess -FilePath $hostExecutable -EncodedCommand $encoded
		}
		catch {
			if (Test-ScanUacCanceled $_.Exception) {
				Write-Host 'Administrator approval was declined. Scans did not run and nothing was changed.'
				return $false
			}
			throw
		}
	}

	if ($exitCode -eq (Get-ScanVerifyFailedExitCode)) {
		throw 'The downloaded file changed after verification, so it was not executed. Run the Scans command again.'
	}
	if ($exitCode -ne 0) { throw "Scans exited with code $exitCode. Review the setup errors before trying again." }
	return $true
}

try {
	Invoke-ScanRelease -RequestedVersion $Version
}
catch {
	Write-Error "Scans could not start: $($_.Exception.Message)" -ErrorAction Stop
}
