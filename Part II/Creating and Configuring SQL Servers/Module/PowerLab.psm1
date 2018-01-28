function New-PowerLabSwitch {
	param(
		[Parameter()]
		[string]$SwitchName = 'PowerLab',

		[Parameter()]
		[string]$SwitchType = 'External'
	)

	if (-not (Get-VmSwitch -Name $SwitchName -SwitchType $SwitchType -ErrorAction SilentlyContinue)) {
		$null = New-VMSwitch -Name $SwitchName -SwitchType $SwitchType
	} else {
		Write-Verbose -Message "The switch [$($SwitchName)] has already been created."
	}
}

function New-PowerLabVm {
	param(
		[Parameter(Mandatory)]
		[string]$Name,

		[Parameter()]
		[string]$Path = 'C:\PowerLab\VMs',

		[Parameter()]
		[string]$Memory = 4GB,

		[Parameter()]
		[string]$Switch = 'PowerLab',

		[Parameter()]
		[ValidateRange(1, 2)]
		[int]$Generation = 2,

		[Parameter()]
		[switch]$PassThru
	)

	if (-not (Get-Vm -Name $Name -ErrorAction SilentlyContinue)) {
		$null = New-VM -Name $Name -Path $Path -MemoryStartupBytes $Memory -Switch $Switch -Generation $Generation
	} else {
		Write-Verbose -Message "The VM [$($Name)] has already been created."
	}
	if ($PassThru.IsPresent) {
		Get-VM -Name $Name
	}
}

function New-PowerLabVhd {
	param
	(
		[Parameter(Mandatory)]
		[string]$Name,

		[Parameter(Mandatory)]
		[string]$AttachToVm,

		[Parameter()]
		[ValidateRange(512MB, 1TB)]
		[int64]$Size = 50GB,

		[Parameter()]
		[ValidateSet('Dynamic', 'Fixed')]
		[string]$Sizing = 'Dynamic',

		[Parameter()]
		[string]$Path = 'C:\PowerLab\VHDs'
	)

	$vhdxFileName = "$Name.vhdx"
	$vhdxFilePath = Join-Path -Path $Path -ChildPath "$Name.vhdx"

	### Ensure we don't try to create a VHD when there's already one there
	if (-not (Test-Path -Path $vhdxFilePath -PathType Leaf)) {
		$params = @{
			SizeBytes = $Size
			Path      = $vhdxFilePath
		}
		if ($Sizing -eq 'Dynamic') {
			$params.Dynamic = $true
		} elseif ($Sizing -eq 'Fixed') {
			$params.Fixed = $true
		}

		New-VHD @params
		Write-Verbose -Message "Created new VHD at path [$($vhdxFilePath)]"
	}

	### Attach either the newly created VHD or the one that was already there to the VM.
	if ($PSBoundParameters.ContainsKey('AttachToVm')) {
		if (-not ($vm = Get-VM -Name $AttachToVm -ErrorAction SilentlyContinue)) {
			Write-Warning -Message "The VM [$($AttachToVm)] does not exist. Unable to attach VHD."
		} elseif (-not ($vm | Get-VMHardDiskDrive | Where-Object { $_.Path -eq $vhdxFilePath })) {
			$vm | Add-VMHardDiskDrive -Path $vhdxFilePath
			Write-Verbose -Message "Attached VHDX [$($vhdxFilePath)] to VM [$($AttachToVM)]."
		} else {
			Write-Verbose -Message "VHDX [$($vhdxFilePath)] already attached to VM [$($AttachToVM)]."
		}
	}
}

function Install-PowerLabOperatingSystem {
	param
	(
		[Parameter(Mandatory)]
		[string]$VmName,

		[Parameter()]
		[string]$OperatingSystem = 'Server 2016',

		[Parameter()]
		[ValidateSet('ServerStandardCore')]
		[string]$OperatingSystemEdition = 'ServerStandardCore',

		[Parameter()]
		[string]$DiskSize = 40GB,

		[Parameter()]
		[string]$VhdFormat = 'VHDX',

		[Parameter()]
		[string]$VhdType = 'Dynamic',

		[Parameter()]
		[string]$VhdPartitionStyle = 'GPT',

		[Parameter()]
		[string]$VhdBaseFolderPath = 'C:\PowerLab\VHDs',

		[Parameter()]
		[string]$IsoBaseFolderPath = 'C:\PowerLab\ISOs',

		[Parameter()]
		[string]$VhdPath
	)
	
	## Assuming we have multiple unattend XML files in this folder named <VMName>.xml
	$answerFile = Get-Item -Path "$PSScriptRoot\$VMName.xml"

	## Dot-source the script. Since the script has a function, doing this will make the function inside the script available
	. "$PSScriptRoot\Convert-WindowsImage.ps1"

	## Here is where we could add mulitple OS support picking the right ISO depending on the OS version chosen
	switch ($OperatingSystem) {
		'Server 2016' {
			$isoFilePath = "$IsoBaseFolderPath\en_windows_server_2016_x64_dvd_9718492.iso"
		}
		default {
			throw "Unrecognized input: [$_]"
		}
	}

	$convertParams = @{
		SourcePath        = $isoFilePath
		SizeBytes         = $DiskSize
		Edition           = $OperatingSystemEdition
		VHDFormat         = $VhdFormat
		VHDType           = $VhdType
		VHDPartitionStyle = 'GPT'
		UnattendPath      = $answerFile.FullName
	}
	if ($PSBoundParameters.ContainsKey('VhdPath')) {
		$convertParams.VHDPath = $VhdPath
	} else {
		$convertParams.VHDPath = "$VhdBaseFolderPath\$VMName.vhdx"
	}

	Convert-WindowsImage @convertParams

	$vm = Get-Vm -Name $VmName
	$vm | Add-VMHardDiskDrive -Path $convertParams.VHDPath
	$bootOrder = ($vm | Get-VMFirmware).Bootorder
	if ($bootOrder[0].BootType -ne 'Drive') {
		$vm | Set-VMFirmware -FirstBootDevice $vm.HardDrives[0]
	}
}

function New-PowerLabActiveDirectoryTestObject {
	param(
		[Parameter(Mandatory)]
		[string]$SpreadsheetPath
	)

	$users = Import-Excel -Path $SpreadsheetPath -WorksheetName Users
	$groups = Import-Excel -Path $SpreadsheetPath -WorksheetName Groups

	$cred = Import-CliXml -Path 'C:\PowerLab\DomainCredential.xml'
	$dcSession = New-PSSession -VMName LABDC -Credential $cred

	$scriptBlock = {
		foreach ($group in $using:groups) {
			if (-not (Get-AdOrganizationalUnit -Filter "Name -eq '$($group.OUName)'")) {
				New-AdOrganizationalUnit -Name $group.OUName
			}
			if (-not (Get-AdGroup -Filter "Name -eq '$($group.GroupName)'")) {
				New-AdGroup -Name $group.GroupName -GroupScope $group.Type -Path "OU=$($group.OUName),DC=powerlab,DC=local"
			}
		}

		foreach ($user in $using:users) {
			if (-not (Get-AdOrganizationalUnit -Filter "Name -eq '$($user.OUName)'")) {
				New-AdOrganizationalUnit -Name $user.OUName
			}
			if (-not (Get-AdUser -Filter "Name -eq '$($user.UserName)'")) {
				New-AdUser -Name $user.UserName -Path "OU=$($user.OUName),DC=powerlab,DC=local"
			}
			if ($user.UserName -notin (Get-AdGroupMember -Identity $user.MemberOf).Name) {
				Add-AdGroupMember -Identity $user.MemberOf -Members $user.UserName
			}
		}
	}

	Invoke-Command -Session $dcSession -ScriptBlock $scriptBlock
	$dcSession | Remove-PSSession
}

function New-PowerLabActiveDirectoryForest {
	param(
		[Parameter(Mandatory)]
		[pscredential]$Credential,

		[Parameter(Mandatory)]
		[string]$SafeModePassword,

		[Parameter()]
		[string]$VMName = 'LABDC',

		[Parameter()]
		[string]$DomainName = 'powerlab.local',

		[Parameter()]
		[string]$DomainMode = 'WinThreshold',

		[Parameter()]
		[string]$ForestMode = 'WinThreshold'
	)

	Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {

		Install-windowsfeature -Name AD-Domain-Services
		
		$forestParams = @{
			DomainName                    = $using:DomainName
			DomainMode                    = $using:DomainMode
			ForestMode                    = $using:ForestMode
			Confirm                       = $false
			SafeModeAdministratorPassword = (ConvertTo-SecureString -AsPlainText -String $using:SafeModePassword -Force)
			WarningAction                 = 'Ignore'
		}
		$null = Install-ADDSForest @forestParams
	}
}

function Test-PowerLabActiveDirectoryForest {
	param(
		[Parameter(Mandatory)]
		[pscredential]$Credential,

		[Parameter()]
		[string]$VMName = 'LABDC'
	)

	Invoke-Command -Credential $Credential -ScriptBlock { Get-AdUser -Filter * }
}

function New-PowerLabSqlServer {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	param
	(
		[Parameter(Mandatory)]
		[hashtable]$NewVMParameters,

		[Parameter(Mandatory, ParameterSetName = 'AddToDomain')]
		[switch]$AddToDomain,

		[Parameter(ParameterSetName = 'AddToDomain')]
		[string]$DomainName = 'powerlab.local',

		[Parameter(Mandatory, ParameterSetName = 'AddToDomain')]
		[pscredential]$DomainCredential
	)

	## Build the VM
	$vmparams = @{ 
		Name       = $NewVMParameters.Name
		Path       = $NewVMParameters.Path
		Memory     = $NewVMParameters.Memory
		Switch     = $NewVMParameters.SwitchName
		Generation = $NewVMParameters.Generation
	}
	New-PowerLabVm @vmParams
	Install-PowerLabSqlServer -ComputerName $NewVMParameters.Name

	if ($AddToDomain.IsPresent) {
		$addParams = @{
			ComputerName = $NewVMParameters.Name
			DomainName   = $DomainName
			Credential   = $DomainCredential
			Restart      = $true
			Force        = $true
		}
		Add-Computer @addParams
	}
}

function Install-PowerLabSqlServer {
	param
	(
		[Parameter(Mandatory)]
		[string]$ComputerName,

		[Parameter(Mandatory)]
		[pscredential]$DomainCredential,

		[Parameter()]
		[ValidateNotNullOrEmpty()]
		[string]$IsoFilePath = 'C:\PowerLab\ISOs\en_sql_server_2016_standard_x64_dvd_8701871.iso'
	)

	try {
		## Create a PowerShell Direct session to copy files from host server to VM
		Write-Verbose -Message "Creating a new PSSession to [$($ComputerName)]..."
		$session = New-PSSession -VMName $ComputerName -Credential $DomainCredential

		$sqlServerAnswerFilePath = "$PSScriptRoot\SqlServer.ini"

		## Make a temporary copy of the template
		Write-Verbose -Message 'Creating temporary SQL Server answer file...'
		$tempFile = Copy-Item -Path $sqlServerAnswerFilePath -Destination "$PSScriptRoot\temp.ini" -PassThru
		
		## Set all of your specific values in the temp answer file
		$sqlServerAnswerFileContents = PrepareSqlServerInstallConfigFile -Path $tempFile.FullName
		Set-Content -Path $tempFile.FullName -Value $sqlServerAnswerFileContents

		## Copy the SQL server config ini to the VM
		Write-Verbose -Message 'Copying SQL server answer file to VM...'
		$copyParams = @{
			Path        = $tempFile.FullName
			Destination = 'C:\'
			VMName      = $ComputerName
			PassThru    = $true
		}
		$copiedConfigFile = Copy-Item @copyParams
		
		## Remove the temp file
		Remove-Item -Path $tempFile.FullName -ErrorAction Ignore
	
		## Copy the ISO to the VM
		Write-Verbose -Message 'Copying SQL server ISO to VM...'
		$copiedIso = Copy-Item -Path $IsoFilePath -Destination 'C:\' -Force -ToSession $session -PassThru
	
		## Execute the installer
		Write-Verbose -Message 'Running SQL Server installer...'
		$icmParams = @{
			VMName       = $ComputerName
			ArgumentList = $copiedConfigFile.FullName, $copiedIso.FullName
			ScriptBlock  = {
				$image = Mount-DiskImage -ImagePath $args[1] -PassThru
				$installerPath = "$(($image | Get-Volume).DriveLetter):"
				$null = & "$installerPath\setup.exe" "/CONFIGURATIONFILE=$($args[0])"
				$image | Dismount-DiskImage
			}
		}
		Invoke-Command @icmParams
	} catch {
		$PSCmdlet.ThrowTerminatingError($_)
	} finally {
		Write-Verbose -Message 'Cleaning up installer remnants...'
		$scriptBlock = { Remove-Item -Path $copiedIso.FullName $using:copiedConfigFile.FullName -Recurse -ErrorAction Ignore }
		Invoke-Command -VMName $ComputerName -ScriptBlock $scriptBlock -Session $session
		$session | Remove-PSSession
	}
}

function PrepareSqlServerInstallConfigFile {
	[CmdletBinding()]
	param
	(
		[Parameter(Mandatory)]
		[string]$Path,

		[Parameter()]
		[string]$ServiceAccountName = 'PowerLabUser',

		[Parameter()]
		[string]$ServiceAccountPassword = 'P@$$w0rd12',

		[Parameter()]
		[string]$SysAdminAcountName = 'P@$$w0rd12'
	)

	$configContents = Get-Content -Path $Path -Raw
	$configContents = $configContents.Replace('SQLSVCACCOUNT=""', ('SQLSVCACCOUNT="{0}"' -f $ServiceAccountName))
	$configContents = $configContents.Replace('SQLSVCPASSWORD=""', ('SQLSVCPASSWORD="{0}"' -f $ServiceAccountPassword))
	$configContents.Replace('SQLSYSADMINACCOUNTS=""', ('SQLSYSADMINACCOUNTS="{0}"' -f $SysAdminAcountName))
}