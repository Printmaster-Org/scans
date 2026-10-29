$sourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\scans.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }

# Load only function definitions, without elevation, UI, or machine configuration.
foreach ($definition in $ast.FindAll({
		param($node)
		$node -is [System.Management.Automation.Language.FunctionDefinitionAst]
	}, $true)) {
	. ([scriptblock]::Create($definition.Extent.Text))
}
$remediationAssignment = $ast.Find({
	param($node)
	$node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$script:Remediation'
}, $true)
. ([scriptblock]::Create($remediationAssignment.Extent.Text))

# Test-local command signatures keep the mocks usable without LocalAccounts or WMIC installed.
function Get-LocalUser {
	[CmdletBinding()]
	param([string]$Name)
	throw 'Unmocked Get-LocalUser'
}
function Get-LocalGroupMember {
	[CmdletBinding()]
	param($SID)
	throw 'Unmocked Get-LocalGroupMember'
}
function New-LocalUser {
	[CmdletBinding()]
	param([string]$Name, [securestring]$Password, [string]$Description, [switch]$AccountNeverExpires,
		[switch]$PasswordNeverExpires, [switch]$UserMayNotChangePassword, [string]$FullName)
	throw 'Unmocked New-LocalUser'
}
function Set-LocalUser {
	[CmdletBinding()]
	param([string]$Name, [securestring]$Password, [string]$Description)
	throw 'Unmocked Set-LocalUser'
}
function wmic { throw 'Unmocked wmic' }
function net {
	param([string]$Operation, [string]$Name, [string]$Password)
	throw 'Unmocked net'
}
function Get-CimInstance {
	[CmdletBinding()]
	param([string]$ClassName)
	throw 'Unmocked Get-CimInstance'
}
function Get-SmbShare {
	[CmdletBinding()]
	param()
	throw 'Unmocked Get-SmbShare'
}
function New-SmbShare {
	[CmdletBinding()]
	param($Name, $Path, $FullAccess, $ChangeAccess)
	throw 'Unmocked New-SmbShare'
}
function Grant-SmbShareAccess {
	[CmdletBinding()]
	param($Name, $AccountName, $AccessRight, [switch]$Force)
	throw 'Unmocked Grant-SmbShareAccess'
}
function Get-SmbShareAccess {
	[CmdletBinding()]
	param($Name)
	throw 'Unmocked Get-SmbShareAccess'
}
function Revoke-SmbShareAccess {
	[CmdletBinding()]
	param($Name, $AccountName, [switch]$Force)
	throw 'Unmocked Revoke-SmbShareAccess'
}
function Get-NetConnectionProfile { throw 'Unmocked Get-NetConnectionProfile' }
function Set-NetConnectionProfile {
	[CmdletBinding()]
	param($NetworkCategory, [Parameter(ValueFromPipeline)]$InputObject)
	throw 'Unmocked Set-NetConnectionProfile'
}
function Get-NetFirewallRule {
	param($DisplayGroup, $Direction)
	throw 'Unmocked Get-NetFirewallRule'
}
function Set-NetFirewallRule {
	[CmdletBinding()]
	param($DisplayGroup, $Direction, $Enabled, $Profile)
	throw 'Unmocked Set-NetFirewallRule'
}
function netsh {
	param($Operation, $Area)
	throw 'Unmocked netsh'
}

function Initialize-TestTheme {
	foreach ($name in @('thBg', 'thBgAlt', 'thFg', 'thFgEm', 'thFgStrong', 'thAccent', 'thAccentHi', 'thBorder', 'thBtnText', 'thSuccess', 'thWarn', 'thDanger')) {
		Set-Variable -Name $name -Value '#002b36' -Scope Script
	}
	$themeAssignment = $ast.Find({
		param($node)
		$node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
		$node.Left.Extent.Text -eq '$script:themeResources'
	}, $true)
	. ([scriptblock]::Create($themeAssignment.Extent.Text))
}

Describe 'Scan account password errors' {
	BeforeEach {
		$script:hasLocalAccounts = $true
		Mock Get-LocalUser { $null }
		Mock Get-LocalGroupMember { @() }
		Mock New-LocalUser { }
		Mock Set-LocalUser { }
		Mock Confirm-ExistingScanAccountUpdate { $true }
		Mock Get-ItemProperty { throw 'Account hiding must not run after account setup fails' }
	}

	It 'catches a non-terminating New-LocalUser password rejection and stops hiding' {
		Mock New-LocalUser { Write-Error 'Password rejected' -ErrorId InvalidPassword }
		$result = @(Initialize-ScanUser -Username scans -Password (ConvertTo-ScanSecureString 'weak') -HideFromLogin $true)
		$result.Count | Should Be 1
		$result[0].Status | Should Be 'Failed'
		$result[0].ErrorId | Should Match 'InvalidPassword'
		$result[0].AccountSetupFailed | Should Be $true
		Assert-MockCalled Get-ItemProperty -Times 0 -Exactly -Scope It
	}

	It 'catches a non-terminating Set-LocalUser password rejection' {
		Mock Get-LocalUser { [pscustomobject]@{ Name = 'scans' } }
		Mock Set-LocalUser { Write-Error 'Password rejected' -ErrorId InvalidPassword }
		$result = @(Initialize-ScanUser -Username scans -Password (ConvertTo-ScanSecureString 'weak'))
		$result[0].Status | Should Be 'Failed'
		$result[0].ErrorId | Should Match 'InvalidPassword'
	}

	It 'preserves successful account creation and updates' {
		$result = @(Initialize-ScanUser -Username scans -Password (ConvertTo-ScanSecureString 'Valid-Example123!'))
		$result[0].Status | Should Be 'Success'
		Assert-MockCalled New-LocalUser -Times 1 -Exactly -Scope It
		Mock Get-LocalUser { [pscustomobject]@{ Name = 'scans' } }
		$result = @(Initialize-ScanUser -Username scans -Password (ConvertTo-ScanSecureString 'Valid-Example123!'))
		$result[0].Status | Should Be 'Success'
		Assert-MockCalled Set-LocalUser -Times 1 -Exactly -Scope It
	}

	It 'requires confirmation before changing an existing account password' {
		Mock Get-LocalUser { [pscustomobject]@{ Name = 'scans' } }
		$result = @(Initialize-ScanUser -Username scans -Password (ConvertTo-ScanSecureString 'Valid-Example123!'))
		$result[0].Status | Should Be 'Success'
		Assert-MockCalled Confirm-ExistingScanAccountUpdate -Times 1 -Exactly -Scope It -ParameterFilter { $Username -eq 'scans' }
		Assert-MockCalled Set-LocalUser -Times 1 -Exactly -Scope It
	}

	It 'cancels before changing an existing account when confirmation is declined' {
		Mock Get-LocalUser { [pscustomobject]@{ Name = 'scans' } }
		Mock Confirm-ExistingScanAccountUpdate { $false }
		$result = @(Initialize-ScanUser -Username scans -Password (ConvertTo-ScanSecureString 'Valid-Example123!') -HideFromLogin $true)
		$result[0].SetupCanceled | Should Be $true
		$result[0].Message | Should Match 'no account changes were made'
		Assert-MockCalled Set-LocalUser -Times 0 -Exactly -Scope It
		Assert-MockCalled Get-ItemProperty -Times 0 -Exactly -Scope It
	}

	It 'refuses to change an existing local Administrators account' {
		Mock Get-LocalUser { [pscustomobject]@{ Name = 'scans' } }
		Mock Get-LocalGroupMember { @([pscustomobject]@{ Name = 'COMPUTER\scans' }) }
		$result = @(Initialize-ScanUser -Username scans -Password (ConvertTo-ScanSecureString 'Valid-Example123!'))
		$result[0].Status | Should Be 'Failed'
		$result[0].ErrorId | Should Match 'ProtectedAccount'
		$result[0].Error | Should Match 'local Administrators group'
		Assert-MockCalled Confirm-ExistingScanAccountUpdate -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-LocalUser -Times 0 -Exactly -Scope It
	}

	It 'fails closed when administrator membership cannot be checked' {
		Mock Get-LocalUser { [pscustomobject]@{ Name = 'scans' } }
		Mock Get-LocalGroupMember { throw 'Membership lookup failed' }
		$result = @(Initialize-ScanUser -Username scans -Password (ConvertTo-ScanSecureString 'Valid-Example123!'))
		$result[0].Status | Should Be 'Failed'
		$result[0].Error | Should Match 'Membership lookup failed'
		Assert-MockCalled Confirm-ExistingScanAccountUpdate -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-LocalUser -Times 0 -Exactly -Scope It
	}

	It 'passes the production description within the 48-character account limit on creation and update' {
		$assignment = $ast.Find({
			param($node)
			$node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
			($node.Left.Extent.Text -replace '^\[string\]', '') -eq '$script:description'
		}, $true)
		. ([scriptblock]::Create($assignment.Extent.Text))
		$description | Should Not BeNullOrEmpty
		($description.Length -le 48) | Should Be $true
		$description | Should Be 'Scanning provided by PrintMaster'
		$result = @(Initialize-ScanUser -Username scans -Password (ConvertTo-ScanSecureString 'Valid-Example123!') -Description $description)
		$result[0].Status | Should Be 'Success'
		Assert-MockCalled New-LocalUser -Times 1 -Exactly -Scope It -ParameterFilter {
			$Description -eq 'Scanning provided by PrintMaster' -and $Description.Length -le 48
		}
		Mock Get-LocalUser { [pscustomobject]@{ Name = 'scans' } }
		$result = @(Initialize-ScanUser -Username scans -Password (ConvertTo-ScanSecureString 'Valid-Example123!') -Description $description)
		$result[0].Status | Should Be 'Success'
		Assert-MockCalled Set-LocalUser -Times 1 -Exactly -Scope It -ParameterFilter {
			$Description -eq 'Scanning provided by PrintMaster' -and $Description.Length -le 48
		}
	}

	It 'preserves non-password failures without classifying them as password errors' {
		Mock New-LocalUser { Write-Error 'Access is denied' -ErrorId AccessDenied }
		$result = @(Initialize-ScanUser -Username scans -Password (ConvertTo-ScanSecureString 'example'))
		$result[0].Status | Should Be 'Failed'
		$result[0].ErrorId | Should Not Match 'InvalidPassword'
		Get-ErrorRemediation $result[0].Error | Should Be $script:Remediation.AccessDenied
	}

	It 'recognizes password error identifiers even when the message is generic' {
		Get-ErrorRemediation 'InvalidPassword,Microsoft.PowerShell.Commands.NewLocalUserCommand' | Should Be $script:Remediation.PasswordPolicy
		Get-ErrorRemediation 'System error 2245 has occurred.' | Should Be $script:Remediation.PasswordPolicy
		Get-ErrorRemediation 'Unrelated failure' | Should BeNullOrEmpty
	}

	It 'handles legacy system error 2245 for new and existing accounts without relying on English text' {
		$script:hasLocalAccounts = $false
		Mock net {
			if (-not $Password) {
				$global:LASTEXITCODE = $script:lookupExitCode
			}
			else {
				$global:LASTEXITCODE = 2
				'2245'
			}
		}
		Mock wmic { }
		foreach ($lookupExitCode in @(2, 0)) {
			$script:lookupExitCode = $lookupExitCode
			$result = @(Initialize-ScanUser -Username scans -Password (ConvertTo-ScanSecureString 'weak') -HideFromLogin $true)
			$result.Count | Should Be 1
			$result[0].Status | Should Be 'Failed'
			$result[0].ErrorId | Should Match 'InvalidPassword'
			$result[0].Error | Should Match '2245'
		}
		Assert-MockCalled wmic -Times 0 -Exactly -Scope It
		Assert-MockCalled Get-ItemProperty -Times 0 -Exactly -Scope It
	}

	It 'reports other legacy command failures rather than claiming success' {
		$script:hasLocalAccounts = $false
		Mock net { $global:LASTEXITCODE = 2; 'System error 5 has occurred. Access is denied.' }
		$result = @(Initialize-ScanUser -Username scans -Password (ConvertTo-ScanSecureString 'example'))
		$result[0].Status | Should Be 'Failed'
		$result[0].ErrorId | Should Not Match 'InvalidPassword'
		$result[0].Error | Should Match 'Access is denied'
	}

	It 'preserves legacy account creation and update success' {
		$script:hasLocalAccounts = $false
		Mock net {
			if (-not $Password) { $global:LASTEXITCODE = $script:lookupExitCode }
			else { $global:LASTEXITCODE = 0 }
		}
		Mock wmic { }
		foreach ($lookupExitCode in @(2, 0)) {
			$script:lookupExitCode = $lookupExitCode
			$result = @(Initialize-ScanUser -Username scans -Password (ConvertTo-ScanSecureString 'Valid-Example123!'))
			$result[0].Status | Should Be 'Success'
		}
		Assert-MockCalled wmic -Times 1 -Exactly -Scope It
	}
}

function New-TestSetupConfiguration {
	param([hashtable]$Override = @{})
	$configuration = [pscustomobject]@{
		Username = 'scans'; FolderPath = 'C:\scans'; ShareName = 'scans'; Description = 'Scanning provided by PrintMaster'
		CreateUser = $true; HideUser = $true; CreateFolder = $true; SetPermissions = $true; SetShare = $true
		CreateShortcut = $true; CheckNetwork = $true; EnableDiscovery = $false
	}
	foreach ($key in $Override.Keys) { $configuration.$key = $Override[$key] }
	return $configuration
}

function Get-TestPlainText([securestring]$Secret) {
	return Use-ScanPlainText -Secret $Secret -ScriptBlock { param($plain) $plain }
}

Describe 'Setup engine' {
	$WarningPreference = 'SilentlyContinue'
	BeforeEach {
		$script:iconPath = 'C:\ProgramData\scans.ico'
		$script:testControls = @{
			progressBar = [pscustomobject]@{ Value = 0; Maximum = 0 }
			lstDetails  = [pscustomobject]@{ Items = New-Object System.Collections.ArrayList }
		}
		$script:progressWindow = New-Object PSObject
		$script:progressWindow | Add-Member ScriptMethod FindName { param($name) $script:testControls[$name] }
		$script:inputPassword = ConvertTo-ScanSecureString 'Original-Pass7-Phrase'
		Mock Set-ProgressBar { }
		Mock Get-ScanComputerIdentity { [pscustomobject]@{ ComputerName = 'PC1'; HostName = 'PC1'; Fqdn = $null; DomainJoined = $false } }
		Mock Initialize-ScanUser { $script:testUserResults }
		Mock Request-ScanReplacementPassword { throw 'Unexpected password prompt' }
		Mock Initialize-ScanFolder { @{ Status = 'Success'; Message = 'Folder ready'; Error = $null } }
		Mock Initialize-ScanShare { @{ Status = 'Success'; Message = 'Share ready'; Error = $null } }
		Mock Initialize-DesktopShortcut { @{ Status = 'Success'; Message = 'Shortcut ready'; Error = $null } }
		Mock Set-NetworkConfiguration { @{ Status = 'Success'; Message = 'Network ready'; Error = $null } }
		$script:testUserResults = @{ Status = 'Success'; Message = 'Account ready'; Error = $null }
	}

	It 'passes the Network Discovery opt-in to network setup' {
		Invoke-ScanSetup -Configuration (New-TestSetupConfiguration) -Password $script:inputPassword | Out-Null
		Assert-MockCalled Set-NetworkConfiguration -Times 1 -Exactly -Scope It -ParameterFilter { -not $EnableDiscovery }
		Invoke-ScanSetup -Configuration (New-TestSetupConfiguration @{ EnableDiscovery = $true }) -Password $script:inputPassword | Out-Null
		Assert-MockCalled Set-NetworkConfiguration -Times 1 -Exactly -Scope It -ParameterFilter { $EnableDiscovery }
	}

	It 'runs every selected step, records results, and returns the password it set' {
		$result = Invoke-ScanSetup -Configuration (New-TestSetupConfiguration) -Password $script:inputPassword
		Assert-MockCalled Initialize-ScanUser -Times 1 -Exactly -Scope It -ParameterFilter { $HideFromLogin -and $Username -eq 'scans' -and $Password -eq $script:inputPassword }
		Assert-MockCalled Initialize-ScanFolder -Times 1 -Exactly -Scope It -ParameterFilter { $SetPermissions }
		Assert-MockCalled Initialize-ScanShare -Times 1 -Exactly -Scope It
		Assert-MockCalled Initialize-DesktopShortcut -Times 1 -Exactly -Scope It -ParameterFilter { $IconPath -eq 'C:\ProgramData\scans.ico' }
		$result.Canceled | Should Be $false
		$result.AccountConfigured | Should Be $true
		$result.ShareConfigured | Should Be $true
		[object]::ReferenceEquals($result.Password, $script:inputPassword) | Should Be $true
		@($result.Steps).Count | Should Be 5
		@($result.Steps | Where-Object Status -ne 'Success').Count | Should Be 0
		($result.Steps | ForEach-Object Category) -join ',' | Should Be 'Account,Folder,Share,Shortcut,Network'
		$script:testControls.progressBar.Value | Should Be $script:progressMax
		(Get-ScanSetupOutcome -Result $result).State | Should Be 'Ready'
	}

	It 'skips permissions and shares and reports not ready after account failure' {
		$script:testUserResults = @{ Status = 'Failed'; Message = 'Account failed'; Error = 'Rejected'; AccountSetupFailed = $true }
		$result = Invoke-ScanSetup -Configuration (New-TestSetupConfiguration) -Password $script:inputPassword
		Assert-MockCalled Initialize-ScanFolder -Times 1 -Exactly -Scope It -ParameterFilter { -not $SetPermissions }
		Assert-MockCalled Initialize-ScanShare -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-NetworkConfiguration -Times 1 -Exactly -Scope It
		$result.AccountConfigured | Should Be $false
		$result.Password | Should BeNullOrEmpty
		$outcome = Get-ScanSetupOutcome -Result $result
		$outcome.State | Should Be 'NotReady'
		$outcome.FailedPrerequisites | Should Be @('scan account')
		$outcome.Message | Should Not Match 'Ready for scanning'
	}

	It 'also gates dependent steps when the hide-user option triggers account setup' {
		$script:testUserResults = @{ Status = 'Failed'; Error = 'Rejected'; AccountSetupFailed = $true }
		$result = Invoke-ScanSetup -Configuration (New-TestSetupConfiguration @{ CreateUser = $false }) -Password $script:inputPassword
		Assert-MockCalled Initialize-ScanUser -Times 1 -Exactly -Scope It
		Assert-MockCalled Initialize-ScanShare -Times 0 -Exactly -Scope It
		$result.AccountStepRan | Should Be $true
		$result.Password | Should BeNullOrEmpty
	}

	It 'retains a replacement share name and keeps running independent steps after a share failure' {
		Mock Initialize-ScanShare { @{ Status = 'Success'; Message = 'Shared'; ShareName = 'printer-scans'; Error = $null } }
		$result = Invoke-ScanSetup -Configuration (New-TestSetupConfiguration) -Password $script:inputPassword
		$result.ShareName | Should Be 'printer-scans'
		$result.ShareConfigured | Should Be $true
		Mock Initialize-ScanShare { @{ Status = 'Failed'; Message = 'Share failed'; Error = 'Share review canceled' } }
		$result = Invoke-ScanSetup -Configuration (New-TestSetupConfiguration) -Password $script:inputPassword
		$result.ShareConfigured | Should Be $false
		$result.ShareName | Should Be 'scans'
		Assert-MockCalled Initialize-DesktopShortcut -Times 2 -Exactly -Scope It
		(Get-ScanSetupOutcome -Result $result).FailedPrerequisites | Should Be @('SMB share')
	}

	It 'does not configure a share when folder permissions fail or their review is canceled' {
		Mock Initialize-ScanFolder { @{ Status = 'Failed'; Message = 'Folder failed'; Error = 'Folder review canceled'; FolderSetupFailed = $true } }
		$result = Invoke-ScanSetup -Configuration (New-TestSetupConfiguration) -Password $script:inputPassword
		Assert-MockCalled Initialize-ScanShare -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-NetworkConfiguration -Times 1 -Exactly -Scope It
		(Get-ScanSetupOutcome -Result $result).State | Should Be 'NotReady'
	}

	It 'pauses for replacement passwords until accepted, then resumes all selected steps' {
		$script:attempts = 0
		$script:seenPasswords = @()
		Mock Initialize-ScanUser {
			$script:attempts++
			# Read now: superseded replacements are disposed once the next one arrives.
			$script:seenPasswords += Get-TestPlainText $Password
			if ($script:attempts -lt 3) {
				@{ Status = 'Failed'; Error = 'Policy rejected'; ErrorId = 'InvalidPassword,NewLocalUserCommand'; AccountSetupFailed = $true }
			}
			else { @{ Status = 'Success'; Message = 'Account configured'; Error = $null } }
		}
		Mock Request-ScanReplacementPassword {
			Assert-MockCalled Initialize-ScanFolder -Times 0 -Exactly -Scope It
			Assert-MockCalled Set-NetworkConfiguration -Times 0 -Exactly -Scope It
			ConvertTo-ScanSecureString "Replacement$script:attempts!"
		}
		$result = Invoke-ScanSetup -Configuration (New-TestSetupConfiguration) -Password $script:inputPassword
		Assert-MockCalled Initialize-ScanUser -Times 3 -Exactly -Scope It -ParameterFilter { $HideFromLogin }
		$script:seenPasswords -join ',' | Should Be 'Original-Pass7-Phrase,Replacement1!,Replacement2!'
		Assert-MockCalled Request-ScanReplacementPassword -Times 2 -Exactly -Scope It -ParameterFilter { $ErrorText -eq 'Policy rejected' }
		Assert-MockCalled Initialize-ScanShare -Times 1 -Exactly -Scope It
		Get-TestPlainText $result.Password | Should Be 'Replacement2!'
		(Get-TestPlainText $script:inputPassword) | Should Be 'Original-Pass7-Phrase'
		@($result.Steps | Where-Object Status -eq 'Failed').Count | Should Be 0
	}

	It 'stops all remaining steps if password correction is canceled' {
		$script:testUserResults = @{ Status = 'Failed'; Error = '2245'; ErrorId = 'InvalidPassword'; AccountSetupFailed = $true }
		Mock Request-ScanReplacementPassword { $null }
		$result = Invoke-ScanSetup -Configuration (New-TestSetupConfiguration) -Password $script:inputPassword
		Assert-MockCalled Initialize-ScanUser -Times 1 -Exactly -Scope It
		Assert-MockCalled Initialize-ScanFolder -Times 0 -Exactly -Scope It
		Assert-MockCalled Initialize-ScanShare -Times 0 -Exactly -Scope It
		Assert-MockCalled Initialize-DesktopShortcut -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-NetworkConfiguration -Times 0 -Exactly -Scope It
		$result.Canceled | Should Be $true
		$result.Password | Should BeNullOrEmpty
		@($result.Steps).Count | Should Be 1
		$result.Steps[0].Status | Should Be 'Skipped'
		$outcome = Get-ScanSetupOutcome -Result $result
		$outcome.State | Should Be 'Canceled'
		$outcome.Message | Should Match 'password correction was canceled'
	}

	It 'stops all remaining steps when the existing account change is declined' {
		$script:testUserResults = @{ Status = 'Skipped'; Message = 'Canceled before changing existing account'; Error = $null; AccountSetupFailed = $true; SetupCanceled = $true }
		$result = Invoke-ScanSetup -Configuration (New-TestSetupConfiguration) -Password $script:inputPassword
		Assert-MockCalled Initialize-ScanFolder -Times 0 -Exactly -Scope It
		$result.Canceled | Should Be $true
		$result.Steps[0].Message | Should Match 'Canceled before changing'
	}

	It 'also offers correction for legacy error 2245 when only hiding is selected' {
		Mock Initialize-ScanUser {
			if ((Get-TestPlainText $Password) -ne 'LegacyReplacement!') {
				@{ Status = 'Failed'; Error = 'System error 2245'; AccountSetupFailed = $true }
			}
			else { @{ Status = 'Success'; Error = $null } }
		}
		Mock Request-ScanReplacementPassword { ConvertTo-ScanSecureString 'LegacyReplacement!' }
		$result = Invoke-ScanSetup -Configuration (New-TestSetupConfiguration @{ CreateUser = $false }) -Password $script:inputPassword
		Assert-MockCalled Request-ScanReplacementPassword -Times 1 -Exactly -Scope It
		Assert-MockCalled Initialize-ScanUser -Times 2 -Exactly -Scope It -ParameterFilter { $HideFromLogin }
		Assert-MockCalled Initialize-ScanShare -Times 1 -Exactly -Scope It
		Get-TestPlainText $result.Password | Should Be 'LegacyReplacement!'
	}

	It 'does not block shares when only hiding the successfully configured account fails' {
		$script:testUserResults = @(@{ Status = 'Success'; Error = $null }, @{ Status = 'Failed'; Message = 'Hide failed'; Error = 'Registry denied' })
		$result = Invoke-ScanSetup -Configuration (New-TestSetupConfiguration) -Password $script:inputPassword
		Assert-MockCalled Initialize-ScanShare -Times 1 -Exactly -Scope It
		$result.Password | Should Not BeNullOrEmpty
	}

	It 'respects disabled steps and reports no password when the account step did not run' {
		$configuration = New-TestSetupConfiguration @{ CreateUser = $false; HideUser = $false; CreateFolder = $false; SetShare = $false; CreateShortcut = $false; CheckNetwork = $false }
		$result = Invoke-ScanSetup -Configuration $configuration -Password $script:inputPassword
		Assert-MockCalled Initialize-ScanUser -Times 0 -Exactly -Scope It
		Assert-MockCalled Initialize-ScanFolder -Times 0 -Exactly -Scope It
		Assert-MockCalled Initialize-ScanShare -Times 0 -Exactly -Scope It
		Assert-MockCalled Initialize-DesktopShortcut -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-NetworkConfiguration -Times 0 -Exactly -Scope It
		$result.AccountStepRan | Should Be $false
		$result.Password | Should BeNullOrEmpty
		(Get-ScanSetupOutcome -Result $result).State | Should Be 'Ready'
	}

	It 'counts progress the same way the steps run' {
		Get-ScanProgressMaximum -Configuration (New-TestSetupConfiguration) | Should Be 12
		Get-ScanProgressMaximum -Configuration (New-TestSetupConfiguration @{ CreateUser = $false; HideUser = $false; CheckNetwork = $false }) | Should Be 6
	}
}

Describe 'Setup step recording' {
	$WarningPreference = 'SilentlyContinue'
	BeforeEach {
		$script:hasErrors = $false
		$script:stepResults = $null
		Mock Set-ProgressBar { }
		Mock Show-ErrorPopup { throw 'Setup must not open error popups' }
	}

	It 'records successful and skipped steps without errors' {
		Show-StepResult @{ Message = 'Created folder'; Error = $null } -Category 'Folder'
		Show-StepResult @{ Status = 'Skipped'; Message = 'Skipped share'; Error = $null } -Category 'Share'
		$script:hasErrors | Should Be $false
		($script:stepResults | ForEach-Object Status) -join ',' | Should Be 'Success,Skipped'
		$script:stepResults[0].Category | Should Be 'Folder'
	}

	It 'records password-specific remediation inline' {
		Show-StepResult @{ Message = 'Account failed'; Error = 'Rejected'; ErrorId = 'InvalidPassword,NewLocalUserCommand' } -Category 'Account'
		$script:hasErrors | Should Be $true
		$script:stepResults[0].Status | Should Be 'Failed'
		$script:stepResults[0].Tip | Should Be $script:Remediation.PasswordPolicy
		Assert-MockCalled Set-ProgressBar -Times 1 -Exactly -Scope It -ParameterFilter { $text -match 'Tip: ' }
	}

	It 'records matching remediation for each other known setup error' {
		foreach ($message in @('The trust relationship failed', 'Access is denied', 'UnauthorizedAccess', 'share is in use', 'File is being used')) {
			Show-StepResult @{ Message = 'Step failed'; Error = $message }
		}
		$tips = @($script:stepResults | ForEach-Object Tip)
		$tips[0] | Should Be $script:Remediation.TrustRelation
		$tips[1] | Should Be $script:Remediation.AccessDenied
		$tips[2] | Should Be $script:Remediation.AccessDenied
		$tips[3] | Should Be $script:Remediation.ShareInUse
		$tips[4] | Should Be $script:Remediation.ShareInUse
	}

	It 'preserves unexpected error details with generic actionable guidance' {
		Show-StepResult @{ Message = 'Shortcut failed'; Error = 'COM error 123' } -Category 'Shortcut'
		$script:stepResults[0].Error | Should Be 'COM error 123'
		$script:stepResults[0].Tip | Should Match 'administrator'
		Assert-MockCalled Set-ProgressBar -Times 1 -Exactly -Scope It -ParameterFilter { $text -match 'Error: COM error 123' }
	}

	It 'files optional results such as Network Discovery under Optional' {
		Show-StepResult @{ Status = 'Failed'; Message = 'Discovery failed'; Error = 'Denied'; Optional = $true } -Category 'Network'
		$script:stepResults[0].Category | Should Be 'Optional'
	}
}

Describe 'Setup outcome and connection details' {
	function New-TestStep([string]$Category, [string]$Status) {
		[pscustomobject]@{ Category = $Category; Status = $Status; Message = "$Category $Status"; Error = $(if ($Status -eq 'Failed') { 'boom' }); Tip = $null }
	}
	$identity = [pscustomobject]@{ ComputerName = 'FRONTDESK'; HostName = 'FRONTDESK'; Fqdn = 'FRONTDESK.office.example'; DomainJoined = $false }

	It 'reports optional-only failures as ready with a warning, never as not ready' {
		$result = [pscustomobject]@{ Canceled = $false; Steps = @((New-TestStep Account Success), (New-TestStep Shortcut Failed), (New-TestStep Optional Failed)) }
		$outcome = Get-ScanSetupOutcome -Result $result
		$outcome.State | Should Be 'Warning'
		$outcome.FailedPrerequisites.Count | Should Be 0
	}

	It 'lists every failed prerequisite once and never claims readiness on partial failure' {
		$result = [pscustomobject]@{ Canceled = $false; Steps = @((New-TestStep Account Success), (New-TestStep Network Failed), (New-TestStep Network Failed), (New-TestStep Share Failed), (New-TestStep Shortcut Failed)) }
		$outcome = Get-ScanSetupOutcome -Result $result
		$outcome.State | Should Be 'NotReady'
		$outcome.FailedPrerequisites | Should Be @('network and firewall settings', 'SMB share')
		$outcome.Title | Should Be 'Not ready for scanning'
	}

	It 'lists usable IPv4 addresses per adapter and skips loopback, link-local, IPv6, and down adapters' {
		function New-TestNic([string]$Name, [string]$Status, [string]$Type, [string[]]$Addresses) {
			$nic = [pscustomobject]@{ Name = $Name; OperationalStatus = $Status; NetworkInterfaceType = $Type; Addresses = $Addresses }
			$nic | Add-Member ScriptMethod GetIPProperties {
				[pscustomobject]@{ UnicastAddresses = @($this.Addresses | ForEach-Object { [pscustomobject]@{ Address = [System.Net.IPAddress]::Parse($_) } }) }
			}
			return $nic
		}
		$nics = @(
			(New-TestNic 'Ethernet' 'Up' 'Ethernet' @('192.168.1.20', 'fe80::1', '169.254.3.4')),
			(New-TestNic 'Wi-Fi' 'Up' 'Wireless80211' @('10.0.0.7')),
			(New-TestNic 'Loopback' 'Up' 'Loopback' @('127.0.0.1')),
			(New-TestNic 'Old' 'Down' 'Ethernet' @('172.16.0.2'))
		)
		$addresses = @(Get-ScanNetworkAddresses -Interfaces $nics)
		$addresses.Count | Should Be 2
		($addresses | ForEach-Object { "$($_.Adapter)=$($_.Address)" }) -join ';' | Should Be 'Ethernet=192.168.1.20;Wi-Fi=10.0.0.7'
		@(Get-ScanNetworkAddresses -Interfaces @()).Count | Should Be 0
	}

	It 'builds copyable connection details for every address without inventing values' {
		$addresses = @([pscustomobject]@{ Adapter = 'Ethernet'; Address = '192.168.1.20' }, [pscustomobject]@{ Adapter = 'Wi-Fi'; Address = '10.0.0.7' })
		$rows = @(Get-ScanConnectionDetails -Identity $identity -Username 'scans' -ShareName 'scans' -ShareConfigured $true -FolderPath 'C:\scans' -Addresses $addresses -PasswordAvailable $true)
		$byKey = @{}; foreach ($row in $rows) { $byKey[$row.Key] = $row }
		$byKey.username.Value | Should Be 'scans'
		$byKey.qualifiedUsername.Value | Should Be 'FRONTDESK\scans'
		$byKey.password.Sensitive | Should Be $true
		$byKey.password.Value | Should BeNullOrEmpty
		$byKey.password.CanCopy | Should Be $true
		$byKey.domain.Value | Should Be 'FRONTDESK'
		$byKey.hostName.Value | Should Be 'FRONTDESK'
		$byKey.fqdn.Value | Should Be 'FRONTDESK.office.example'
		$byKey.shareName.Value | Should Be 'scans'
		$byKey.pathHost.Value | Should Be '\\FRONTDESK\scans'
		$byKey.pathIp0.Value | Should Be '\\192.168.1.20\scans'
		$byKey.pathIp1.Value | Should Be '\\10.0.0.7\scans'
		$byKey.ip0.Value | Should Be '192.168.1.20'
		$byKey.ip1.Hint | Should Match 'DHCP'
		$byKey.port.Value | Should Be '445'
		$byKey.localFolder.Value | Should Be 'C:\scans'
		$byKey.localFolder.Value | Should Not Be $byKey.pathHost.Value
		@($rows | Where-Object { $_.CanCopy -and -not $_.Sensitive -and [string]::IsNullOrEmpty($_.Value) }).Count | Should Be 0
	}

	It 'says when the password, FQDN, share, or addresses are unknown and disables their copy' {
		$noSuffix = [pscustomobject]@{ ComputerName = 'PC2'; HostName = 'PC2'; Fqdn = $null; DomainJoined = $false }
		$rows = @(Get-ScanConnectionDetails -Identity $noSuffix -Username 'scans' -ShareName 'scans' -ShareConfigured $false -FolderPath 'C:\scans' -Addresses @() -PasswordAvailable $false)
		$byKey = @{}; foreach ($row in $rows) { $byKey[$row.Key] = $row }
		$byKey.password.Value | Should Match 'Unknown'
		$byKey.password.CanCopy | Should Be $false
		$byKey.fqdn.CanCopy | Should Be $false
		$byKey.shareName.Value | Should Match 'Not configured'
		$byKey.shareName.CanCopy | Should Be $false
		$byKey.ContainsKey('pathHost') | Should Be $false
		$byKey.ip.Value | Should Match 'No usable IPv4'
		$byKey.ip.CanCopy | Should Be $false
	}

	It 'builds a summary that never includes the password' {
		$secretValue = 'Sentinel-Secret-4815'
		$rows = @(Get-ScanConnectionDetails -Identity $identity -Username 'scans' -ShareName 'scans' -ShareConfigured $true -FolderPath 'C:\scans' -PasswordAvailable $true)
		$outcome = [pscustomobject]@{ Title = 'Ready for scanning'; Message = 'All good' }
		$summary = Get-ScanSetupSummaryText -Outcome $outcome -Details $rows -Steps @((New-TestStep Account Success), (New-TestStep Share Failed))
		$summary | Should Match 'Password: \(not included\)'
		$summary | Should Match '\[OK\] Account Success'
		$summary | Should Match '\[FAILED\] Share Failed'
		$summary | Should Not Match $secretValue
	}
}

Describe 'Wizard configuration and review' {
	It 'reports each invalid Configure input' {
		$problems = @(Test-ScanWizardConfiguration -Configuration (New-TestSetupConfiguration @{ Username = ''; FolderPath = 'scans'; ShareName = '' }) -PasswordPresent $false)
		$problems.Count | Should Be 4
		$problems[0] | Should Match 'account name'
		$problems[1] | Should Match 'password'
		$problems[2] | Should Match 'local folder'
		$problems[3] | Should Match 'share name'
		@(Test-ScanWizardConfiguration -Configuration (New-TestSetupConfiguration @{ Username = 'a@b' }) -PasswordPresent $true)[0] | Should Match 'cannot contain'
		@(Test-ScanWizardConfiguration -Configuration (New-TestSetupConfiguration @{ Username = 'x' * 21 }) -PasswordPresent $true)[0] | Should Match '20 characters'
		@(Test-ScanWizardConfiguration -Configuration (New-TestSetupConfiguration @{ ShareName = 'bad/share' }) -PasswordPresent $true)[0] | Should Match 'Share names'
	}

	It 'accepts valid input and only requires what the selected steps use' {
		@(Test-ScanWizardConfiguration -Configuration (New-TestSetupConfiguration) -PasswordPresent $true).Count | Should Be 0
		$networkOnly = New-TestSetupConfiguration @{ CreateUser = $false; HideUser = $false; CreateFolder = $false; SetShare = $false; CreateShortcut = $false; FolderPath = ''; ShareName = '' }
		@(Test-ScanWizardConfiguration -Configuration $networkOnly -PasswordPresent $false).Count | Should Be 0
	}

	It 'gates Apply on existing, administrator, and unverifiable accounts' {
		$configuration = New-TestSetupConfiguration
		$new = [pscustomobject]@{ Exists = $false; IsAdministrator = $false; CheckFailed = $false }
		$existing = [pscustomobject]@{ Exists = $true; IsAdministrator = $false; CheckFailed = $false }
		$admin = [pscustomobject]@{ Exists = $true; IsAdministrator = $true; CheckFailed = $false }
		$failed = [pscustomobject]@{ Exists = $false; IsAdministrator = $false; CheckFailed = $true; Message = 'lookup failed' }
		(Get-ScanReviewGate -Configuration $configuration -AccountState $new).CanApply | Should Be $true
		$gate = Get-ScanReviewGate -Configuration $configuration -AccountState $existing -Confirmed $false
		$gate.CanApply | Should Be $false
		$gate.NeedsConfirmation | Should Be $true
		$gate.Tone | Should Be 'Warn'
		(Get-ScanReviewGate -Configuration $configuration -AccountState $existing -Confirmed $true).CanApply | Should Be $true
		$gate = Get-ScanReviewGate -Configuration $configuration -AccountState $admin -Confirmed $true
		$gate.CanApply | Should Be $false
		$gate.Notice | Should Match 'Administrators'
		$gate = Get-ScanReviewGate -Configuration $configuration -AccountState $failed
		$gate.CanApply | Should Be $false
		$gate.Notice | Should Match 'lookup failed'
		(Get-ScanReviewGate -Configuration (New-TestSetupConfiguration @{ CreateUser = $false; HideUser = $false }) -AccountState $admin).CanApply | Should Be $true
	}

	It 'summarizes the planned changes without exposing the password' {
		$rows = @(Get-ScanSetupReview -Configuration (New-TestSetupConfiguration) -AccountState ([pscustomobject]@{ Exists = $true }) -ComputerName 'PC1')
		($rows | Where-Object Label -eq 'Scan account').Value | Should Match 'Update existing'
		($rows | Where-Object Label -eq 'Scan account').Tone | Should Be 'Warn'
		($rows | Where-Object Label -eq 'SMB share').Value | Should Be 'Share as \\PC1\scans'
		($rows | Where-Object Label -eq 'Password').Value | Should Match 'hidden'
		$rows = @(Get-ScanSetupReview -Configuration (New-TestSetupConfiguration @{ CheckNetwork = $false; CreateShortcut = $false }) -ComputerName 'PC1')
		($rows | Where-Object Label -eq 'Network').Tone | Should Be 'Muted'
		($rows | Where-Object Label -eq 'Desktop shortcut').Value | Should Be 'Not added'
	}
}

Describe 'Secret handling' {
	$WarningPreference = 'SilentlyContinue'
	BeforeEach {
		$script:hasLocalAccounts = $true
		$script:sentinel = 'Sentinel-Secret-4815'
		$script:sentinelSecret = ConvertTo-ScanSecureString $script:sentinel
		Mock Get-LocalUser { $null }
		Mock Get-LocalGroupMember { @() }
		Mock Confirm-ExistingScanAccountUpdate { $true }
	}

	It 'round-trips plaintext only inside Use-ScanPlainText and makes secrets read-only' {
		$script:sentinelSecret.IsReadOnly() | Should Be $true
		Get-TestPlainText $script:sentinelSecret | Should Be $script:sentinel
		Use-ScanPlainText -Secret $null -ScriptBlock { param($plain) "[$plain]" } | Should Be '[]'
		Test-ScanSecretPresent -Secret $script:sentinelSecret | Should Be $true
		Test-ScanSecretPresent -Secret (ConvertTo-ScanSecureString '') | Should Be $false
		Test-ScanSecretPresent -Secret $null | Should Be $false
	}

	It 'redacts the password from text' {
		Remove-ScanSecretText -Text "net user scans $($script:sentinel) failed" -Secret $script:sentinelSecret | Should Be 'net user scans [redacted] failed'
		Remove-ScanSecretText -Text 'nothing here' -Secret $null | Should Be 'nothing here'
	}

	It 'passes a SecureString to the LocalAccounts cmdlets' {
		Mock New-LocalUser { }
		Initialize-ScanUser -Username scans -Password $script:sentinelSecret | Out-Null
		Assert-MockCalled New-LocalUser -Times 1 -Exactly -Scope It -ParameterFilter { $Password -is [securestring] -and (Get-TestPlainText $Password) -eq $script:sentinel }
	}

	It 'keeps the password out of errors and verbose output when a cmdlet echoes it' {
		Mock New-LocalUser { throw "Rejected password $($script:sentinel)" }
		$VerbosePreference = 'Continue'
		$output = Initialize-ScanUser -Username scans -Password $script:sentinelSecret 4>&1 3>&1
		($output | Out-String) | Should Not Match $script:sentinel
		$failure = @($output | Where-Object { $_ -is [hashtable] })[0]
		$failure.Error | Should Match '\[redacted\]'
	}

	It 'keeps the password out of legacy NET.EXE failures while still using it' {
		$script:hasLocalAccounts = $false
		Mock net {
			if (-not $Password) { $global:LASTEXITCODE = 2; return }
			$script:netPassword = $Password
			$global:LASTEXITCODE = 2
			"The command failed for $Password"
		}
		$result = @(Initialize-ScanUser -Username scans -Password $script:sentinelSecret)
		$script:netPassword | Should Be $script:sentinel
		$result[0].Error | Should Not Match $script:sentinel
		$result[0].Error | Should Match '\[redacted\]'
	}

	It 'marks sensitive clipboard data as excluded from history, cloud sync, and monitors' {
		Add-Type -AssemblyName System.Windows.Forms
		$data = New-ScanClipboardData -Text 'value' -Sensitive
		$data.GetData([System.Windows.Forms.DataFormats]::UnicodeText) | Should Be 'value'
		[BitConverter]::ToInt32($data.GetData('CanIncludeInClipboardHistory').ToArray(), 0) | Should Be 0
		[BitConverter]::ToInt32($data.GetData('CanUploadToCloudClipboard').ToArray(), 0) | Should Be 0
		$data.GetDataPresent('ExcludeClipboardContentFromMonitorProcessing') | Should Be $true
		(New-ScanClipboardData -Text 'value').GetDataPresent('CanIncludeInClipboardHistory') | Should Be $false
	}

	It 'clears the copied password on close only if the clipboard still holds it' {
		Mock Set-ScanClipboardText { }
		Mock Clear-ScanClipboard { }
		Copy-ScanSecret -Secret $script:sentinelSecret
		Assert-MockCalled Set-ScanClipboardText -Times 1 -Exactly -Scope It -ParameterFilter { $Sensitive -and $Text -eq $script:sentinel }
		Mock Get-ScanClipboardText { 'something the user copied later' }
		Clear-ScanCopiedSecret
		Assert-MockCalled Clear-ScanClipboard -Times 0 -Exactly -Scope It
		$script:copiedSecret | Should BeNullOrEmpty

		Copy-ScanSecret -Secret $script:sentinelSecret
		Mock Get-ScanClipboardText { $script:sentinel }
		Clear-ScanCopiedSecret
		Assert-MockCalled Clear-ScanClipboard -Times 1 -Exactly -Scope It
		Get-TestPlainText $script:sentinelSecret | Should Be $script:sentinel
	}

	It 'refuses to copy an empty password' {
		{ Copy-ScanSecret -Secret $null } | Should Throw 'no password'
	}
}

Describe 'Account visibility' {
	BeforeEach {
		$script:hasLocalAccounts = $true
		Mock Get-LocalUser { [pscustomobject]@{ Name = 'scans' } }
		Mock Get-LocalGroupMember { @() }
		Mock Set-LocalUser { }
		Mock Confirm-ExistingScanAccountUpdate { $true }
		Mock Get-ItemProperty { $null }
		Mock Test-Path { $false }
		Mock New-Item { }
		Mock New-ItemProperty { }
	}

	It 'creates the hiding key and value on non-domain computers' {
		$results = @(Initialize-ScanUser -Username scans -Password (ConvertTo-ScanSecureString 'Example123!') -HideFromLogin $true)
		$results.Count | Should Be 2
		$results[1].Status | Should Be 'Success'
		Assert-MockCalled New-ItemProperty -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'scans' -and $Value -eq 0 }
	}

	It 'does not modify visibility on a domain-joined computer' {
		$results = @(Initialize-ScanUser -Username scans -Password (ConvertTo-ScanSecureString 'Example123!') -HideFromLogin $true -DomainJoined $true)
		$results[1].Status | Should Be 'Skipped'
		Assert-MockCalled New-ItemProperty -Times 0 -Exactly -Scope It
	}

	It 'leaves an already hidden account unchanged' {
		Mock Get-ItemProperty { [pscustomobject]@{ scans = 0 } }
		$results = @(Initialize-ScanUser -Username scans -Password (ConvertTo-ScanSecureString 'Example123!') -HideFromLogin $true)
		$results[1].Message | Should Match 'already hidden'
		Assert-MockCalled New-ItemProperty -Times 0 -Exactly -Scope It
	}

	It 'reports non-terminating registry failures separately from account setup' {
		Mock New-ItemProperty { Write-Error 'Access is denied' }
		$results = @(Initialize-ScanUser -Username scans -Password (ConvertTo-ScanSecureString 'Example123!') -HideFromLogin $true)
		$results[1].Status | Should Be 'Failed'
		$results[1].AccountSetupFailed | Should BeNullOrEmpty
	}
}

Describe 'Scan folder setup' {
	BeforeEach {
		$script:scanSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001')
		$script:recipientSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1002')
		$script:folderAcl = [System.Security.AccessControl.DirectorySecurity]::new()
		$script:resolveRecipientFails = $false
		Mock Test-Path { $false }
		Mock New-Item { }
		Mock Get-Acl { $script:folderAcl }
		Mock Set-Acl { }
		Mock Get-ScanDesktopUser { 'DOMAIN\recipient' }
		Mock Resolve-ScanAccountSid {
			if ($AccountName -eq 'DOMAIN\recipient') {
				if ($script:resolveRecipientFails) { throw 'Account not found' }
				$script:recipientSid
			}
			else { $script:scanSid }
		}
		Mock Show-ScanFolderAccessDialog {
			@{ Recipient = 'DOMAIN\recipient'; AllowEveryoneModify = $false; RemoveRules = @() }
		}
	}

	It 'creates a missing folder without touching disabled permissions' {
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans')
		$results[0].Status | Should Be 'Success'
		Assert-MockCalled New-Item -Times 1 -Exactly -Scope It -ParameterFilter { $Path -eq 'C:\scans' -and $ItemType -eq 'Directory' }
		Assert-MockCalled Get-Acl -Times 0 -Exactly -Scope It
		Assert-MockCalled Get-ScanDesktopUser -Times 0 -Exactly -Scope It
	}

	It 'defaults folder review to the user of the UI session rather than the elevated identity' {
		Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -SetPermissions $true | Out-Null
		Assert-MockCalled Get-ScanDesktopUser -Times 1 -Exactly -Scope It
		Assert-MockCalled Show-ScanFolderAccessDialog -Times 1 -Exactly -Scope It -ParameterFilter {
			$DesktopUser -eq 'DOMAIN\recipient'
		}
	}

	It 'passes an empty detected user to review without substituting the elevated account' {
		Mock Get-ScanDesktopUser { $null }
		Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -SetPermissions $true | Out-Null
		Assert-MockCalled Show-ScanFolderAccessDialog -Times 1 -Exactly -Scope It -ParameterFilter {
			[string]::IsNullOrWhiteSpace($DesktopUser)
		}
	}

	It 'reports desktop-session lookup failure before modifying the folder' {
		Mock Get-ScanDesktopUser { throw 'Session identity lookup failed' }
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -SetPermissions $true)
		$results[0].Error | Should Match 'Session identity lookup failed'
		$results[0].FolderSetupFailed | Should Be $true
		Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-Acl -Times 0 -Exactly -Scope It
	}

	It 'does not recreate an existing folder' {
		Mock Test-Path { $true }
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans')
		$results[0].Message | Should Match 'already exists'
		Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
	}

	It 'stops before ACL work when folder creation fails' {
		Mock New-Item { Write-Error 'Access is denied' }
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans' -SetPermissions $true)
		$results.Count | Should Be 1
		$results[0].Status | Should Be 'Failed'
		$results[0].FolderSetupFailed | Should Be $true
		Assert-MockCalled Set-Acl -Times 0 -Exactly -Scope It
	}

	It 'reports non-terminating ACL read failures' {
		Mock Test-Path { $true }
		Mock Get-Acl { Write-Error 'Access is denied' }
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans' -SetPermissions $true)
		$results[0].Status | Should Be 'Failed'
		$results[0].FolderSetupFailed | Should Be $true
		Assert-MockCalled Set-Acl -Times 0 -Exactly -Scope It
	}

	It 'writes a protected new-folder ACL with the exact restricted rights on domain and non-domain PCs' {
		foreach ($joined in @($false, $true)) {
			$results = @(Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -DesktopUser 'DOMAIN\recipient' -SetPermissions $true -DomainJoined $joined)
			$results[-1].Status | Should Be 'Success'
			Assert-MockCalled Set-Acl -Scope It -ParameterFilter {
				$rules = @($AclObject.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
				$scanRule = @($rules | Where-Object { $_.IdentityReference.Value -eq $script:scanSid.Value })
				$AclObject.AreAccessRulesProtected -and $rules.Count -eq 4 -and $scanRule.Count -eq 1 -and
				[int]$scanRule[0].FileSystemRights -eq 1048583 -and
				$scanRule[0].InheritanceFlags -eq 'ContainerInherit,ObjectInherit'
			}
		}
		Assert-MockCalled Set-Acl -Times 2 -Exactly -Scope It
	}

	It 'cancels before creating a folder or writing any ACL' {
		Mock Show-ScanFolderAccessDialog { $null }
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -SetPermissions $true)
		$results[0].FolderSetupFailed | Should Be $true
		$results[0].Error | Should Match 'canceled'
		Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-Acl -Times 0 -Exactly -Scope It
	}

	It 'does not modify an existing folder when its review is canceled' {
		Mock Test-Path { $true }
		Mock Show-ScanFolderAccessDialog { $null }
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -SetPermissions $true)
		$results[0].FolderSetupFailed | Should Be $true
		Assert-MockCalled Set-Acl -Times 0 -Exactly -Scope It
		$script:folderAcl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]).Count | Should Be 0
	}

	It 'fails explicitly before creation if a receiving user cannot be resolved' {
		$script:resolveRecipientFails = $true
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -SetPermissions $true)
		$results[0].Error | Should Match 'Account not found'
		Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-Acl -Times 0 -Exactly -Scope It
	}

	It 'reports ACL write failure and never claims permissions were applied' {
		Mock Set-Acl { Write-Error 'Access is denied' }
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -SetPermissions $true)
		$results[-1].FolderSetupFailed | Should Be $true
		@($results | Where-Object { $_.Message -like 'Folder permissions applied*' }).Count | Should Be 0
	}

	It 'logs retained inherited and custom access on an existing folder' {
		Mock Test-Path { $true }
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -SetPermissions $true)
		($results | Where-Object { $_.Error } | ForEach-Object { $_.Error } | Out-String).Trim() | Should BeNullOrEmpty
		$results[-1].Status | Should Be 'Warning'
		$results[-1].Message | Should Match 'not a guarantee'
		$script:folderAcl.AreAccessRulesProtected | Should Be $false
	}
}

Describe 'Folder ACL policy' {
	BeforeEach {
		$script:scanSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001')
		$script:recipientSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1002')
		$script:folderAcl = [System.Security.AccessControl.DirectorySecurity]::new()
	}

	It 'grants Full Control to the recipient, local Administrators, and SYSTEM using SIDs' {
		Set-ScanFolderAccessRules -Acl $script:folderAcl -ScanSid $script:scanSid -RecipientSid $script:recipientSid -NewFolder $true
		$rules = @($script:folderAcl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))
		foreach ($sid in @($script:recipientSid.Value, 'S-1-5-32-544', 'S-1-5-18')) {
			$rule = @($rules | Where-Object { $_.IdentityReference.Value -eq $sid })
			$rule.Count | Should Be 1
			$rule[0].FileSystemRights | Should Be ([System.Security.AccessControl.FileSystemRights]::FullControl)
			$rule[0].InheritanceFlags | Should Be ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit')
			$rule[0].PropagationFlags | Should Be 'None'
		}
	}

	It 'never gives the scan account the receiving users Full Control grant' {
		{ Set-ScanFolderAccessRules -Acl $script:folderAcl -ScanSid $script:scanSid -RecipientSid $script:scanSid -NewFolder $true } | Should Throw 'must differ'
		$script:folderAcl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]).Count | Should Be 0
	}

	It 'grants Everyone Modify only after an explicit opt-in' {
		Set-ScanFolderAccessRules -Acl $script:folderAcl -ScanSid $script:scanSid -RecipientSid $script:recipientSid -NewFolder $true -AllowEveryoneModify $true
		$rules = @($script:folderAcl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))
		$rule = @($rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-1-0' })
		$rule.Count | Should Be 1
		[int]$rule[0].FileSystemRights | Should Be 1245631
	}

	It 'identifies only exact explicit legacy-shaped rules as cleanup candidates' {
		$script:folderAcl.SetSecurityDescriptorSddlForm('D:AI(A;OICI;0x1301bf;;;WD)(A;OICI;FA;;;S-1-5-21-1-2-3-1001)(A;OICI;0x1301bf;;;S-1-5-21-1-2-3-513)(A;;0x1301bf;;;WD)(A;OICI;FR;;;S-1-5-21-1-2-3-1003)(A;OICIID;0x1301bf;;;WD)')
		$candidates = @(Get-ScanFolderCleanupRules -Acl $script:folderAcl -ScanSid $script:scanSid)
		$candidates.Count | Should Be 3
		@($candidates | Where-Object { $_.IsInherited }).Count | Should Be 0
	}

	It 'preserves all existing access including inherited broad grants unless explicitly selected' {
		$script:folderAcl.SetSecurityDescriptorSddlForm('D:AI(A;OICI;0x1301bf;;;WD)(A;OICI;FA;;;S-1-5-21-1-2-3-1001)(A;OICI;FR;;;S-1-5-21-1-2-3-1003)(A;OICIID;0x1301bf;;;WD)')
		Set-ScanFolderAccessRules -Acl $script:folderAcl -ScanSid $script:scanSid -RecipientSid $script:recipientSid
		$rules = @($script:folderAcl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
		$script:folderAcl.AreAccessRulesProtected | Should Be $false
		@($rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-1-0' }).Count | Should Be 2
		@($rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-21-1-2-3-1003' }).Count | Should Be 1
		@($rules | Where-Object { $_.IdentityReference.Value -eq $script:scanSid.Value })[0].FileSystemRights | Should Be ([System.Security.AccessControl.FileSystemRights]::FullControl)
	}

	It 'removes only approved exact entries and preserves custom and inherited ACEs' {
		$script:folderAcl.SetSecurityDescriptorSddlForm('D:AI(A;OICI;0x1301bf;;;WD)(A;OICI;FA;;;S-1-5-21-1-2-3-1001)(A;OICI;FR;;;S-1-5-21-1-2-3-1003)(A;OICIID;0x1301bf;;;WD)')
		$candidates = @(Get-ScanFolderCleanupRules -Acl $script:folderAcl -ScanSid $script:scanSid)
		Set-ScanFolderAccessRules -Acl $script:folderAcl -ScanSid $script:scanSid -RecipientSid $script:recipientSid -RemoveRules $candidates
		$rules = @($script:folderAcl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
		$everyone = @($rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-1-0' })
		$everyone.Count | Should Be 1
		$everyone[0].IsInherited | Should Be $true
		$scanRule = @($rules | Where-Object { $_.IdentityReference.Value -eq $script:scanSid.Value })
		[int]$scanRule[0].FileSystemRights | Should Be 1048583
		@($rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-21-1-2-3-1003' }).Count | Should Be 1
	}

	It 'retains a protected existing folder instead of enabling inheritance' {
		$script:folderAcl.SetAccessRuleProtection($true, $false)
		Set-ScanFolderAccessRules -Acl $script:folderAcl -ScanSid $script:scanSid -RecipientSid $script:recipientSid
		$script:folderAcl.AreAccessRulesProtected | Should Be $true
	}

	It 'rejects a blank receiving account rather than selecting the elevated account' {
		{ Resolve-ScanAccountSid '' } | Should Throw 'Choose the receiving Windows user'
	}
}

Describe 'SMB share setup' {
	BeforeEach {
		$script:hasSmbShareCmdlets = $true
		$script:shareScanSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001')
		$script:shareAccess = @([pscustomobject]@{ AccountName = 'Everyone'; AccessControlType = 'Allow'; AccessRight = 'Full' })
		Mock Test-Path { $true }
		Mock Resolve-ScanAccountSid {
			if ($AccountName -eq 'Everyone') { return [System.Security.Principal.SecurityIdentifier]::new('S-1-1-0') }
			return $script:shareScanSid
		}
		Mock Resolve-ScanPrincipalDisplay { "TEST\$($Sid.Value)" }
		Mock Get-SmbShare { $null }
		Mock Get-SmbShareAccess { $script:shareAccess }
		Mock New-SmbShare { }
		Mock Grant-SmbShareAccess { }
		Mock Revoke-SmbShareAccess { }
		Mock Show-ScanShareAccessDialog { @{ RemoveAccounts = @() } }
		Mock Show-ScanShareConflictDialog { $null }
		Mock Get-CimInstance { @() }
		Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 0 } }
		Mock net { throw 'Share setup must not call net share.' }
	}

	It 'creates a share with Change only for the explicitly local scan account' {
		$result = Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans
		$result.Status | Should Be 'Success'
		$result.ShareName | Should Be 'scans'
		Assert-MockCalled New-SmbShare -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'scans' -and $ChangeAccess -eq "$env:COMPUTERNAME\scans" -and -not $FullAccess }
		Assert-MockCalled Show-ScanShareAccessDialog -Times 0 -Exactly -Scope It
	}

	It 'matches existing share names and normalized paths case-insensitively' {
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'SCANS'; Path = 'c:\scans\.' } }
		$result = Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans
		$result.Status | Should Be 'Success'
		Assert-MockCalled Show-ScanShareAccessDialog -Times 1 -Exactly -Scope It
		Assert-MockCalled Grant-SmbShareAccess -Times 1 -Exactly -Scope It -ParameterFilter { $AccessRight -eq 'Change' }
		Assert-MockCalled Revoke-SmbShareAccess -Times 0 -Exactly -Scope It
		Assert-MockCalled New-SmbShare -Times 0 -Exactly -Scope It
	}

	It 'does not confuse a partial name with an existing share' {
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'scans-backup' } }
		Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans | Out-Null
		Assert-MockCalled New-SmbShare -Times 1 -Exactly -Scope It
	}

	It 'cancels a path conflict without touching the unrelated share' {
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'scans'; Path = 'D:\other' } }
		$result = Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans
		$result.Status | Should Be 'Failed'
		$result.Error | Should Match 'canceled'
		Assert-MockCalled Show-ScanShareConflictDialog -Times 1 -Exactly -Scope It
		Assert-MockCalled Get-SmbShareAccess -Times 0 -Exactly -Scope It
		Assert-MockCalled Grant-SmbShareAccess -Times 0 -Exactly -Scope It
		Assert-MockCalled New-SmbShare -Times 0 -Exactly -Scope It
	}

	It 'checks a replacement name and reports the name actually created' {
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'scans'; Path = 'D:\other' } }
		Mock Show-ScanShareConflictDialog { 'printer-scans' }
		$result = Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans
		$result.Status | Should Be 'Success'
		$result.ShareName | Should Be 'printer-scans'
		Assert-MockCalled New-SmbShare -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'printer-scans' }
		Assert-MockCalled Grant-SmbShareAccess -Times 0 -Exactly -Scope It
	}

	It 'does not modify an existing share when access review is canceled' {
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'scans'; Path = 'C:\scans' } }
		Mock Show-ScanShareAccessDialog { $null }
		$result = Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans
		$result.Error | Should Match 'canceled'
		Assert-MockCalled Grant-SmbShareAccess -Times 0 -Exactly -Scope It
		Assert-MockCalled Revoke-SmbShareAccess -Times 0 -Exactly -Scope It
	}

	It 'removes only explicitly selected Allow grants and grants scan Change' {
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'scans'; Path = 'C:\scans' } }
		Mock Show-ScanShareAccessDialog { @{ RemoveAccounts = @('Everyone') } }
		$result = Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans
		$result.Status | Should Be 'Success'
		Assert-MockCalled Revoke-SmbShareAccess -Times 1 -Exactly -Scope It -ParameterFilter { $AccountName -eq 'Everyone' }
		Assert-MockCalled Grant-SmbShareAccess -Times 1 -Exactly -Scope It -ParameterFilter { $AccessRight -eq 'Change' }
	}

	It 'preserves existing scan Full unless explicitly selected for reduction' {
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'scans'; Path = 'C:\scans' } }
		$script:shareAccess = @([pscustomobject]@{ AccountName = 'TEST\scan'; AccessControlType = 'Allow'; AccessRight = 'Full' })
		(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Status | Should Be 'Success'
		Assert-MockCalled Grant-SmbShareAccess -Times 0 -Exactly -Scope It
		Mock Show-ScanShareAccessDialog { @{ RemoveAccounts = @('TEST\scan') } }
		(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Status | Should Be 'Success'
		Assert-MockCalled Revoke-SmbShareAccess -Times 1 -Exactly -Scope It -ParameterFilter { $AccountName -eq 'TEST\scan' }
		Assert-MockCalled Grant-SmbShareAccess -Times 1 -Exactly -Scope It -ParameterFilter { $AccessRight -eq 'Change' }
	}

	It 'rejects unreviewed and Deny removal requests' {
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'scans'; Path = 'C:\scans' } }
		$script:shareAccess += [pscustomobject]@{ AccountName = 'TEST\blocked'; AccessControlType = 'Deny'; AccessRight = 'Full' }
		foreach ($name in @('TEST\blocked', 'UNREVIEWED')) {
			$script:removeShareAccount = $name
			Mock Show-ScanShareAccessDialog { @{ RemoveAccounts = @($script:removeShareAccount) } }
			(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Status | Should Be 'Failed'
		}
		Assert-MockCalled Revoke-SmbShareAccess -Times 0 -Exactly -Scope It
		Assert-MockCalled Grant-SmbShareAccess -Times 0 -Exactly -Scope It
	}

	It 'rejects ambiguous duplicate Allow entries for account-wide removal' {
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'scans'; Path = 'C:\scans' } }
		$script:shareAccess += [pscustomobject]@{ AccountName = 'Everyone'; AccessControlType = 'Allow'; AccessRight = 'Read' }
		Mock Show-ScanShareAccessDialog { @{ RemoveAccounts = @('Everyone') } }
		(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Status | Should Be 'Failed'
		Assert-MockCalled Revoke-SmbShareAccess -Times 0 -Exactly -Scope It
	}

	It 'treats SID aliases as one principal when checking removal ambiguity' {
		$access = @(
			[pscustomobject]@{ AccountName = 'TEST\scan'; AccessControlType = 'Allow'; AccessRight = 'Full' }
			[pscustomobject]@{ AccountName = $script:shareScanSid.Value; AccessControlType = 'Allow'; AccessRight = 'Read' }
		)
		$rows = @(Get-ScanShareAccessRows -Access $access -ScanSid $script:shareScanSid)
		@($rows | Where-Object { $_.CanRemove }).Count | Should Be 0
	}

	It 'does not repeat grants when the scan account already has Change' {
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'scans'; Path = 'C:\scans' } }
		$script:shareAccess = @([pscustomobject]@{ AccountName = $script:shareScanSid.Value; AccessControlType = 'Allow'; AccessRight = 'Change' })
		(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Status | Should Be 'Success'
		Assert-MockCalled Grant-SmbShareAccess -Times 0 -Exactly -Scope It
	}

	It 'labels unresolved named principals without confusing them with the scan account' {
		Mock Resolve-ScanAccountSid { throw [System.Security.Principal.IdentityNotMappedException]::new('Unavailable identity') }
		$rows = @(Get-ScanShareAccessRows -Access $script:shareAccess -ScanSid $script:shareScanSid)
		$rows[0].Principal | Should Be 'Unresolved account (Everyone)'
		$rows[0].IsScan | Should Be $false
		$rows[0].Remove | Should Be $false
	}

	It 'fails closed for unreadable and unsupported ACL shapes' {
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'scans'; Path = 'C:\scans' } }
		foreach ($access in @(
			@(),
			@([pscustomobject]@{ AccountName = 'Everyone'; AccessControlType = 'Unknown'; AccessRight = 'Full' })
		)) {
			$script:shareAccess = $access
			(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Status | Should Be 'Failed'
		}
		Assert-MockCalled Show-ScanShareAccessDialog -Times 0 -Exactly -Scope It
	}

	It 'stops when the share path changes during review' {
		$script:shareReviewed = $false
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'scans'; Path = $(if ($script:shareReviewed) { 'D:\other' } else { 'C:\scans' }) } }
		Mock Show-ScanShareAccessDialog { $script:shareReviewed = $true; @{ RemoveAccounts = @('Everyone') } }
		$result = Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans
		$result.Error | Should Match 'changed during review'
		Assert-MockCalled Revoke-SmbShareAccess -Times 0 -Exactly -Scope It
		Assert-MockCalled Grant-SmbShareAccess -Times 0 -Exactly -Scope It
	}

	It 'stops when the ACL changes during review' {
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'scans'; Path = 'C:\scans' } }
		Mock Show-ScanShareAccessDialog {
			$script:shareAccess = @([pscustomobject]@{ AccountName = 'Everyone'; AccessControlType = 'Allow'; AccessRight = 'Read' })
			@{ RemoveAccounts = @('Everyone') }
		}
		$result = Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans
		$result.Error | Should Match 'changed during review'
		Assert-MockCalled Revoke-SmbShareAccess -Times 0 -Exactly -Scope It
	}

	It 'reports partial changes when a later grant fails without claiming rollback' {
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'scans'; Path = 'C:\scans' } }
		Mock Show-ScanShareAccessDialog { @{ RemoveAccounts = @('Everyone') } }
		Mock Grant-SmbShareAccess { Write-Error 'Grant denied' }
		$result = Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans
		$result.Status | Should Be 'Failed'
		$result.Error | Should Match 'Grant denied'
		$result.Error | Should Match 'Partial updates already applied.*Everyone.*No rollback'
	}

	It 'fails closed for missing folders and invalid or special names' {
		foreach ($name in @('', 'scans$', 'bad/name', 'bad*name', ' scans')) {
			(Initialize-ScanShare -ShareName $name -FolderPath 'C:\scans' -ScanUser scans).Status | Should Be 'Failed'
		}
		Mock Test-Path { $false }
		(Initialize-ScanShare -ShareName scans -FolderPath 'C:\missing' -ScanUser scans).Status | Should Be 'Failed'
		Assert-MockCalled New-SmbShare -Times 0 -Exactly -Scope It
	}

	It 'rejects relative and UNC paths instead of guessing equivalence' {
		foreach ($path in @('scans', '\\server\scans', 'C:scans')) {
			{ ConvertTo-ScanSharePath $path } | Should Throw 'absolute local drive path'
		}
	}

	It 'refuses duplicate scoped and special shares' {
		Mock Get-SmbShare { @([pscustomobject]@{ Name = 'scans'; Path = 'C:\scans'; ScopeName = 'A' }, [pscustomobject]@{ Name = 'scans'; Path = 'C:\scans'; ScopeName = 'B' }) }
		(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Error | Should Match 'Multiple scoped'
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'scans'; Path = 'C:\scans'; Special = $true } }
		(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Error | Should Match 'special share'
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'scans'; Path = 'C:\scans'; ScopeName = 'SERVER' } }
		(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Error | Should Match 'is scoped'
		Assert-MockCalled Grant-SmbShareAccess -Times 0 -Exactly -Scope It
	}

	It 'reports share lookup, creation, ACL-read, revoke and permission errors' {
		Mock Get-SmbShare { Write-Error 'Access is denied' }
		(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Status | Should Be 'Failed'
		Mock Get-SmbShare { $null }
		Mock New-SmbShare { Write-Error 'Access is denied' }
		(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Status | Should Be 'Failed'
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'scans'; Path = 'C:\scans' } }
		Mock Get-SmbShareAccess { Write-Error 'ACL read denied' }
		(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Error | Should Match 'ACL read denied'
		Mock Get-SmbShareAccess { $script:shareAccess }
		Mock Show-ScanShareAccessDialog { @{ RemoveAccounts = @('Everyone') } }
		Mock Revoke-SmbShareAccess { Write-Error 'Revoke denied' }
		(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Error | Should Match 'Revoke denied'
		Mock Show-ScanShareAccessDialog { @{ RemoveAccounts = @() } }
		Mock Grant-SmbShareAccess { Write-Error 'Access is denied' }
		(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Status | Should Be 'Failed'
	}

	It 'creates legacy shares through a create-only WMI method with an explicit Change DACL' {
		$script:hasSmbShareCmdlets = $false
		(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Status | Should Be 'Success'
		Assert-MockCalled Invoke-CimMethod -Times 1 -Exactly -Scope It -ParameterFilter {
			$ClassName -eq 'Win32_Share' -and $MethodName -eq 'Create' -and $Arguments.Type -eq 0 -and
			$Arguments.Access.ControlFlags -eq 4 -and $Arguments.Access.DACL.Count -eq 1 -and
			$Arguments.Access.DACL[0].AccessMask -eq 1245631 -and $Arguments.Access.DACL[0].AceType -eq 0 -and
			[System.Security.Principal.SecurityIdentifier]::new([byte[]]$Arguments.Access.DACL[0].Trustee.SID, 0).Value -eq $script:shareScanSid.Value
		}
	}

	It 'refuses legacy existing-share edits without invoking a writer' {
		$script:hasSmbShareCmdlets = $false
		Mock Get-CimInstance { [pscustomobject]@{ Name = 'scans'; Path = 'C:\scans' } }
		(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Error | Should Match 'Without SMB cmdlets'
		Assert-MockCalled Invoke-CimMethod -Times 0 -Exactly -Scope It
		Assert-MockCalled net -Times 0 -Exactly -Scope It
	}

	It 'does not treat a legacy lookup failure as share absence' {
		$script:hasSmbShareCmdlets = $false
		Mock Get-CimInstance { Write-Error 'WMI denied' }
		(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Error | Should Match 'WMI denied'
		Assert-MockCalled Invoke-CimMethod -Times 0 -Exactly -Scope It
	}

	It 'also detects legacy path conflicts before attempting to create anything' {
		$script:hasSmbShareCmdlets = $false
		Mock Get-CimInstance { [pscustomobject]@{ Name = 'scans'; Path = 'D:\other' } }
		(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Error | Should Match 'canceled'
		Assert-MockCalled Show-ScanShareConflictDialog -Times 1 -Exactly -Scope It
		Assert-MockCalled Invoke-CimMethod -Times 0 -Exactly -Scope It
	}

	It 'reports legacy creation return codes and CIM errors' {
		$script:hasSmbShareCmdlets = $false
		Mock Invoke-CimMethod { [pscustomobject]@{ ReturnValue = 22 } }
		(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Error | Should Match 'return code 22'
		Mock Invoke-CimMethod { Write-Error 'Create denied' }
		(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Error | Should Match 'Create denied'
	}
}

Describe 'SMB share review dialogs' {
	BeforeEach {
		Add-Type -AssemblyName PresentationFramework
		Initialize-TestTheme
		$script:progressWindow = $null
		$script:shareDialogAccepted = $true
		$script:inspectShareWindow = { param($window) }
		Mock Set-WindowTheme {
			$window | Add-Member ScriptMethod ShowDialog {
				& $script:inspectShareWindow $this
				return $script:shareDialogAccepted
			} -Force
		}
		$script:shareDialogRows = @(
			[pscustomobject]@{ Principal = 'Everyone'; AccountName = 'Everyone'; Type = 'Allow'; Access = 'Full'; CanRemove = $true; Remove = $false; Icon = [char]0xE73E }
			[pscustomobject]@{ Principal = 'TEST\blocked'; AccountName = 'TEST\blocked'; Type = 'Deny'; Access = 'Full'; CanRemove = $false; Remove = $false; Icon = [char]0xE711 }
		)
	}

	It 'shows all entries and warnings with Cancel as the keyboard default' {
		$script:inspectShareWindow = {
			param($window)
			$window.FindName('btnCancel').IsDefault | Should Be $true
			$window.FindName('txtScanAccess').Text | Should Match 'TEST\\scan.*Change'
			$window.FindName('txtAccessWarning').Text | Should Match 'groups.*Unselected entries stay.*Deny'
			$rows = $window.FindName('lstShareAccess').ItemsSource
			$rows.Count | Should Be 2
			$rows[0].Remove | Should Be $false
			$rows[1].CanRemove | Should Be $false
			$rows[0].Remove = $true
			$rows[1].Remove = $true
		}
		$result = Show-ScanShareAccessDialog -ShareName 'scans & <demo>' -FolderPath 'C:\scans & <demo>' -ScanAccount 'TEST\scan' -Rows $script:shareDialogRows
		$result.RemoveAccounts.Count | Should Be 1
		$result.RemoveAccounts[0] | Should Be 'Everyone'
	}

	It 'returns no ACL or replacement-name choices on cancel or close' {
		foreach ($accepted in @($false, $null)) {
			$script:shareDialogAccepted = $accepted
			Show-ScanShareAccessDialog -ShareName scans -Rows $script:shareDialogRows | Should BeNullOrEmpty
			Show-ScanShareConflictDialog -ShareName scans -ExistingPath 'D:\other' -FolderPath 'C:\scans' | Should BeNullOrEmpty
		}
	}

	It 'requires nonblank replacement names and treats runtime text as text, not markup' {
		$script:inspectShareWindow = {
			param($window)
			$window.FindName('txtMessage').Text | Should Match ([regex]::Escape('D:\other & <folder>'))
			$window.FindName('btnAccept').IsEnabled | Should Be $false
			$window.FindName('txtShareName').Text = '   '
			$window.FindName('btnAccept').IsEnabled | Should Be $false
			$window.FindName('txtShareName').Text = ' printer-scans '
			$window.FindName('btnAccept').IsEnabled | Should Be $true
			$window.FindName('btnCancel').IsDefault | Should Be $true
		}
		Show-ScanShareConflictDialog -ShareName scans -ExistingPath 'D:\other & <folder>' -FolderPath 'C:\scans' | Should Be 'printer-scans'
	}

	It 'updates removal through the actual checkbox binding' {
		$script:shareBindingError = $null
		Mock Set-WindowTheme {
			$window.WindowStartupLocation = 'Manual'
			$window.Left = -32000
			$window.Top = -32000
			$window.ShowActivated = $false
			$window.Add_ContentRendered({
				try {
					$table = $this.FindName('lstShareAccess')
					$table.UpdateLayout()
					$pending = [System.Collections.Generic.Queue[System.Windows.DependencyObject]]::new()
					$pending.Enqueue($table.ItemContainerGenerator.ContainerFromIndex(0))
					$checkbox = $null
					while ($pending.Count -and -not $checkbox) {
						$node = $pending.Dequeue()
						if ($node -is [System.Windows.Controls.CheckBox]) { $checkbox = $node }
						else {
							for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node); $i++) {
								$pending.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($node, $i))
							}
						}
					}
					if (-not $checkbox) { throw 'Share removal checkbox was not rendered.' }
					$checkbox.IsChecked = $true
				}
				catch { $script:shareBindingError = $_.Exception.Message }
				finally { $this.DialogResult = $true }
			})
		}
		$result = Show-ScanShareAccessDialog -ShareName scans -FolderPath 'C:\scans' -ScanAccount 'TEST\scan' -Rows $script:shareDialogRows
		$script:shareBindingError | Should BeNullOrEmpty
		$result.RemoveAccounts.Count | Should Be 1
		$result.RemoveAccounts[0] | Should Be 'Everyone'
	}
}

Describe 'Network setup' {
	BeforeEach {
		$script:hasNetConnection = $true
		$script:hasNetSecurity = $true
		Mock Get-NetConnectionProfile { [pscustomobject]@{ NetworkCategory = 'Private' } }
		Mock Set-NetConnectionProfile { }
		Mock Get-NetFirewallRule { $null }
		Mock Set-NetFirewallRule { }
		Mock netsh { $global:LASTEXITCODE = 0 }
	}

	It 'sets a public non-domain profile to private and enables only File and Printer Sharing by default' {
		Mock Get-NetConnectionProfile { [pscustomobject]@{ NetworkCategory = 'Public' } }
		$results = @(Set-NetworkConfiguration -DomainJoined $false)
		@($results | Where-Object { $_.Status -eq 'Failed' }).Count | Should Be 0
		Assert-MockCalled Set-NetConnectionProfile -Times 1 -Exactly -Scope It -ParameterFilter { $NetworkCategory -eq 'Private' }
		Assert-MockCalled Set-NetFirewallRule -Times 1 -Exactly -Scope It -ParameterFilter { $DisplayGroup -eq 'File and Printer Sharing' }
		Assert-MockCalled Set-NetFirewallRule -Times 0 -Exactly -Scope It -ParameterFilter { $DisplayGroup -eq 'Network Discovery' }
		$skipped = @($results | Where-Object { $_.Status -eq 'Skipped' })
		$skipped.Count | Should Be 1
		$skipped[0].Message | Should Match 'Network Discovery left unchanged'
	}

	It 'enables Network Discovery only when opted in' {
		$results = @(Set-NetworkConfiguration -DomainJoined $false -EnableDiscovery $true)
		@($results | Where-Object { $_.Status -eq 'Skipped' }).Count | Should Be 0
		Assert-MockCalled Set-NetFirewallRule -Times 1 -Exactly -Scope It -ParameterFilter { $DisplayGroup -eq 'File and Printer Sharing' -and $Profile -eq 'Private' }
		Assert-MockCalled Set-NetFirewallRule -Times 1 -Exactly -Scope It -ParameterFilter { $DisplayGroup -eq 'Network Discovery' -and $Profile -eq 'Private' }
		@($results | Where-Object { $_.Message -match 'Network Discovery has been enabled \(Private profile\)' }).Count | Should Be 1
	}

	It 'never touches the Network Discovery group when not opted in' {
		Set-NetworkConfiguration -DomainJoined $false | Out-Null
		Assert-MockCalled Get-NetFirewallRule -Times 0 -Exactly -Scope It -ParameterFilter { $DisplayGroup -eq 'Network Discovery' }
		Assert-MockCalled Set-NetFirewallRule -Times 0 -Exactly -Scope It -ParameterFilter { $DisplayGroup -eq 'Network Discovery' }
	}

	It 'does not change a domain profile and maps DomainAuthenticated to Domain' {
		Mock Get-NetConnectionProfile { [pscustomobject]@{ NetworkCategory = 'DomainAuthenticated' } }
		$results = @(Set-NetworkConfiguration -DomainJoined $true -EnableDiscovery $true)
		$results[0].Status | Should Be 'Skipped'
		Assert-MockCalled Set-NetConnectionProfile -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-NetFirewallRule -Times 2 -Exactly -Scope It -ParameterFilter { $Profile -eq 'Domain' }
	}

	It 'leaves already enabled private networking unchanged' {
		Mock Get-NetFirewallRule { [pscustomobject]@{ Enabled = 'True'; Profile = 'Private' } }
		$results = @(Set-NetworkConfiguration -DomainJoined $false -EnableDiscovery $true)
		Assert-MockCalled Set-NetConnectionProfile -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-NetFirewallRule -Times 0 -Exactly -Scope It
		@($results | Where-Object { $_.Message -match 'already enabled' }).Count | Should Be 2
	}

	It 'reports non-terminating firewall failures' {
		Mock Set-NetFirewallRule { Write-Error 'Access is denied' }
		$results = @(Set-NetworkConfiguration -DomainJoined $false -EnableDiscovery $true)
		@($results | Where-Object { $_.Status -eq 'Failed' }).Count | Should Be 2
	}

	It 'runs the legacy firewall path and respects domain management' {
		$script:hasNetConnection = $false
		$script:hasNetSecurity = $false
		$results = @(Set-NetworkConfiguration -DomainJoined $true -EnableDiscovery $true)
		$results[0].Status | Should Be 'Skipped'
		Assert-MockCalled netsh -Times 2 -Exactly -Scope It
	}

	It 'runs only the File and Printer Sharing legacy command by default' {
		$script:hasNetConnection = $false
		$script:hasNetSecurity = $false
		Set-NetworkConfiguration -DomainJoined $true | Out-Null
		Assert-MockCalled netsh -Times 1 -Exactly -Scope It
	}

	It 'reports every failed legacy firewall command rather than claiming success' {
		$script:hasNetConnection = $false
		$script:hasNetSecurity = $false
		Mock netsh { $global:LASTEXITCODE = 1; 'Access is denied' }
		$results = @(Set-NetworkConfiguration -DomainJoined $false -EnableDiscovery $true)
		@($results | Where-Object { $_.Status -eq 'Failed' }).Count | Should Be 3
	}
}

Describe 'Desktop shortcut setup' {
	It 'writes the expected public desktop shortcut without using COM' {
		$script:saved = $false
		$script:shortcut = [pscustomobject]@{ TargetPath = ''; IconLocation = ''; Description = '' }
		$script:shortcut | Add-Member ScriptMethod Save { $script:saved = $true }
		$script:shell = [pscustomobject]@{}
		$script:shell | Add-Member ScriptMethod CreateShortcut {
			param($path)
			$path | Should Be 'C:\Users\Public\Desktop\Scans.lnk'
			return $script:shortcut
		}
		Mock New-Object { $script:shell } -ParameterFilter { $ComObject -eq 'WScript.Shell' }
		$result = Initialize-DesktopShortcut -FolderPath 'C:\scans' -IconPath 'C:\scans.ico' -Description 'Test shortcut'
		$result.Status | Should Be 'Success'
		$script:shortcut.TargetPath | Should Be 'C:\scans'
		$script:shortcut.IconLocation | Should Be 'C:\scans.ico'
		$script:shortcut.Description | Should Be 'Test shortcut'
		$script:saved | Should Be $true
	}

	It 'reports COM activation failure' {
		Mock New-Object { throw 'COM unavailable' } -ParameterFilter { $ComObject -eq 'WScript.Shell' }
		$result = Initialize-DesktopShortcut -FolderPath 'C:\scans' -IconPath 'C:\scans.ico'
		$result.Status | Should Be 'Failed'
		$result.Error | Should Match 'COM unavailable'
	}

	It 'reports a missing icon path before invoking Windows shortcut creation' {
		Mock New-Object { throw 'Should not create a COM object' } -ParameterFilter { $ComObject -eq 'WScript.Shell' }
		$result = Initialize-DesktopShortcut -FolderPath 'C:\scans'
		$result.Status | Should Be 'Failed'
		$result.Error | Should Match 'shortcut icon path is missing'
		Assert-MockCalled New-Object -Times 0 -Exactly -Scope It -ParameterFilter { $ComObject -eq 'WScript.Shell' }
	}

	It 'keeps the production icon path visible to setup in the loader child scope' {
		$assignment = $ast.EndBlock.Statements | Where-Object {
			$_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
			($_.Left.Extent.Text -replace '^\$(script:)?', '') -eq 'iconPath'
		}
		$assignment | Should Not BeNullOrEmpty
		$hostShell = [powershell]::Create()
		try {
			$launch = '& {' + $assignment.Extent.Text +
				'; function Get-TestShortcutIcon { $script:iconPath }; Get-TestShortcutIcon }'
			$value = @($hostShell.AddScript($launch).Invoke())
			$hostShell.HadErrors | Should Be $false
			$value.Count | Should Be 1
			$value[0] | Should Be 'C:\ProgramData\scans.ico'
		}
		finally { $hostShell.Dispose() }
	}
}

Describe 'Generated passphrases' {
	It 'uses the curated EFF short word list' {
		$words = Get-ScanPassphraseWordList
		$words.Count | Should Be 1293
		@($words | Sort-Object -Unique).Count | Should Be 1293
		@($words | Where-Object { $_ -notmatch '^[a-z]{3,5}$' }).Count | Should Be 0
		$words -contains 'scan' | Should Be $false
		$words -contains 'user' | Should Be $false
	}

	It 'creates five capitalized hyphen-separated words with exactly one digit after a word' {
		$words = Get-ScanPassphraseWordList
		foreach ($attempt in 1..50) {
			$passphrase = New-ScanPassphrase
			$passphrase | Should Match '^([A-Z][a-z]{2,4}\d?-){4}[A-Z][a-z]{2,4}\d?$'
			([regex]::Matches($passphrase, '\d')).Count | Should Be 1
			($passphrase.Length -ge 20 -and $passphrase.Length -le 30) | Should Be $true
			foreach ($part in $passphrase -split '-') {
				$words -contains ($part -replace '\d', '').ToLowerInvariant() | Should Be $true
			}
			# Windows complexity: upper, lower, digit and symbol are all present.
			$passphrase | Should MatchExactly '[A-Z]'
			$passphrase | Should MatchExactly '[a-z]'
		}
	}

	It 'honors an explicitly requested word count' {
		@((New-ScanPassphrase -WordCount 7) -split '-').Count | Should Be 7
	}

	It 'varies the generated passphrase and digit position' {
		$samples = @(1..40 | ForEach-Object { New-ScanPassphrase })
		@($samples | Sort-Object -Unique).Count | Should Be 40
		$positions = @($samples | ForEach-Object { @($_ -split '-').IndexOf((@($_ -split '-') | Where-Object { $_ -match '\d' })) } | Sort-Object -Unique)
		($positions.Count -gt 1) | Should Be $true
	}

	It 'rejects random values from the biased tail instead of using modulo' {
		$script:randomCalls = 0
		$generator = [pscustomobject]@{}
		$generator | Add-Member ScriptMethod GetBytes {
			param([byte[]]$Buffer)
			$script:randomCalls++
			# First draw is 0xFFFFFFFF, inside the incomplete final block for 1293.
			$fill = if ($script:randomCalls -eq 1) { 255 } else { 0 }
			for ($i = 0; $i -lt $Buffer.Length; $i++) { $Buffer[$i] = $fill }
		}
		Get-ScanRandomIndex -Count 1293 -Generator $generator | Should Be 0
		$script:randomCalls | Should Be 2
	}
}

Describe 'Shared themed dialogs' {
	BeforeEach {
		Add-Type -AssemblyName PresentationFramework
		Initialize-TestTheme
		$script:dialogAccepted = $true
		$script:inspectDialog = { param($window) }
		Mock Set-WindowTheme {
			$window | Add-Member ScriptMethod ShowDialog {
				& $script:inspectDialog $this
				return $script:dialogAccepted
			} -Force
		}
	}

	It 'supports source-owned input controls without treating runtime text as markup' {
		$message = 'Account <test> & "example": {Binding Secret}'
		$window = New-ScanDialog -Title $message -Message $message -Guidance $message `
			-ContentXaml '<TextBox Name="txtInput"/>' -AcceptText 'Continue' -CancelText 'Stop'
		$window.Title | Should Be "PrintMaster Scans - $message"
		$window.FindName('txtMessage').Text | Should Be $message
		$window.FindName('txtGuidance').Text | Should Be $message
		$window.FindName('txtInput') | Should Not BeNullOrEmpty
		$window.FindName('btnAccept').Content | Should Be 'Continue'
		$window.FindName('btnCancel').Content | Should Be 'Stop'
		$window.FindName('txtProvider').Text | Should Be 'Provided by PrintMaster'
		$window.Icon | Should Not BeNullOrEmpty
		$window.Close()
	}

	It 'inherits application resources in both light and dark palettes' {
		$resourceAssignment = $ast.Find({
			param($node)
			$node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
			$node.Left.Extent.Text -eq '$script:themeResources'
		}, $true)
		foreach ($background in @('#002b36', '#fdf6e3')) {
			$script:thBg = $background
			. ([scriptblock]::Create($resourceAssignment.Extent.Text))
			$window = New-ScanDialog -Title 'Theme Test' -Message 'Themed message'
			$window.Background.Color | Should Be ([System.Windows.Media.ColorConverter]::ConvertFromString($background))
			$window.FindName('btnAccept').Style | Should Not BeNullOrEmpty
			$window.FindName('btnAccept').Background.Color | Should Be ([System.Windows.Media.ColorConverter]::ConvertFromString($script:thAccent))
			Assert-MockCalled Set-WindowTheme -Scope It -ParameterFilter { $window.Title -eq 'PrintMaster Scans - Theme Test' }
			$window.Close()
		}
	}

	It 'puts quiet Cancel before the emphasized rightmost approval action in both themes' {
		$palette = $ast.Find({
			param($node)
			$node -is [System.Management.Automation.Language.IfStatementAst] -and
			$node.Clauses[0].Item1.Extent.Text -eq '$script:useDarkTheme'
		}, $true)
		$resources = $ast.Find({
			param($node)
			$node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
			$node.Left.Extent.Text -eq '$script:themeResources'
		}, $true)
		foreach ($dark in @($true, $false)) {
			$script:useDarkTheme = $dark
			. ([scriptblock]::Create($palette.Extent.Text))
			. ([scriptblock]::Create($resources.Extent.Text))
			$window = New-ScanDialog -Title 'Footer hierarchy' -DefaultCancel
			try {
				$cancel = $window.FindName('btnCancel')
				$accept = $window.FindName('btnAccept')
				$cancel.Parent.Children[0] | Should Be $cancel
				$cancel.Parent.Children[1] | Should Be $accept
				$cancel.Background.Color.A | Should Be 0
				$cancel.Foreground.Color | Should Be ([System.Windows.Media.ColorConverter]::ConvertFromString($script:thFgStrong))
				$cancel.BorderThickness.Left | Should Be 1
				$accept.Background.Color | Should Be ([System.Windows.Media.ColorConverter]::ConvertFromString($script:thAccent))
				$accept.FontWeight | Should Be ([System.Windows.FontWeights]::SemiBold)
				$cancel.IsDefault | Should Be $true
				$cancel.IsCancel | Should Be $true
				$accept.IsDefault | Should Be $false
				$cancel.ApplyTemplate() | Out-Null
				$mouseKey = [System.Windows.UIElement].GetField('IsMouseOverPropertyKey', [Reflection.BindingFlags]'Static,NonPublic').GetValue($null)
				$cancel.SetValue($mouseKey, $true)
				$cancel.Background.Color | Should Be ([System.Windows.Media.ColorConverter]::ConvertFromString($script:thBgAlt))
				$cancel.Foreground.Color | Should Be ([System.Windows.Media.ColorConverter]::ConvertFromString($script:thFgStrong))
				$window.Content.Measure([System.Windows.Size]::new(900, 780))
				$window.Content.Arrange([System.Windows.Rect]::new(0, 0, 900, 200))
				$window.Content.UpdateLayout()
				($accept.ActualWidth -gt 0) | Should Be $true
				$cancel.TranslatePoint([System.Windows.Point]::new(0, 0), $window.Content).X | Should BeLessThan $accept.TranslatePoint([System.Windows.Point]::new(0, 0), $window.Content).X
			}
			finally { $window.Close() }
		}
	}

	It 'centers on an owner when supplied and on screen for startup failures' {
		$ownerWindow = [System.Windows.Window]::new()
		[System.Windows.Interop.WindowInteropHelper]::new($ownerWindow).EnsureHandle() | Out-Null
		$owned = New-ScanDialog -Title 'Owned' -Owner $ownerWindow
		$owned.Owner | Should Be $ownerWindow
		$owned.WindowStartupLocation | Should Be ([System.Windows.WindowStartupLocation]::CenterOwner)
		$unowned = New-ScanDialog -Title 'Startup'
		$unowned.Owner | Should BeNullOrEmpty
		$unowned.WindowStartupLocation | Should Be ([System.Windows.WindowStartupLocation]::CenterScreen)
		$owned.Close()
		$unowned.Close()
		$ownerWindow.Close()
	}

	It 'defaults account confirmation to cancel and returns true only for explicit acceptance' {
		$script:progressWindow = $null
		$script:inspectDialog = {
			param($window)
			$window.FindName('btnAccept').IsDefault | Should Be $false
			$window.FindName('btnCancel').IsDefault | Should Be $true
			$window.FindName('btnCancel').IsCancel | Should Be $true
			$window.FindName('btnAccept').Content | Should Be 'Change password'
			$window.FindName('btnCancel').Content | Should Be 'Cancel setup'
			$window.FindName('txtMessage').Text | Should Match "local account named 'scans'"
			$window.FindName('txtMessage').Text | Should Match 'will change its password'
		}
		foreach ($accepted in @($true, $false, $null)) {
			$script:dialogAccepted = $accepted
			Confirm-ExistingScanAccountUpdate -Username scans | Should Be ($accepted -eq $true)
		}
	}

	It 'shows error details and remediation without a cancel button or leaking a return value' {
		$script:inspectDialog = {
			param($window)
			$window.FindName('txtMessage').Text | Should Be 'Access denied <example>'
			$window.FindName('txtGuidance').Text | Should Match 'How to fix:'
			$window.FindName('txtGuidance').Text | Should Match 'Try again as administrator'
			$window.FindName('btnCancel').Visibility | Should Be ([System.Windows.Visibility]::Collapsed)
		}
		Show-ErrorPopup -Title 'Test Error' -Message 'Access denied <example>' -Remediation 'Try again as administrator' | Should BeNullOrEmpty
	}

	It 'accepts through the shared button handler without caller-specific wiring' {
		Mock Set-WindowTheme { }
		$window = New-ScanDialog -Title 'Button Test'
		$window.WindowStartupLocation = 'Manual'
		$window.Left = -32000
		$window.Top = -32000
		$window.ShowActivated = $false
		$window.Add_ContentRendered({
			$this.FindName('btnAccept').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
		})
		$window.ShowDialog() | Should Be $true
	}

	It 'never treats closing the dialog as consent' {
		Mock Set-WindowTheme { }
		$window = New-ScanDialog -Title 'Close Test' -DefaultCancel
		$window.WindowStartupLocation = 'Manual'
		$window.Left = -32000
		$window.Top = -32000
		$window.ShowActivated = $false
		$window.Add_ContentRendered({ $this.Close() })
		($window.ShowDialog() -eq $true) | Should Be $false
	}

	It 'initializes theme and icon before any preflight error can open a dialog' {
		$source = Get-Content $sourcePath -Raw
		$preflight = $source.IndexOf('$currentPrincipal =')
		$source.IndexOf('$script:themeResources =') | Should BeLessThan $preflight
		$source.IndexOf('function Set-WindowTheme') | Should BeLessThan $preflight
		$source.IndexOf('function New-PrintMasterIcon') | Should BeLessThan $preflight
		$source.IndexOf('$script:iconPath =') | Should BeGreaterThan $preflight
	}
}

Describe 'Setup wizard window' {
	$WarningPreference = 'SilentlyContinue'
	BeforeEach {
		Add-Type -AssemblyName PresentationFramework, System.Windows.Forms
		Initialize-TestTheme
		$script:hasDwmTheming = $false
		$script:scanUser = 'scans'; $script:folderPath = 'C:\scans'; $script:shareName = 'scans'
		$script:description = 'Scanning provided by PrintMaster'
		foreach ($name in 'createUser', 'hideUser', 'createFolder', 'setPermissions', 'setShare', 'createShortcut', 'checkNetworkSettings') {
			Set-Variable -Scope Script -Name $name -Value $true
		}
		$script:enableNetworkDiscovery = $false
		$script:confirmedExistingAccount = $null
		Mock New-ScanPassphrase { 'Alpha-Bravo7-Charlie-Delta' }
		Mock Get-ScanAccountState { [pscustomobject]@{ Username = $Username; Exists = $false; IsAdministrator = $false; CheckFailed = $false; Message = $null } }
		Mock Get-ScanNetworkAddresses { @([pscustomobject]@{ Adapter = 'Ethernet'; Address = '192.168.1.20' }) }
		$script:wizard = New-ScanWizardWindow
		$script:progressWindow = $script:wizard
		Initialize-ScanWizard -Window $script:wizard -Configuration (New-ScanSetupConfiguration)
	}
	AfterEach {
		$script:wizardBusy = $false
		$script:wizard.Close()
	}

	function Get-Control([string]$Name) { $script:wizard.FindName($Name) }
	function Invoke-Click([string]$Name) {
		(Get-Control $Name).RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
	}

	It 'starts on Configure with the settings inline, a masked generated passphrase, and no settings popup' {
		$script:wizard.Tag | Should Be 'Configure'
		$script:wizard.Title | Should Be 'PrintMaster Scans Setup'
		(Get-Control 'pageConfigure').Visibility | Should Be 'Visible'
		(Get-Control 'pageReview').Visibility | Should Be 'Collapsed'
		(Get-Control 'btnBack').Visibility | Should Be 'Collapsed'
		(Get-Control 'btnNext').Content | Should Be 'Next'
		(Get-Control 'txtUsername').Text | Should Be 'scans'
		(Get-Control 'expAdvanced').IsExpanded | Should Be $false
		(Get-Control 'chkNetworkDiscovery').IsChecked | Should Be $false
		(Get-Control 'configPasswordBox').Visibility | Should Be 'Visible'
		(Get-Control 'configPasswordText').Visibility | Should Be 'Collapsed'
		(Get-Control 'configPasswordBox').Password | Should Be 'Alpha-Bravo7-Charlie-Delta'
		(Get-Control 'txtSharePreview').Text | Should Match '\\scans$'
		Get-Control 'btnSettings' | Should BeNullOrEmpty
	}

	It 'prefills names and selects the default steps when launched in the loader child scope' {
		$defaultNames = @('scanUser', 'folderPath', 'shareName', 'description',
			'createUser', 'hideUser', 'createFolder', 'setPermissions', 'setShare',
			'createShortcut', 'checkNetworkSettings', 'enableNetworkDiscovery')
		$assignments = @($ast.EndBlock.Statements | Where-Object {
			$_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
			($_.Left.Extent.Text -replace '^\[string\]', '' -replace '^\$(script:)?', '') -in $defaultNames
		})
		$assignments.Count | Should Be $defaultNames.Count
		$factory = $ast.Find({
			param($node)
			$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
			$node.Name -eq 'New-ScanSetupConfiguration'
		}, $true)
		# A fresh runspace prevents the fixture's script-scoped defaults from hiding
		# the scope mismatch when the loader invokes the utility with &.
		$launch = '& {' + ($assignments.Extent.Text -join "`n") + "`n" +
			$factory.Extent.Text + "`nNew-ScanSetupConfiguration`n}"
		$hostShell = [powershell]::Create()
		try {
			$configuration = @($hostShell.AddScript($launch).Invoke())
			$hostShell.HadErrors | Should Be $false
			$configuration.Count | Should Be 1
			$configuration = $configuration[0]
		}
		finally { $hostShell.Dispose() }
		$configuration.Username | Should Be 'scans'
		$configuration.FolderPath | Should Be 'C:\scans'
		$configuration.ShareName | Should Be 'scans'
		$configuration.Description | Should Be 'Scanning provided by PrintMaster'
		foreach ($name in 'CreateUser', 'HideUser', 'CreateFolder', 'SetPermissions',
			'SetShare', 'CreateShortcut', 'CheckNetwork') {
			$configuration.$name | Should Be $true
		}
		$configuration.EnableDiscovery | Should Be $false
		Set-ScanWizardConfiguration -Window $script:wizard -Configuration $configuration
		(Get-Control 'txtUsername').Text | Should Be 'scans'
		(Get-Control 'txtFolderPath').Text | Should Be 'C:\scans'
		(Get-Control 'txtShareName').Text | Should Be 'scans'
		(Get-Control 'txtSharePreview').Text | Should Match '\\scans$'
	}

	It 'reveals, edits, generates, and re-masks through the shared password field' {
		Invoke-Click 'configReveal'
		(Get-Control 'configPasswordText').Visibility | Should Be 'Visible'
		(Get-Control 'configPasswordText').Text | Should Be 'Alpha-Bravo7-Charlie-Delta'
		(Get-Control 'configReveal').Content | Should Be 'Hide'
		(Get-Control 'configPasswordText').Text = 'Typed-While-Shown'
		(Get-Control 'configPasswordBox').Password | Should Be 'Typed-While-Shown'
		Mock New-ScanPassphrase { 'Echo-Foxtrot3-Golf-Hotel' }
		Invoke-Click 'configGenerate'
		(Get-Control 'configPasswordText').Text | Should Be 'Echo-Foxtrot3-Golf-Hotel'
		Invoke-Click 'configReveal'
		(Get-Control 'configPasswordText').Visibility | Should Be 'Collapsed'
		(Get-Control 'configPasswordText').Text | Should BeNullOrEmpty
		Get-TestPlainText (Get-ScanPasswordFieldSecret -Window $script:wizard -Prefix 'config') | Should Be 'Echo-Foxtrot3-Golf-Hotel'
	}

	It 'keeps dependent options disabled until their parent step is selected' {
		(Get-Control 'chkCreateFolder').IsChecked = $false
		(Get-Control 'chkSetPermissions').IsEnabled | Should Be $false
		(Get-Control 'chkNetworkSettings').IsChecked = $false
		(Get-Control 'chkNetworkDiscovery').IsEnabled | Should Be $false
		$configuration = Get-ScanWizardConfiguration -Window $script:wizard
		$configuration.SetPermissions | Should Be $false
		$configuration.EnableDiscovery | Should Be $false
		(Get-Control 'chkNetworkSettings').IsChecked = $true
		(Get-Control 'chkNetworkDiscovery').IsEnabled | Should Be $true
	}

	It 'stays on Configure and lists problems when input is invalid' {
		(Get-Control 'txtUsername').Text = ''
		Clear-ScanPasswordField -Window $script:wizard -Prefix 'config'
		Invoke-Click 'btnNext'
		$script:wizard.Tag | Should Be 'Configure'
		(Get-Control 'pnlValidation').Visibility | Should Be 'Visible'
		(Get-Control 'txtValidation').Text | Should Match 'account name'
		(Get-Control 'txtValidation').Text | Should Match 'password'
		Assert-MockCalled Get-ScanAccountState -Times 0 -Exactly -Scope It
	}

	It 'moves to Review and back without losing any choice' {
		(Get-Control 'txtUsername').Text = 'printer'
		(Get-Control 'txtShareName').Text = 'office-scans'
		(Get-Control 'chkCreateShortcut').IsChecked = $false
		(Get-Control 'chkNetworkDiscovery').IsChecked = $true
		Invoke-Click 'btnNext'
		$script:wizard.Tag | Should Be 'Review'
		Assert-MockCalled Get-ScanAccountState -Times 1 -Exactly -Scope It -ParameterFilter { $Username -eq 'printer' }
		(Get-Control 'btnNext').Content | Should Be 'Apply'
		(Get-Control 'btnNext').IsEnabled | Should Be $true
		(Get-Control 'btnBack').Visibility | Should Be 'Visible'
		(Get-Control 'grdReview').Children.Count | Should BeGreaterThan 0
		(Get-Control 'pnlAccountNotice').Visibility | Should Be 'Collapsed'
		Invoke-Click 'btnBack'
		$script:wizard.Tag | Should Be 'Configure'
		(Get-Control 'txtUsername').Text | Should Be 'printer'
		(Get-Control 'txtShareName').Text | Should Be 'office-scans'
		(Get-Control 'chkCreateShortcut').IsChecked | Should Be $false
		(Get-Control 'chkNetworkDiscovery').IsChecked | Should Be $true
		(Get-Control 'configPasswordBox').Password | Should Be 'Alpha-Bravo7-Charlie-Delta'
	}

	It 'requires inline confirmation for an existing account and blocks administrators' {
		Mock Get-ScanAccountState { [pscustomobject]@{ Username = $Username; Exists = $true; IsAdministrator = $false; CheckFailed = $false; Message = $null } }
		Invoke-Click 'btnNext'
		(Get-Control 'pnlAccountNotice').Visibility | Should Be 'Visible'
		(Get-Control 'chkConfirmExisting').Visibility | Should Be 'Visible'
		(Get-Control 'btnNext').IsEnabled | Should Be $false
		(Get-Control 'chkConfirmExisting').IsChecked = $true
		(Get-Control 'btnNext').IsEnabled | Should Be $true
		Invoke-Click 'btnBack'
		Mock Get-ScanAccountState { [pscustomobject]@{ Username = $Username; Exists = $true; IsAdministrator = $true; CheckFailed = $false; Message = $null } }
		Invoke-Click 'btnNext'
		(Get-Control 'chkConfirmExisting').IsChecked | Should Be $false
		(Get-Control 'chkConfirmExisting').Visibility | Should Be 'Collapsed'
		(Get-Control 'txtAccountNotice').Text | Should Match 'Administrators'
		(Get-Control 'btnNext').IsEnabled | Should Be $false
	}

	It 'applies with the confirmed account and shows connection details on Done' {
		Mock Get-ScanAccountState { [pscustomobject]@{ Username = $Username; Exists = $true; IsAdministrator = $false; CheckFailed = $false; Message = $null } }
		Mock Invoke-ScanSetup {
			$script:seenConfirmation = $script:confirmedExistingAccount
			$script:seenPassword = Get-TestPlainText $Password
			$script:seenBusy = $script:wizardBusy
			$script:wizard.Tag | Should Be 'Apply'
			(Get-Control 'btnCancel').IsEnabled | Should Be $false
			$result = New-ScanSetupResult -Configuration $Configuration
			$result.Identity = [pscustomobject]@{ ComputerName = 'FRONTDESK'; HostName = 'FRONTDESK'; Fqdn = $null; DomainJoined = $false }
			$result.AccountStepRan = $true; $result.AccountConfigured = $true; $result.ShareConfigured = $true
			$result.Password = $Password
			$result.Steps = @([pscustomobject]@{ Category = 'Account'; Status = 'Success'; Message = 'Account ready'; Error = $null; Tip = $null })
			$result
		}
		Invoke-Click 'btnNext'
		(Get-Control 'chkConfirmExisting').IsChecked = $true
		Invoke-Click 'btnNext'
		$script:seenConfirmation | Should Be 'scans'
		$script:seenPassword | Should Be 'Alpha-Bravo7-Charlie-Delta'
		$script:seenBusy | Should Be $true
		$script:wizardBusy | Should Be $false
		$script:confirmedExistingAccount | Should BeNullOrEmpty
		$script:wizard.Tag | Should Be 'Done'
		$script:wizard.Title | Should Match 'Ready for scanning'
		(Get-Control 'txtOutcomeTitle').Text | Should Be 'Ready for scanning'
		(Get-Control 'btnNext').Content | Should Be 'Close'
		(Get-Control 'btnBack').Content | Should Be 'Back to setup'
		(Get-Control 'btnCancel').Visibility | Should Be 'Collapsed'
		(Get-Control 'pnlConnection').Visibility | Should Be 'Visible'
		@($script:connectionDetails | Where-Object Key -eq 'password')[0].CanCopy | Should Be $true
		(Get-Control 'pnlResults').Children.Count | Should Be 1
		Invoke-Click 'btnBack'
		$script:wizard.Tag | Should Be 'Configure'
		$script:wizardResult | Should BeNullOrEmpty
		(Get-Control 'txtUsername').Text | Should Be 'scans'
	}

	It 'records unexpected setup errors on the Done page instead of crashing' {
		Mock Get-ScanComputerIdentity { [pscustomobject]@{ ComputerName = 'PC1'; HostName = 'PC1'; Fqdn = $null; DomainJoined = $false } }
		Mock Set-ProgressBar { }
		Mock Invoke-ScanSetup { $script:stepResults = New-Object System.Collections.ArrayList; throw 'Kaboom' }
		Invoke-Click 'btnNext'
		Invoke-Click 'btnNext'
		$script:wizard.Tag | Should Be 'Done'
		(Get-Control 'txtOutcomeTitle').Text | Should Be 'Not ready for scanning'
		@($script:wizardResult.Steps)[0].Error | Should Be 'Kaboom'
		@($script:connectionDetails | Where-Object Key -eq 'password')[0].Value | Should Match 'Unknown'
	}

	It 'hides connection details and leads with results when setup is canceled' {
		Mock Invoke-ScanSetup {
			$result = New-ScanSetupResult -Configuration $Configuration
			$result.Canceled = $true; $result.CancelReason = 'password correction was canceled'
			$result.Steps = @([pscustomobject]@{ Category = 'Account'; Status = 'Skipped'; Message = 'Canceled'; Error = $null; Tip = $null })
			$result
		}
		Invoke-Click 'btnNext'
		Invoke-Click 'btnNext'
		(Get-Control 'txtOutcomeTitle').Text | Should Be 'Setup canceled'
		(Get-Control 'pnlConnection').Visibility | Should Be 'Collapsed'
		[array]::IndexOf(@((Get-Control 'pageDone').Children), (Get-Control 'pnlResultsSection')) | Should Be 1
	}

	It 'returns a replacement password from the inline retry panel and cleans up' {
		Mock Wait-ScanWizardPrompt {
			(Get-Control 'pnlPasswordRetry').Visibility | Should Be 'Visible'
			(Get-Control 'txtRetryError').Text | Should Be 'Policy rejected'
			(Get-Control 'btnRetryPassword').IsEnabled | Should Be $false
			(Get-Control 'retryPasswordBox').Password = 'Manual-Replacement9'
			(Get-Control 'btnRetryPassword').IsEnabled | Should Be $true
			$true
		}
		$replacement = Request-ScanReplacementPassword -ErrorText 'Policy rejected' -Window $script:wizard
		Get-TestPlainText $replacement | Should Be 'Manual-Replacement9'
		(Get-Control 'pnlPasswordRetry').Visibility | Should Be 'Collapsed'
		(Get-Control 'retryPasswordBox').Password | Should BeNullOrEmpty
		Mock Wait-ScanWizardPrompt { $false }
		Request-ScanReplacementPassword -ErrorText 'Policy rejected' -Window $script:wizard | Should BeNullOrEmpty
	}

	It 'resolves the inline prompt from the Retry and Cancel setup buttons' {
		$script:wizardPromptFrame = [System.Windows.Threading.DispatcherFrame]::new()
		Invoke-Click 'btnRetryPassword'
		$script:wizardPromptResult | Should Be $true
		$script:wizardPromptFrame.Continue | Should Be $false
		Invoke-Click 'btnRetryCancel'
		$script:wizardPromptResult | Should Be $false
		$script:wizardPromptFrame = $null
	}

	It 'copies each connection detail through the right clipboard path' {
		Mock Set-ScanClipboardText { }
		Mock Copy-ScanSecret { }
		$script:wizardResult = [pscustomobject]@{ Password = ConvertTo-ScanSecureString 'Copied-Secret1'; Steps = @() }
		$identity = [pscustomobject]@{ ComputerName = 'FRONTDESK'; HostName = 'FRONTDESK'; Fqdn = 'FRONTDESK.lan'; DomainJoined = $false }
		$script:connectionDetails = @(Get-ScanConnectionDetails -Identity $identity -Username 'scans' -ShareName 'scans' -ShareConfigured $true -FolderPath 'C:\scans' -Addresses @(Get-ScanNetworkAddresses) -PasswordAvailable $true)
		foreach ($row in $script:connectionDetails | Where-Object { $_.CanCopy -and -not $_.Sensitive }) {
			Copy-ScanConnectionDetail -Window $script:wizard -Key $row.Key
			$expected = $row.Value
			Assert-MockCalled Set-ScanClipboardText -Times 1 -Scope It -ParameterFilter { $Text -eq $expected -and -not $Sensitive }
		}
		Copy-ScanConnectionDetail -Window $script:wizard -Key 'password'
		Assert-MockCalled Copy-ScanSecret -Times 1 -Exactly -Scope It -ParameterFilter { [object]::ReferenceEquals($Secret, $script:wizardResult.Password) }
		(Get-Control 'txtCopyStatus').Text | Should Match 'Copied the password'
		$script:connectionDetails = @(Get-ScanConnectionDetails -Identity $identity -Username 'scans' -ShareName 'scans' -ShareConfigured $true -FolderPath 'C:\scans' -PasswordAvailable $false)
		Copy-ScanConnectionDetail -Window $script:wizard -Key 'password'
		Assert-MockCalled Copy-ScanSecret -Times 1 -Exactly -Scope It
	}

	It 'masks the Done page password until Show is pressed' {
		$script:wizardResult = [pscustomobject]@{ Password = ConvertTo-ScanSecureString 'Shown-Secret2'; Steps = @() }
		$value = [System.Windows.Controls.TextBlock]::new()
		$value.Text = [string]::new([char]0x25CF, 12)
		$button = [System.Windows.Controls.Button]::new()
		$button.Content = 'Show'
		$button.Tag = $value
		Switch-ScanDonePasswordReveal -Button $button
		$value.Text | Should Be 'Shown-Secret2'
		$button.Content | Should Be 'Hide'
		Switch-ScanDonePasswordReveal -Button $button
		$value.Text | Should Be ([string]::new([char]0x25CF, 12))
		$button.Content | Should Be 'Show'
	}
}

Describe 'Folder access review dialog' {
	BeforeEach {
		Add-Type -AssemblyName PresentationFramework
		Initialize-TestTheme
		$script:progressWindow = $null
		$script:accessAccepted = $true
		$script:inspectAccessWindow = { param($window) }
		Mock Resolve-ScanPrincipalDisplay { "TEST\account-$($Sid.Value.Split('-')[-1])" }
		Mock Set-WindowTheme {
			$window | Add-Member ScriptMethod ShowDialog {
				& $script:inspectAccessWindow $this
				return $script:accessAccepted
			} -Force
		}
	}

	It 'defaults to the desktop user and explicitly discloses a different elevated identity' {
		$script:inspectAccessWindow = {
			param($window)
			$window.FindName('txtIdentityWarning').Text | Should Match 'These accounts differ'
			$window.FindName('txtIdentityWarning').Text | Should Match 'not automatically for the elevated account'
			$window.FindName('txtRecipient').Text | Should Be 'DOMAIN\recipient'
			$window.FindName('chkEveryone').IsChecked | Should Be $false
			$window.FindName('txtPolicy').Text | Should Match 'inheritance will be disabled'
			$window.FindName('btnAccept').IsEnabled | Should Be $true
			$window.FindName('btnAccept').IsDefault | Should Be $false
			$window.FindName('btnCancel').IsDefault | Should Be $true
		}
		$result = Show-ScanFolderAccessDialog -FolderPath 'C:\scans' -DesktopUser 'DOMAIN\recipient' -ElevatedUser 'PC\admin'
		$result.Recipient | Should Be 'DOMAIN\recipient'
		$result.AllowEveryoneModify | Should Be $false
		$result.RemoveRules.Count | Should Be 0
	}

	It 'requires an explicit receiving user when no desktop user was detected' {
		$script:inspectAccessWindow = {
			param($window)
			$window.FindName('txtRecipient').Text | Should BeNullOrEmpty
			$window.FindName('txtIdentityWarning').Text | Should Match 'No desktop user was detected'
			$window.FindName('btnAccept').IsEnabled | Should Be $false
			$window.FindName('txtRecipient').Text = '   '
			$window.FindName('btnAccept').IsEnabled | Should Be $false
			$window.FindName('txtRecipient').Text = ' PC\recipient '
			$window.FindName('btnAccept').IsEnabled | Should Be $true
		}
		$result = Show-ScanFolderAccessDialog -FolderPath 'C:\scans' -ElevatedUser 'PC\admin'
		$result.Recipient | Should Be 'PC\recipient'
	}

	It 'shows existing ACLs and removes only individually checked legacy-shaped rules' {
		$acl = [System.Security.AccessControl.DirectorySecurity]::new()
		$acl.SetSecurityDescriptorSddlForm('D:AI(A;OICI;0x1301bf;;;WD)(A;OICI;FA;;;S-1-5-21-1-2-3-1001)')
		$candidates = @(Get-ScanFolderCleanupRules -Acl $acl -ScanSid ([System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001')))
		$script:inspectAccessWindow = {
			param($window)
			$window.FindName('txtPolicy').Text | Should Match 'inheritance and custom permissions are preserved'
			$rows = $window.FindName('lstExistingRules').ItemsSource
			$rows.Count | Should Be 2
			foreach ($row in $rows) {
				$row.Remove | Should Be $false
				$row.Principal | Should Match 'TEST\\account-'
				$row.CanRemove | Should Be $true
			}
			$rows[0].Remove = $true
			$window.FindName('chkEveryone').IsChecked = $true
			$window.FindName('pnlEveryoneWarning').Visibility | Should Be ([System.Windows.Visibility]::Visible)
			$window.FindName('chkEveryone').IsChecked = $false
			$window.FindName('pnlEveryoneWarning').Visibility | Should Be ([System.Windows.Visibility]::Collapsed)
			$window.FindName('chkEveryone').IsChecked = $true
		}
		$result = Show-ScanFolderAccessDialog -FolderPath 'C:\scans' -DesktopUser 'PC\recipient' -ElevatedUser 'PC\admin' -Acl $acl -CleanupRules $candidates
		$result.AllowEveryoneModify | Should Be $true
		$result.RemoveRules.Count | Should Be 1
		$result.RemoveRules[0].IdentityReference.Value | Should Be $candidates[0].IdentityReference.Value
	}

	It 'returns no permission choices when canceled or closed' {
		foreach ($accepted in @($false, $null)) {
			$script:accessAccepted = $accepted
			Show-ScanFolderAccessDialog -FolderPath 'C:\scans' -DesktopUser 'PC\recipient' -ElevatedUser 'PC\admin' | Should BeNullOrEmpty
		}
	}

	It 'hides the existing permissions section for new folders and keeps safe defaults' {
		$script:inspectAccessWindow = {
			param($window)
			$window.FindName('pnlExistingAccess').Visibility | Should Be ([System.Windows.Visibility]::Collapsed)
			$window.FindName('txtIdentityWarning').Visibility | Should Be ([System.Windows.Visibility]::Collapsed)
			$window.FindName('pnlEveryoneWarning').Visibility | Should Be ([System.Windows.Visibility]::Collapsed)
			$window.FindName('lstExistingRules').View.Columns.Count | Should Be 6
			$window.FindName('txtFolder').Text | Should Be 'C:\scans & <example>'
		}
		Show-ScanFolderAccessDialog -FolderPath 'C:\scans & <example>' -DesktopUser 'PC\recipient' -ElevatedUser 'PC\recipient' | Out-Null
	}

	It 'keeps warning text readable against the light and dark panel backgrounds' {
		$script:inspectAccessWindow = {
			param($window)
			$foreground = $window.FindName('txtIdentityWarning').Foreground.Color
			$background = [System.Windows.Media.ColorConverter]::ConvertFromString($script:thBgAlt)
			$luminance = foreach ($color in @($foreground, $background)) {
				$channels = foreach ($channel in @($color.R, $color.G, $color.B)) {
					$value = $channel / 255.0
					if ($value -le 0.04045) { $value / 12.92 } else { [Math]::Pow(($value + 0.055) / 1.055, 2.4) }
				}
				0.2126 * $channels[0] + 0.7152 * $channels[1] + 0.0722 * $channels[2]
			}
			$ratio = ([Math]::Max($luminance[0], $luminance[1]) + 0.05) / ([Math]::Min($luminance[0], $luminance[1]) + 0.05)
			($ratio -ge 4.5) | Should Be $true
		}
		$palette = $ast.Find({
			param($node)
			$node -is [System.Management.Automation.Language.IfStatementAst] -and
			$node.Clauses[0].Item1.Extent.Text -eq '$script:useDarkTheme'
		}, $true)
		foreach ($dark in @($true, $false)) {
			$script:useDarkTheme = $dark
			# Check the shipped palette, not test placeholders.
			. ([scriptblock]::Create($palette.Extent.Text))
			Show-ScanFolderAccessDialog -FolderPath 'C:\scans' -DesktopUser 'PC\recipient' -ElevatedUser 'PC\admin' | Out-Null
		}
		Initialize-TestTheme
	}

	It 'does not return an ineligible row even if its model is marked for removal' {
		$acl = [System.Security.AccessControl.DirectorySecurity]::new()
		$acl.SetSecurityDescriptorSddlForm('D:AI(A;OICI;FA;;;SY)')
		$script:inspectAccessWindow = {
			param($window)
			$window.FindName('lstExistingRules').ItemsSource[0].Remove = $true
		}
		$result = Show-ScanFolderAccessDialog -FolderPath 'C:\scans' -DesktopUser 'PC\recipient' -ElevatedUser 'PC\recipient' -Acl $acl
		$result.RemoveRules.Count | Should Be 0
	}

	It 'binds the table removal checkbox to the exact returned ACE' {
		$acl = [System.Security.AccessControl.DirectorySecurity]::new()
		$acl.SetSecurityDescriptorSddlForm('D:AI(A;OICI;0x1301bf;;;WD)(A;OICI;FA;;;SY)')
		$candidates = @(Get-ScanFolderCleanupRules -Acl $acl -ScanSid ([System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001')))
		$script:tableBindingError = $null
		Mock Set-WindowTheme {
			$window.WindowStartupLocation = 'Manual'
			$window.Left = -32000
			$window.Top = -32000
			$window.ShowActivated = $false
			$window.Add_ContentRendered({
				try {
					$table = $this.FindName('lstExistingRules')
					$table.UpdateLayout()
					$index = 0
					while (-not $table.Items[$index].CanRemove) { $index++ }
					$pending = [System.Collections.Generic.Queue[System.Windows.DependencyObject]]::new()
					$pending.Enqueue($table.ItemContainerGenerator.ContainerFromIndex($index))
					$checkbox = $null
					while ($pending.Count -and -not $checkbox) {
						$node = $pending.Dequeue()
						if ($node -is [System.Windows.Controls.CheckBox]) { $checkbox = $node }
						else {
							for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node); $i++) {
								$pending.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($node, $i))
							}
						}
					}
					if (-not $checkbox) { throw 'Removal checkbox was not rendered.' }
					$checkbox.IsChecked = $true
				}
				catch { $script:tableBindingError = $_.Exception.Message }
				finally { $this.DialogResult = $true }
			})
		}
		$result = Show-ScanFolderAccessDialog -FolderPath 'C:\scans' -DesktopUser 'PC\recipient' -ElevatedUser 'PC\recipient' -Acl $acl -CleanupRules $candidates
		$script:tableBindingError | Should BeNullOrEmpty
		$result.RemoveRules.Count | Should Be 1
		$result.RemoveRules[0].IdentityReference.Value | Should Be 'S-1-1-0'
	}
}

Describe 'Permission table interaction rendering' {
	BeforeEach {
		Add-Type -AssemblyName PresentationFramework
		$script:progressWindow = $null
		$script:rowRenderError = $null
		Mock Resolve-ScanPrincipalDisplay { 'TEST\recipient' }
		Mock Set-WindowTheme {
			$window.WindowStartupLocation = 'Manual'
			$window.Left = -32000
			$window.Top = -32000
			$window.ShowActivated = $false
			$window.Add_ContentRendered({
				try {
					$table = $this.FindName($script:interactionTable)
					$table.UpdateLayout()
					$row = $table.ItemContainerGenerator.ContainerFromIndex(0)
					$row | Should Not BeNullOrEmpty
					$chrome = $row.Template.FindName('RowChrome', $row)
					$chrome | Should Not BeNullOrEmpty
					([Math]::Abs($chrome.ActualWidth - $row.ActualWidth) -lt 1) | Should Be $true
					($row.ActualWidth -ge $table.ActualWidth - 40) | Should Be $true
					$mouseKey = [System.Windows.UIElement].GetField('IsMouseOverPropertyKey', [Reflection.BindingFlags]'Static,NonPublic').GetValue($null)
					$focusKey = [System.Windows.UIElement].GetField('IsKeyboardFocusWithinPropertyKey', [Reflection.BindingFlags]'Static,NonPublic').GetValue($null)
					$activeKey = [System.Windows.Controls.Primitives.Selector].GetField('IsSelectionActivePropertyKey', [Reflection.BindingFlags]'Static,NonPublic').GetValue($null)
					$states = @(
						@{ Hover = $false; Selected = $false; Active = $false; Focus = $false }
						@{ Hover = $true; Selected = $false; Active = $false; Focus = $false }
						@{ Hover = $false; Selected = $true; Active = $true; Focus = $false }
						@{ Hover = $true; Selected = $true; Active = $true; Focus = $false }
						@{ Hover = $false; Selected = $true; Active = $false; Focus = $false }
						@{ Hover = $false; Selected = $true; Active = $true; Focus = $true }
					)
					foreach ($state in $states) {
						# Drive WPF's real trigger properties without moving the user's
						# mouse or stealing desktop focus during off-screen tests.
						$row.SetValue($mouseKey, $state.Hover)
						$row.IsSelected = $state.Selected
						$row.SetValue($activeKey, $state.Active)
						$row.SetValue($focusKey, $state.Focus)
						$table.UpdateLayout()
						$background = if ($state.Hover -or $state.Selected) { $script:thBgAlt } else { $script:thBg }
						$expectedBorder = if ($state.Focus) { $script:thAccentHi } elseif ($state.Selected) { $script:thAccent } elseif ($state.Hover) { $script:thBorder } else { 'Transparent' }
						$chrome.BorderBrush.Color | Should Be ([System.Windows.Media.ColorConverter]::ConvertFromString($expectedBorder))
						$row.Foreground.Color | Should Be ([System.Windows.Media.ColorConverter]::ConvertFromString($script:thFgStrong))

						$visual = [System.Windows.Media.DrawingVisual]::new()
						$context = $visual.RenderOpen()
						$rect = [System.Windows.Rect]::new(0, 0, $row.ActualWidth, $row.ActualHeight)
						$context.DrawRectangle($table.Background, $null, $rect)
						$context.DrawRectangle([System.Windows.Media.VisualBrush]::new($row), $null, $rect)
						$context.Close()
						$bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
							[int][Math]::Ceiling($row.ActualWidth), [int][Math]::Ceiling($row.ActualHeight),
							96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
						$bitmap.Render($visual)
						$expected = [System.Windows.Media.ColorConverter]::ConvertFromString($background)
						# Sample the fill across the row below its text, not just
						# the Background property that the native template ignored.
						foreach ($x in @(3, [int]($row.ActualWidth / 2), ([int]$row.ActualWidth - 4))) {
							$pixel = [byte[]]::new(4)
							$bitmap.CopyPixels([System.Windows.Int32Rect]::new($x, [int]$row.ActualHeight - 4, 1, 1), $pixel, 4, 0)
							$pixel[0] | Should Be $expected.B
							$pixel[1] | Should Be $expected.G
							$pixel[2] | Should Be $expected.R
							$pixel[3] | Should Be 255
						}
						$luminance = foreach ($color in @($row.Foreground.Color, $expected)) {
							$channels = foreach ($channel in @($color.R, $color.G, $color.B)) {
								$value = $channel / 255.0
								if ($value -le 0.04045) { $value / 12.92 } else { [Math]::Pow(($value + 0.055) / 1.055, 2.4) }
							}
							0.2126 * $channels[0] + 0.7152 * $channels[1] + 0.0722 * $channels[2]
						}
						$ratio = ([Math]::Max($luminance[0], $luminance[1]) + 0.05) / ([Math]::Min($luminance[0], $luminance[1]) + 0.05)
						($ratio -ge 4.5) | Should Be $true
					}
				}
				catch { $script:rowRenderError = $_ | Out-String }
				finally { $this.DialogResult = $false }
			})
		}
	}

	It 'renders full-width readable interaction states for <Table> in dark=<Dark>' -TestCases @(
		@{ Table = 'folder'; Dark = $true }
		@{ Table = 'folder'; Dark = $false }
		@{ Table = 'share'; Dark = $true }
		@{ Table = 'share'; Dark = $false }
	) {
		param($Table, $Dark)
		$script:useDarkTheme = $Dark
		$palette = $ast.Find({
			param($node)
			$node -is [System.Management.Automation.Language.IfStatementAst] -and
			$node.Clauses[0].Item1.Extent.Text -eq '$script:useDarkTheme'
		}, $true)
		. ([scriptblock]::Create($palette.Extent.Text))
		$resources = $ast.Find({
			param($node)
			$node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
			$node.Left.Extent.Text -eq '$script:themeResources'
		}, $true)
		. ([scriptblock]::Create($resources.Extent.Text))
		if ($Table -eq 'folder') {
			$script:interactionTable = 'lstExistingRules'
			$acl = [System.Security.AccessControl.DirectorySecurity]::new()
			$acl.SetSecurityDescriptorSddlForm('D:AI(A;OICI;FA;;;SY)')
			Show-ScanFolderAccessDialog -FolderPath 'C:\scans' -DesktopUser 'TEST\recipient' -ElevatedUser 'TEST\recipient' -Acl $acl | Out-Null
		} else {
			$script:interactionTable = 'lstShareAccess'
			$rows = @([pscustomobject]@{
				Principal = 'TEST\recipient'; AccountName = 'TEST\recipient'; Type = 'Allow'
				Access = 'Change'; IsScan = $true; CanRemove = $false; Remove = $false; Icon = [char]0xE73E
			})
			Show-ScanShareAccessDialog -ShareName scans -FolderPath 'C:\scans' -ScanAccount 'TEST\recipient' -Rows $rows | Out-Null
		}
		$script:rowRenderError | Should BeNullOrEmpty
	}
}

Describe 'Readable folder permission rows' {
	BeforeEach {
		Initialize-TestTheme
	}

	It 'resolves a well-known SID to its Windows account name' {
		$sid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
		Resolve-ScanPrincipalDisplay $sid | Should Be $sid.Translate([System.Security.Principal.NTAccount]).Value
	}

	It 'marks an unresolved SID honestly rather than inventing a username' {
		$result = Resolve-ScanPrincipalDisplay ([System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-4294967294'))
		$result | Should Match '^Unresolved account \(S-1-5-21-'
	}

	It 'shows readable access, source, scope, deny indicators, and exact tooltip data' {
		$acl = [System.Security.AccessControl.DirectorySecurity]::new()
		$acl.SetSecurityDescriptorSddlForm('D:AI(D;;SD;;;WD)(A;OICI;FA;;;SY)(A;OICI;0x100007;;;S-1-5-21-1-2-3-1001)(A;OICIID;0x1301bf;;;WD)')
		Mock Resolve-ScanPrincipalDisplay { "Resolved $($Sid.Value)" }
		$rows = @(Get-ScanFolderAccessRows -Acl $acl)
		$rows.Count | Should Be 4
		$rows[0].Type | Should Be 'Deny'
		$rows[0].Color | Should Be '#cb4b16'
		$rows[0].Scope | Should Be 'This folder'
		$rows[1].Access | Should Be 'Full control'
		$rows[2].Access | Should Be 'Scan: read, write, append'
		$rows[3].Access | Should Be 'Modify'
		$rows[3].Source | Should Be 'Inherited'
		$rows[3].Scope | Should Be 'This folder, subfolders, files'
		$rows[3].CanRemove | Should Be $false
		$rows[3].Details | Should Match 'SID: S-1-1-0'
		Assert-MockCalled Resolve-ScanPrincipalDisplay -Times 3 -Exactly -Scope It
	}

	It 'does not enable removal for another rule on the same principal or inherited entries' {
		$acl = [System.Security.AccessControl.DirectorySecurity]::new()
		$acl.SetSecurityDescriptorSddlForm('D:AI(A;;0x1301bf;;;WD)(A;OICI;0x1301bf;;;WD)(A;OICIID;0x1301bf;;;WD)')
		$candidates = @(Get-ScanFolderCleanupRules -Acl $acl -ScanSid ([System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001')))
		$rows = @(Get-ScanFolderAccessRows -Acl $acl -CleanupRules $candidates)
		@($rows | Where-Object { $_.CanRemove }).Count | Should Be 1
		@($rows | Where-Object { $_.CanRemove })[0].Scope | Should Be 'This folder, subfolders, files'
	}

	It 'describes inherit-only and one-level rules without claiming they apply to the folder' {
		$acl = [System.Security.AccessControl.DirectorySecurity]::new()
		$acl.SetSecurityDescriptorSddlForm('D:(A;CINPIO;FR;;;SY)')
		$row = @(Get-ScanFolderAccessRows -Acl $acl)[0]
		$row.Scope | Should Be 'subfolders (one level)'
		$row.Access | Should Match '^Special:'
	}
}

Describe 'Taskbar window identity' {
	BeforeAll {
		Add-Type -AssemblyName PresentationFramework
		Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ScanTaskbarTestNative {
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
}
'@
	}

	It 'assigns the native window identity independently of DWM support and retains the printer icon' {
		$script:hasDwmTheming = $false
		$window = [System.Windows.Window]::new()
		$window.Icon = New-PrintMasterIcon
		try {
			Set-WindowTheme $window
			$hwnd = [System.Windows.Interop.WindowInteropHelper]::new($window).EnsureHandle()
			[ScanTaskbarIdentity]::GetApplicationId($hwnd) | Should Be 'mstrhakr.scans.setup'
			# WM_GETICON / ICON_BIG verifies that WPF supplied a native taskbar icon.
			$icon = [ScanTaskbarTestNative]::SendMessage($hwnd, 0x7F, [IntPtr]1, [IntPtr]::Zero)
			$icon | Should Not Be ([IntPtr]::Zero)
		}
		finally { $window.Close() }
	}

	It 'reports taskbar identity failures without preventing the window from opening' {
		Mock Initialize-ScanTaskbarInterop { throw 'Native identity unavailable' }
		Mock Write-Warning { }
		$window = [System.Windows.Window]::new()
		try {
			Set-ScanWindowTaskbarIdentity $window
			[System.Windows.Interop.WindowInteropHelper]::new($window).EnsureHandle() | Out-Null
			Assert-MockCalled Write-Warning -Times 1 -Exactly -Scope It -ParameterFilter {
				$Message -match 'Could not set the Scans taskbar identity.*Native identity unavailable'
			}
		}
		finally { $window.Close() }
	}
}

Describe 'WPF window markup' {
	It 'renders the embedded PrintMaster window logo without external files' {
		Add-Type -AssemblyName PresentationFramework
		$icon = New-PrintMasterIcon
		$icon.IsFrozen | Should Be $true
		$icon.Width | Should Be 64
		$icon.Height | Should Be 64
		$visual = [System.Windows.Media.DrawingVisual]::new()
		$context = $visual.RenderOpen()
		$context.DrawImage($icon, [System.Windows.Rect]::new(0, 0, 64, 64))
		$context.Close()
		$bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(64, 64, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
		$bitmap.Render($visual)
		$pixels = New-Object byte[] (64 * 64 * 4)
		$bitmap.CopyPixels($pixels, 64 * 4, 0)
		# The center of the green printer status light, in BGRA order.
		$offset = (32 * 64 + 46) * 4
		($pixels[$offset..($offset + 3)] -join ',') | Should Be '120,187,72,255'
		$source = Get-Content $sourcePath -Raw
		([regex]::Matches($source, '\.Icon = New-PrintMasterIcon')).Count | Should Be 2
		$source | Should Not Match '\[System\.Windows\.MessageBox\]::Show'
		$source | Should Match 'Initialize-DesktopShortcut -FolderPath .c\.FolderPath -IconPath .script:iconPath'
		$source | Should Match '\[IO.File\]::WriteAllBytes\(\$iconPath, \[Convert\]::FromBase64String\(\$script:appIconBase64\)\)'
	}

	It 'keeps status text colors readable on both backgrounds in both themes' {
		$palette = $ast.Find({
			param($node)
			$node -is [System.Management.Automation.Language.IfStatementAst] -and
			$node.Clauses[0].Item1.Extent.Text -eq '$script:useDarkTheme'
		}, $true)
		function Get-TestLuminance([string]$Hex) {
			$color = [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
			$channels = foreach ($channel in @($color.R, $color.G, $color.B)) {
				$value = $channel / 255.0
				if ($value -le 0.04045) { $value / 12.92 } else { [Math]::Pow(($value + 0.055) / 1.055, 2.4) }
			}
			return 0.2126 * $channels[0] + 0.7152 * $channels[1] + 0.0722 * $channels[2]
		}
		foreach ($dark in @($true, $false)) {
			$script:useDarkTheme = $dark
			. ([scriptblock]::Create($palette.Extent.Text))
			foreach ($foreground in @($script:thSuccess, $script:thWarn, $script:thDanger, $script:thFgStrong)) {
				foreach ($background in @($script:thBg, $script:thBgAlt)) {
					$a = Get-TestLuminance $foreground
					$b = Get-TestLuminance $background
					$ratio = ([Math]::Max($a, $b) + 0.05) / ([Math]::Min($a, $b) + 0.05)
					"$foreground on $background = $([Math]::Round($ratio, 2))" | Should Not Match ' = ([0-3]\.|4\.[0-4])'
				}
			}
		}
		Initialize-TestTheme
	}

	It 'loads the setup wizard without displaying it or running setup' {
		Add-Type -AssemblyName PresentationFramework
		Initialize-TestTheme
		$wizard = New-ScanWizardWindow
		try {
			$wizard.Title | Should Be 'PrintMaster Scans Setup'
			$wizard.Icon | Should Not BeNullOrEmpty
			$wizard.FindName('imgLogo').Source | Should Be $wizard.Icon
			$wizard.FindName('txtProvider').Text | Should Be 'Provided by PrintMaster'
			foreach ($name in @('pageConfigure', 'pageReview', 'pageApply', 'pageDone', 'txtUsername', 'configPasswordBox', 'configReveal', 'configGenerate',
					'txtFolderPath', 'btnBrowse', 'txtShareName', 'expAdvanced', 'grdReview', 'chkConfirmExisting', 'progressBar', 'lstDetails',
					'pnlPasswordRetry', 'retryPasswordBox', 'btnRetryPassword', 'grdConnection', 'pnlResults', 'btnCopySummary', 'btnBack', 'btnNext')) {
				$wizard.FindName($name) | Should Not BeNullOrEmpty
			}
			$wizard.FindName('btnCancel').IsCancel | Should Be $true
			$wizard.FindName('btnNext').IsDefault | Should Be $true
			$wizard.FindName('pnlPasswordRetry').Visibility | Should Be 'Collapsed'
		}
		finally { $wizard.Close() }
	}
}
