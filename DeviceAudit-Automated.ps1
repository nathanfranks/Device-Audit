param(
	$companies = @(),
	[switch]$ForceMonthlyUsageRollup
)
#####################################################################
### Run this with a single argument
### The argument should either be the company's acronym (referencing a config file)
### or "ALL" which will audit every company there is a config file for
### You can also list multiple companies to target a few specific ones
### e.g. DeviceAudit-Automated.ps1 -companies STS, AVA, MV  # (note the companies flag is optional)
###
### Make sure there is a config file for the company under the "Config Files/" folder
### See the main Device Audit script for more info
###

. "$PSScriptRoot\Config Files\APIKeys.ps1" # API Keys
. "$PSScriptRoot\Config Files\Global-Config.ps1" # Global Config
#####################################################################

# Setup logging
If (Get-Module -ListAvailable -Name "PSFramework") {Import-module PSFramework} Else { install-module PSFramework -Force; import-module PSFramework}
$logFile = Join-Path -path "$PSScriptRoot\ErrorLogs" -ChildPath "log-$(Get-date -f 'yyyyMMddHHmmss').txt";
Set-PSFLoggingProvider -Name logfile -FilePath $logFile -Enabled $true;

Write-PSFMessage -Level Verbose -Message "Starting audit on: $($companies | ConvertTo-Json)"
$CompaniesToAudit = [System.Collections.Generic.List[string]]::new();
if ($companies -contains "ALL") {
	$CompaniesToAudit = (Get-ChildItem "$PSScriptRoot\Config Files\" | Where-Object { $_.PSIsContainer -eq $false -and $_.Extension -eq '.ps1' -and $_.Name -like "Config-*" }).Name
} else {
	foreach ($CompanyConfig in $companies) {
		if ($CompanyConfig -like "Config-*") {
			$ConfigFile = $CompanyConfig
		} else {
			$ConfigFile = "Config-$CompanyConfig"
		}

		if ($ConfigFile -notlike "*.ps1") {
			$ConfigFile = "$ConfigFile.ps1"
		}

		if (Test-Path -Path "$PSScriptRoot\Config Files\$ConfigFile") {
			$CompaniesToAudit.Add($ConfigFile)
		}
	}
}

if ($CompaniesToAudit.Count -eq 0) {
	Write-Warning "No configuration files were found. Exiting!"
	Write-PSFMessage -Level Warning -Message "No configuration files found."
	if ($companies.count -eq 0) {
		Write-Warning "Please try again using the 'companies' argument.  e.g. DeviceAudit-Automated.ps1 -companies STS, AVA, MV"
	} else {
		Write-Warning "Please try again. The 'companies' argument did not seem to map to a valid config file."
	}
	exit
}

Write-Output "Computer audit starting..."

### This code is common for every company and can be ran before looping through multiple companies
$CurrentTLS = [System.Net.ServicePointManager]::SecurityProtocol
if ($CurrentTLS -notlike "*Tls12" -and $CurrentTLS -notlike "*Tls13") {
	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
	Write-Output "This device is using an old version of TLS. Temporarily changed to use TLS v1.2."
	Write-PSFMessage -Level Warning -Message "Temporarily changed TLS to TLS v1.2."
}

# Import/Install any required modules
If (Get-Module -ListAvailable -Name "ImportExcel") {Import-module ImportExcel} Else { install-module ImportExcel -Force; import-module ImportExcel}
If (Get-Module -ListAvailable -Name "Az.Accounts") {Import-module Az.Accounts } Else { install-module Az.Accounts  -Force; import-module Az.Accounts }
If (Get-Module -ListAvailable -Name "Az.Resources") {Import-module Az.Resources } Else { install-module Az.Resources  -Force; import-module Az.Resources }
If (Get-Module -ListAvailable -Name "Microsoft.Graph.Authentication") {Import-module Microsoft.Graph.Authentication -Force} Else { install-module Microsoft.Graph -Force; import-module Microsoft.Graph.Authentication -Force}
If (Get-Module -ListAvailable -Name "Microsoft.Graph.Identity.DirectoryManagement") {Import-module Microsoft.Graph.Identity.DirectoryManagement -Force}
If (Get-Module -ListAvailable -Name "Microsoft.Graph.DeviceManagement") {Import-module Microsoft.Graph.DeviceManagement -Force}
If (Get-Module -ListAvailable -Name "CosmosDB") {Import-module CosmosDB } Else { install-module CosmosDB  -Force; import-module CosmosDB }
If (Get-Module -ListAvailable -Name "DattoRMM") {Import-module DattoRMM -Force} Else { install-module DattoRMM -Force; import-module DattoRMM -Force}
If (Get-Module -ListAvailable -Name "ITGlueAPI") {Import-module ITGlueAPI -Force} Else { install-module ITGlueAPI -Force; import-module ITGlueAPI -Force}
If (Get-Module -ListAvailable -Name "AutotaskAPI") {Import-module AutotaskAPI -Force} Else { install-module AutotaskAPI -Force; import-module AutotaskAPI -Force}
If (Get-Module -ListAvailable -Name "JumpCloud") {Import-module JumpCloud -Force} Else { install-module JumpCloud -Force; import-module JumpCloud -Force}
If (Get-Module -ListAvailable -Name "Subnet") {Import-module Subnet -Force} Else { install-module Subnet -Force; import-module Subnet -Force}

if ($Ninite_Login.MFA_Secret) {
	Unblock-File -Path "$PSScriptRoot\GoogleAuthenticator.psm1"
	Import-Module "$PSScriptRoot\GoogleAuthenticator.psm1"
}

# Connect to Azure
if (Test-Path "$PSScriptRoot\Config Files\AzureServiceAccount.json") {
	$LastUpdatedAzureCreds = (Get-Item "$PSScriptRoot\Config Files\AzureServiceAccount.json").LastWriteTime
	if ($LastUpdatedAzureCreds -lt (Get-Date).AddMonths(-3)) {
		Write-PSFMessage -Level Error -Message "Azure credentials are out of date. Please run Connect-AzAccount to set up your Azure credentials."
		# Send an email alert
		$mailbody = @{
			"From" = $EmailFrom
			"To" = $EmailTo_FailedFixes
			"Subject" = "Device Audit - Azure Credentials need updating"
			"TextContent" = "The Azure credentials are out of date on $env:computername. Please run Connect-AzAccount to set up your Azure credentials."
		} | ConvertTo-Json -Depth 6

		$headers = @{
			'x-api-key' = $Email_APIKey.Key
		}
		Invoke-RestMethod -Method Post -Uri $Email_APIKey.Url -Body $mailbody -Headers $headers -ContentType application/json
		exit
	}

	try {
		Import-AzContext -Path "$PSScriptRoot\Config Files\AzureServiceAccount.json"
	} catch {
		Write-PSFMessage -Level Error -Message "Failed to connect to: Azure"
	}
} else {
	Connect-AzAccount
	Save-AzContext -Path "$PSScriptRoot\Config Files\AzureServiceAccount.json" -Force
}

# Get CPU data and Download new CPU data if older than 2 weeks
if ($CPUDataLocation -and (Test-Path -Path ($CPUDataLocation + "\lastUpdated.txt"))) {
	$CPUDataLastUpdated = Get-Content -Path ($CPUDataLocation + "\lastUpdated.txt") -Raw
	if ([string]$CPUDataLastUpdated -as [DateTime])   {
		$CPUDataLastUpdated = Get-Date $CPUDataLastUpdated
	} else {
		$CPUDataLastUpdated = $false
	}
}

if ($CPUDataLocation -and (Test-Path -Path ($CPUDataLocation + "\cpus.json"))) {
	$CPUDetails = Get-Content -Path ($CPUDataLocation + "\cpus.json") -Raw | ConvertFrom-Json
} else {
	$CPUDetails = @()
}

if ($CPUDataLocation -and (Test-Path -Path ($CPUDataLocation + "\cpu_matching.json"))) {
	$CPUMatching = Get-Content -Path ($CPUDataLocation + "\cpu_matching.json") -Raw | ConvertFrom-Json
} else {
	$CPUMatching = @()
}

if ($CPUDataLastUpdated -and $CPUDataLastUpdated.AddDays(14) -lt (Get-Date)) {
	$NewCPUList = [System.Collections.ArrayList]@()
	$UpdateSuccessful = $true
	$headers=@{}
	$headers.Add("X-RapidAPI-Host", $RapidAPI_Creds.Host)
	$headers.Add("X-RapidAPI-Key", $RapidAPI_Creds.Key)

	foreach ($CPUName in $CPUNameSearch) {
		try {
			$response = Invoke-RestMethod -Uri "https://$($RapidAPI_Creds.Host)/cpus/search/?name=$($CPUName)" -Method GET -Headers $headers
		} catch {
			if ($_.Exception.Response.StatusCode.value__ -eq 503) {
				$UpdateSuccessful = $false
				break;
			}
		}
		$response | Foreach-Object { $NewCPUList.Add($_) } | Out-Null
		Start-Sleep -Seconds 2 # we are rate limited to 1 call per second
	}

	if ($UpdateSuccessful -or ($NewCPUList | Measure-Object).Count -gt 0) {
		(Get-Date).ToString() | Out-File -FilePath ($CPUDataLocation + "\lastUpdated.txt")

		if ($CPUDetails -and $CPUDetails.ID) {
			$CPUDetails = [System.Collections.ArrayList]@($CPUDetails)
			foreach ($NewCPU in $NewCPUList) {
				if ($NewCPU.ID -in $CPUDetails.ID) {
					$OldCPUEntry = $CPUDetails | Where-Object { $_.ID -eq $NewCPU.ID }
					if ($OldCPUEntry.CPUMark -ne $NewCPU.CPUMark) {
						($CPUDetails | Where-Object { $_.ID -eq $NewCPU.ID }).CPUMark = $NewCPU.CPUMark
					}
				} else {
					$CPUDetails.Add($NewCPU) 
				}
			}
		} else {
			$CPUDetails = $NewCPUList
		}

		$CPUDetails = $CPUDetails | Sort-Object -Unique -Property ID
		$CPUDetails | ConvertTo-Json | Out-File -FilePath ($CPUDataLocation + "\cpus.json")
	}
}

$CPUDetailsHash = @{}
foreach ($CPU in $CPUDetails) { 
	$CPUDetailsHash[$CPU.ID] = $CPU
}

# Connect to IT Glue
$ITGConnected = $false
if ($ITGAPIKey.Key) {
	Add-ITGlueBaseURI -base_uri $ITGAPIKey.Url
	Add-ITGlueAPIKey $ITGAPIKey.Key
	$WANFilterID = (Get-ITGlueFlexibleAssetTypes -filter_name $WANFlexAssetName).data
	$LANFilterID = (Get-ITGlueFlexibleAssetTypes -filter_name $LANFlexAssetName).data
	$OverviewFilterID = (Get-ITGlueFlexibleAssetTypes -filter_name $OverviewFlexAssetName).data
	$ScriptsLastRunFilterID = (Get-ITGlueFlexibleAssetTypes -filter_name $ScriptsLastRunFlexAssetName).data
	$ITGConnected = $true

	if (!$WANFilterID -or !$LANFilterID -or !$OverviewFilterID) {
		Write-PSFMessage -Level Error -Message "Could not get all of the flex asset filter id's from ITG. Exiting..."
		exit 1
	}
}

# Connect to Autotask
$AutotaskConnected = $false
if ($AutotaskAPIKey.Key) {
	$Secret = ConvertTo-SecureString $AutotaskAPIKey.Key -AsPlainText -Force
	$Creds = New-Object System.Management.Automation.PSCredential($AutotaskAPIKey.Username, $Secret)
	Add-AutotaskAPIAuth -ApiIntegrationcode $AutotaskAPIKey.IntegrationCode -credentials $Creds
	Add-AutotaskBaseURI -BaseURI $AutotaskAPIKey.Url
	
	# Verify the Autotask API key works
	$AutotaskConnected = $true
	try { 
		Get-AutotaskAPIResource -Resource Companies -ID 0 -ErrorAction Stop 
		Write-PSFMessage -Level Verbose -Message "Successfully connected to Autotask."
	} catch { 
		$CleanError = ($_ -split "/n")[0]
		if ($_ -like "*(401) Unauthorized*") {
			$CleanError = "API Key Unauthorized. ($($CleanError))"
		}
		Write-Host $CleanError -ForegroundColor Red
		Write-PSFMessage -Level Error -Message $CleanError
		$AutotaskConnected = $false
	}
}

# Connect to Sophos
$SophosTenantID = $false
$SophosGetTokenBody = @{
	grant_type = "client_credentials"
	client_id = $SophosAPIKey.ClientID
	client_secret = $SophosAPIKey.Secret
	scope = "token"
}
$SophosToken = Invoke-RestMethod -Method POST -Body $SophosGetTokenBody -ContentType "application/x-www-form-urlencoded" -uri "https://id.sophos.com/api/v2/oauth2/token"
$SophosJWT = $SophosToken.access_token
$SophosToken | Add-Member -NotePropertyName expiry -NotePropertyValue $null
$SophosToken.expiry = (Get-Date).AddSeconds($SophosToken.expires_in - 60)

if ($SophosJWT) {
	# Get our partner ID
	$SophosHeader = @{
		Authorization = "Bearer $SophosJWT"
	}
	$SophosPartnerInfo = Invoke-RestMethod -Method GET -Headers $SophosHeader -uri "https://api.central.sophos.com/whoami/v1"
	$SophosPartnerID = $SophosPartnerInfo.id

	if ($SophosPartnerID) {
		# Get list of tenants, so we can get the companies ID in sophos
		$SophosHeader = @{
			Authorization = "Bearer $SophosJWT"
			"X-Partner-ID" = $SophosPartnerID
		}
		$SophosTenants = Invoke-RestMethod -Method GET -Headers $SophosHeader -uri "https://api.central.sophos.com/partner/v1/tenants?pageTotal=true"

		if ($SophosTenants.pages -and $SophosTenants.pages.total -gt 1) {
			$TotalPages = $SophosTenants.pages.total
			for ($i = 2; $i -le $TotalPages; $i++) {
				$SophosTenants.items += (Invoke-RestMethod -Method GET -Headers $SophosHeader -uri "https://api.central.sophos.com/partner/v1/tenants?page=$i").items
			}
		} else {
			Write-PSFMessage -Level Error -Message "Failed to connect to: Sophos (No Tenants Found)"
		}
	} else {
		Write-PSFMessage -Level Error -Message "Failed to connect to: Sophos (No Partner ID)"
	}
} else {
	Write-PSFMessage -Level Error -Message "Failed to connect to: Sophos (No JWT)"
}

# Authenticate with Ninite
$NiniteAuthResponse = $false
if ($Ninite_Login.Email) {
	# Try to auth with Ninite
	$attempt = 3
	while ($attempt -ge 0 -and !$NiniteAuthResponse) {
		if ($attempt -eq 0) {
			# Already tried 10x, lets give up
			Write-PSFMessage -Level Error -Message "Could not authenticate with Ninite. Please verify the credentials and try again."
		}

		# Get the xsrf token from the form
		$NiniteSignInPage = Invoke-WebRequest "$($Ninite_Login.BaseURI)signin/" -SessionVariable 'NiniteWebSession'
		$XSRFToken = ($NiniteSignInPage.InputFields | Where-Object { $_.name -eq "_xsrf" }).value

		if (!$XSRFToken) {
			Write-Host "Failed to get the XSRF token for Ninite. Retrying..."
			Start-Sleep -Seconds 2
			continue
		}

		if ($XSRFToken) {
			# Attempt initial login
			$FormBody = @{
				email = $Ninite_Login.Email
				pw = $Ninite_Login.Password
				"_xsrf" = $XSRFToken
			}

			try {
				$NiniteAuthResponse = Invoke-WebRequest "$($Ninite_Login.BaseURI)signin/" -WebSession $NiniteWebSession -Body $FormBody -Method 'POST' -ContentType 'application/x-www-form-urlencoded'
			} catch {
				$attempt--
				Write-Host "Failed to connect to: Ninite"
				Write-Host "Status Code: $($_.Exception.Response.StatusCode.Value__)"
				Write-Host "Message: $($_.Exception.Message)"
				Write-Host "Status Description: $($_.Exception.Response.StatusDescription)"
				start-sleep (get-random -Minimum 10 -Maximum 100)
				continue
			}
		}

		if ($NiniteAuthResponse.Content -like "*Please enter the current two-factor code*") {
			if ($Ninite_Login.MFA_Secret -and $Ninite_Login.MFA_Method -eq "totp") {
				$MFACode = Get-GoogleAuthenticatorPin -Secret $Ninite_Login.MFA_Secret
				if ($MFACode.'Seconds Remaining' -le 5) {
					# If the current code is about to expire, lets wait until a new one is ready to be generated to grab the code and try to login
					Start-Sleep -Seconds ($MFACode.'Seconds Remaining' + 1)
					$MFACode = Get-GoogleAuthenticatorPin -Secret $Ninite_Login.MFA_Secret
				}

				$FormBody = @{
					totp = $MFACode."PIN Code" -replace " ", ""
					method = "totp"
					"_xsrf" = $XSRFToken
				}

				try {
					$NiniteAuthResponse = Invoke-WebRequest "$($Ninite_Login.BaseURI)me/2fa/challenge" -WebSession $NiniteWebSession -Body $FormBody -Method 'POST' -ContentType 'application/x-www-form-urlencoded'
				} catch {
					$attempt--
					Write-Host "Failed to connect to: Ninite"
					Write-Host "Status Code: $($_.Exception.Response.StatusCode.Value__)"
					Write-Host "Message: $($_.Exception.Message)"
					Write-Host "Status Description: $($_.Exception.Response.StatusDescription)"
					start-sleep (get-random -Minimum 10 -Maximum 100)
					continue
				}

			} elseif (!$Ninite_Login.MFA_Secret) {
				Write-PSFMessage -Level Error -Message "An MFA secret is required for the Ninite login. Could not authenticate. Please verify the credentials and try again."
				break
			} elseif ($Ninite_Login.MFA_Method -ne "totp") {
				Write-PSFMessage -Level Error -Message "Please setup Ninite with the TOTP MFA type. This script does not support other versions of MFA."
				break
			}
		}

		if (!$NiniteAuthResponse) {
			$attempt--
			Write-Host "Failed to connect to: Ninite"
			start-sleep (get-random -Minimum 10 -Maximum 100)
			continue
		}
	}
}

# Get all devices from SC
$attempt = 10
while ($attempt -ge 0) {
	if ($attempt -eq 0) {
		# Already tried 10x, lets give up and exit the script
		Write-PSFMessage -Level Error -Message "Could not get device list from ScreenConnect. Exiting..."
		exit
	}

	# Send a post request to $SCLogin.URL/Services/AuthenticationService.ashx/TryLogin
	# to set the login cookie
	$Nonce = $SC_Nonce # Manually obtained from SC.util.getRandomAlphanumericString(16);  (it just seems to care that the format is correct)
	$FormBody = @(
		$SCLogin.Username,
		$SCLogin.Password,
		$false,
		$false,
		$Nonce
	) | ConvertTo-Json

	try {
		$AuthResponse = Invoke-WebRequest "$($SCLogin.URL)/Services/AuthenticationService.ashx/TryLogin" -SessionVariable 'SCWebSession' -Body $FormBody -Method 'POST' -ContentType 'application/json'
	} catch {
		$attempt--
		Write-PSFMessage -Level Error -Message "Failed to connect to: ScreenConnect"
		Write-PSFMessage -Level Error -Message "Status Code: $($_.Exception.Response.StatusCode.Value__)"
		Write-PSFMessage -Level Error -Message "Message: $($_.Exception.Message)"
		Write-PSFMessage -Level Error -Message "Status Description: $($_.Exception.Response.StatusDescription)"
		Write-PSFMessage -Level Error -Message "URL attempted: $($SCLogin.URL)/Services/AuthenticationService.ashx/TryLogin"
		Write-PSFMessage -Level Error -Message "Username used: $($SCLogin.Username)"
		start-sleep (get-random -Minimum 10 -Maximum 100)
		continue
	}
	if (!$AuthResponse) {
		$attempt--
		Write-PSFMessage -Level Error -Message "Failed to connect to: ScreenConnect"
		start-sleep (get-random -Minimum 10 -Maximum 100)
		continue
	}

	# Download the full device list report and then import it
	$Response = Invoke-WebRequest "$($SCLogin.URL)/Report.csv?ReportType=Session&SelectFields=SessionID&SelectFields=Name&SelectFields=GuestMachineName&SelectFields=GuestMachineSerialNumber&SelectFields=GuestHardwareNetworkAddress&SelectFields=GuestOperatingSystemName&SelectFields=GuestLastActivityTime&SelectFields=GuestInfoUpdateTime&SelectFields=GuestLastBootTime&SelectFields=GuestLoggedOnUserName&SelectFields=GuestLoggedOnUserDomain&SelectFields=GuestMachineManufacturerName&SelectFields=GuestMachineModel&SelectFields=GuestMachineDescription&SelectFields=CustomProperty1&SelectFields=GuestSystemMemoryTotalMegabytes&SelectFields=GuestProcessorName&SelectFields=GuestProcessorVirtualCount&Filter=SessionType%20%3D%20'Access'%20AND%20NOT%20IsEnded&AggregateFilter=&ItemLimit=100000" -WebSession $SCWebSession
	$SC_Devices_Full = $Response.Content | ConvertFrom-Csv

	# If bad results
	if (($Response.Headers.Keys.Contains("P3P") -and $Response.Headers.P3P -like "*NON CUR OUR STP STA PRE*") -or 
		$Response.Headers.'Content-Type' -like "text/html;*" -or 
		$SC_Devices_Full[0].PSObject.Properties.Name.Count -le 1 -or 
		$SC_Devices_Full[0].PSObject.Properties.Name -contains "H1") 
	{
		$attempt--
		Write-PSFMessage -Level Error -Message "Failed to get: Device List from ScreenConnect"
		Write-PSFMessage -Level Error -Message "StatusCode: $($Response.StatusCode)"
		Write-PSFMessage -Level Error -Message "Message: $($_.Exception.Message)"
		Write-PSFMessage -Level Error -Message "StatusDescription: $($Response.StatusDescription)"

		Write-PSFMessage -Level Error -Message "Headers: $($Response.Headers | ConvertTo-Json)"
		Write-PSFMessage -Level Error -Message "Auth Content: $($AuthResponse.RawContent)"
		Write-PSFMessage -Level Error -Message "Auth Headers: $($AuthResponse.Headers)"
		Write-PSFMessage -Level Error -Message "BaseResponse: $($Response.BaseResponse | ConvertTo-Json)"

		start-sleep (get-random -Minimum 10 -Maximum 100)
		continue
	} else {
		# Success
		Write-PSFMessage -Level Verbose -Message "Successfully got $($SC_Devices_Full.Length) devices from ScreenConnect."
		break
	}
}

# Get org info and devices from Ninite
$Ninite_Machines = @()
if ($NiniteAuthResponse) {
	$NiniteHeader = @{
		"x-xsrftoken" = $XSRFToken
		"ninite-role" = 0
	}
	$FormBody = @{
		id = 1
		jsonrpc = "2.0"
		method = "get_org_info"
		params = @{}
	} | ConvertTo-Json

	$NiniteResponse = Invoke-WebRequest "$($Ninite_Login.BaseURI)remote/rpc_web" -WebSession $NiniteWebSession -Headers $NiniteHeader -Body $FormBody -Method 'POST' -ContentType 'application/json; charset=utf-8'
	$Ninite_OrgInfo = $NiniteResponse.Content | ConvertFrom-Json


	$TotalNiniteDevices = $Ninite_OrgInfo.result.machine_ids.count
	for ($i = 0; $i -lt [Math]::Ceiling($TotalNiniteDevices / 500); $i++) {
		$StartIndex = $i * 500
		$EndIndex = ($i+1) * 500 - 1

		$FormBody = @{
			id = 1
			jsonrpc = "2.0"
			method = "get_machines"
			params = @{
				machine_ids = @($Ninite_OrgInfo.result.machine_ids[$StartIndex..$EndIndex])
			}
		} | ConvertTo-Json

		$NiniteResponse = Invoke-WebRequest "$($Ninite_Login.BaseURI)remote/rpc_web" -WebSession $NiniteWebSession -Headers $NiniteHeader -Body $FormBody -Method 'POST' -ContentType 'application/json; charset=utf-8'
		$Ninite_Machines += ($NiniteResponse.Content | ConvertFrom-Json).result
		Start-Sleep -Seconds 1
	}
}

$Ninite_DevicesHash = @{}
foreach ($Device in $Ninite_Machines) { 
	$Ninite_DevicesHash[$Device.id] = $Device
}

#################
# Functions (the 'if' just allows me to collapse them all)
#################
if ($true) {

	# Function to convert imported UTC date/times to local time for easier comparisons
	function Convert-UTCtoLocal {
		param( [parameter(Mandatory=$true)] [String] $UTCTime )
		$strCurrentTimeZone = (Get-WmiObject win32_timezone).StandardName 
		$TZ = [System.TimeZoneInfo]::FindSystemTimeZoneById($strCurrentTimeZone) 
		$LocalTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($UTCTime, $TZ)
		return $LocalTime
	}

	# The id on each Sophos device is not the same ID that is used on the website
	# To get this ID, we must invert each pair of characters in the ID
	function convert_sophos_id_to_web($EndpointID) {
		$WebEndpointID = ""
		$Length = $EndpointID.length
		
		for ($i = 0; $i -lt $Length; $i ++) {
			if ($EndpointID[$i] -eq "-") {
				$WebEndpointID += "-"
				continue
			}
			$WebEndpointID += $EndpointID[$i+1]
			$WebEndpointID += $EndpointID[$i]
			$i++
		}

		return $WebEndpointID
	}

	# This function checks the force match array for any forced matches and returns them
	# Input the device ID and the $Type of connection (SC, RMM, Sophos, or ITG)
	# Returns an array containing hashtables for each match with the matching connections type, and device id, and if we want to match with this id or ignore this id
	# @( @{"type" = "sc, rmm, sophos, or itg", "id" = "device id or $false for no match", "match" = $true if we want to match to this ID, $false if we want to block matches with this id } )
	function force_match($DeviceID, $Type) {
		$Types = @("SC", "RMM", "Sophos", "ITG")
		if (!$Type -or $Type -notin $Types) {
			return
		}

		$ForcedMatches = @()
		foreach ($DefaultType in $Types) {
			# For each entry in the type we are getting, get all by from id
			if ($DefaultType -like $Type) {
				foreach ($Match in $ForceMatch.$Type) {
					# Check if id matches, if this is a sophos match, see if the inverted id matches as well
					if ($Match.from -like $DeviceID -or (($Match.tosystem -like "Sophos" -or $DefaultType -like "Sophos") -and (convert_sophos_id_to_web $Match.from) -like $DeviceID)) {
						$ForcedMatches += @{
							type = $Match.tosystem
							id = $Match.to
							match = [bool]$Match.to
						}
					}
				}
			# For each entry in other types, get all by to id
			} else {
				foreach ($Match in $ForceMatch.$DefaultType) {
					if ($Match.tosystem -like $Type -and ($Match.to -like $DeviceID -or $Match.to -eq $false -or (($Match.tosystem -like "Sophos" -or $DefaultType -like "Sophos") -and (convert_sophos_id_to_web $Match.to) -like $DeviceID))) {
						$ForcedMatches += @{
							type = $DefaultType
							id = $Match.from
							match = [bool]$Match.to
						}
					}
				}
			}
		}

		# Convert and add a new entry for any sophos ids into their web id equivalent as well (sophos uses inverted ids on their website which is most likely what will be entered in the $ForceMatches section)
		$ForcedMatchesCopy = $ForcedMatches
		foreach ($Match in $ForcedMatchesCopy) {
			if ($Match.type -like "Sophos" -and $Match.id) {
				$ForcedMatches += @{
					type = $Match.type
					id = convert_sophos_id_to_web $Match.id
					match = $Match.match
				}
			}
		}

		return $ForcedMatches
	}

	# Function for logging automated changes (installs, deletions, etc.)
	# $ServiceTarget is 'rmm', 'sc', 'sophos', 'jc', 'ninite', 'itg', or 'autotask'
	function log_change($Company_Acronym, $ServiceTarget, $RMM_Device_ID, $SC_Device_ID, $Sophos_Device_ID, $JC_Device_ID = $false, $Ninite_Device_ID = $false, $ChangeType, $Hostname = "", $Reason = "") {
		if (!$LogLocation) {
			return $false
		}
		if (!(Test-Path -Path $LogLocation)) {
			New-Item -ItemType Directory -Force -Path $LogLocation | Out-Null
		}
	
		$Now = [int](New-TimeSpan -Start (Get-Date "01/01/1970") -End (Get-Date).ToUniversalTime()).TotalSeconds
		$LogFilePath = "$($LogLocation)\$($Company_Acronym)_log.json"
		if (Test-Path $LogFilePath) {
			$LogData = Get-Content -Path $LogFilePath -Raw | ConvertFrom-Json
			if ($LogData.GetType().BaseType -ne "System.Array") {
				$LogData = @($LogData)
			}
		} else {
			$LogData = @()
		}
	
		$LogData += [pscustomobject]@{
			rmm_id = $RMM_Device_ID
			sc_id = $SC_Device_ID
			sophos_id = $Sophos_Device_ID
			jc_id = $JC_Device_ID
			ninite_id = $Ninite_Device_ID
			service_target = $ServiceTarget
			change = $ChangeType
			hostname = $Hostname
			reason = $Reason
			datetime = $Now
		}
	
		$LogData | ConvertTo-Json -Depth 5 | Out-File -FilePath $LogFilePath
	}

	# Function for querying a portion of the log history based on the possible filters
	# $LogHistory is the loaded json from the companies history log
	# StartTime is the unixtimestamp to start selection from (inclusive)
	# EndTime is the unixtimestamp to end selection at (exclusive) (if you set it to 'now' it will automatically calculate the current timestamp)
	# the remainder are optional and can be used as filters, hostname and reason support wildcards
	function log_query($LogHistory, $StartTime, $EndTime, $ServiceTarget = "", $RMM_Device_ID = "", $SC_Device_ID = "", $Sophos_Device_ID = "", $Ninite_Device_ID = "", $ChangeType = "", $Hostname = "", $Reason = "") {
		if ($EndTime -eq 'now') {
			$EndTime = [int](New-TimeSpan -Start (Get-Date "01/01/1970") -End (Get-Date).ToUniversalTime()).TotalSeconds
		}

		$History_TimeSubset = $LogHistory | Where-Object { $_.datetime -ge $StartTime -and $_.datetime -lt $EndTime }
		
		$History_Filtered = $History_TimeSubset
		if ($ServiceTarget) {
			$History_Filtered = $History_Filtered | Where-Object { $_.service_target -eq $ServiceTarget }
		}
		if ($RMM_Device_ID) {
			$History_Filtered = $History_Filtered | Where-Object { $RMM_Device_ID -in $_.rmm_id }
		}
		if ($SC_Device_ID) {
			$History_Filtered = $History_Filtered | Where-Object { $SC_Device_ID -in $_.sc_id }
		}
		if ($Sophos_Device_ID) {
			$History_Filtered = $History_Filtered | Where-Object { $Sophos_Device_ID -in $_.sophos_id }
		}
		if ($Ninite_Device_ID) {
			$History_Filtered = $History_Filtered | Where-Object { $Ninite_Device_ID -in $_.ninite_id }
		}
		if ($ChangeType) {
			$History_Filtered = $History_Filtered | Where-Object { $_.change -eq $ChangeType }
		}
		if ($Hostname) {
			$History_Filtered = $History_Filtered | Where-Object { $_.hostname -like $Hostname }
		}
		if ($Reason) {
			$History_Filtered = $History_Filtered | Where-Object { $_.reason -like $Reason }
		}
		
		return $History_Filtered;
	}

	# Helper function that queries the log based on the filters and returns the count of entries found
	function log_attempt_count($LogHistory, $ServiceTarget = "", $RMM_Device_ID = "", $SC_Device_ID = "", $Sophos_Device_ID = "", $Ninite_Device_ID = "", $ChangeType = "", $Hostname = "", $Reason = "") {
		$History = log_query -LogHistory $LogHistory -StartTime 0 -EndTime 'now' -ServiceTarget $ServiceTarget -RMM_Device_ID $RMM_Device_ID -SC_Device_ID $SC_Device_ID -Sophos_Device_ID $Sophos_Device_ID -Ninite_Device_ID $Ninite_Device_ID -ChangeType $ChangeType -Hostname $Hostname -Reason $Reason
		return ($History | Measure-Object).Count
	}

	# This function finds the difference in seconds between the oldest and newest unixtimestamp in a set of log history
	function log_time_diff($LogHistory) {
		$Newest = $LogHistory | Sort-Object -Property datetime -Descending | Select-Object -First 1
		$Oldest = $LogHistory | Sort-Object -Property datetime | Select-Object -First 1
		return $Newest.datetime - $Oldest.datetime
	}

	# Function for querying repair tickets based on the possible filters
	# $ServiceTarget is 'rmm', 'sc', 'sophos', or 'ninite'
	# $Hostname can be a single hostname or an array of hostnames to check for
	function repair_tickets($ServiceTarget = "", $Hostname = "") {
		if ($ServiceTarget -eq 'rmm') {
			$RepairTickets_ByService = $RepairTickets | Where-Object { $_.title -like "RMM *" -or $_.title -like "* RMM" -or $_.title -like "* RMM *" }
		} elseif ($ServiceTarget -eq 'sc') {
			$RepairTickets_ByService = $RepairTickets | Where-Object { $_.title -like "SC *" -or $_.title -like "* SC" -or $_.title -like "* SC *" -or $_.title -like "*ScreenConnect*" }
		} elseif ($ServiceTarget -eq 'sophos') {
			$RepairTickets_ByService = $RepairTickets | Where-Object { $_.title -like "Sophos *" -or $_.title -like "* Sophos" -or $_.title -like "* Sophos *" }
		} elseif ($ServiceTarget -eq 'ninite') {
				$RepairTickets_ByService = $RepairTickets | Where-Object { $_.title -like "Ninite *" -or $_.title -like "* Ninite" -or $_.title -like "* Ninite *" }
		} else {
			$RepairTickets_ByService = $RepairTickets
		}

		if ($Hostname -is [array]) {
			$RepairTickets_FilteredIDs = @()
			foreach ($UniqueHostname in $Hostname) {
				$RepairTickets_FilteredIDs += ($RepairTickets_ByService | Where-Object { $_.title -like "*$($UniqueHostname)*" }).Id
			}
			$RepairTickets_FilteredIDs = $RepairTickets_FilteredIDs | Sort-Object -Unique
			$RepairTickets_Filtered = $RepairTickets_ByService | Where-Object { $_.Id -in $RepairTickets_FilteredIDs }
		} else {
			$RepairTickets_Filtered = $RepairTickets_ByService | Where-Object { $_.title -like "*$($Hostname)*" }
		}

		return $RepairTickets_Filtered;
	}

	# Checks the log history to see if something has been attempted more than 5 times
	# and attempts have been made for the past 2 weeks
	# If so, an email is sent if one hasn't already been sent in the last 2 weeks, and the email is logged
	# $ErrorMessage can use HTML and it will become the main body of the email sent
	function check_failed_attempts($LogHistory, $Company_Acronym, $ErrorMessage, $ServiceTarget, $RMM_Device_ID, $SC_Device_ID, $Sophos_Device_ID, $Ninite_Device_ID, $ChangeType, $Hostname = "", $Reason = "") {
		$TwoWeeksAgo = [int](New-TimeSpan -Start (Get-Date "01/01/1970") -End (Get-Date).AddDays(-14).ToUniversalTime()).TotalSeconds
		$TenDays = [int](New-TimeSpan -Start (Get-Date).AddDays(-10).ToUniversalTime() -End (Get-Date).ToUniversalTime()).TotalSeconds

		# first check if a repair ticket already exists for this device/service
		if ($ServiceTarget -in ("rmm", "sc", "sophos", "ninite")) {
			$RepairTickets_Filtered = repair_tickets -ServiceTarget $ServiceTarget -Hostname $Hostname
			if (($RepairTickets_Filtered | Measure-Object).count -gt 0) {
				break;
			}
		}

		# next check if an email was sent about this in the last 2 weeks
		if ($ChangeType) {
			$EmailChangeType = $ChangeType + "-email"
		}
		if ($Reason) {
			$EmailReason = "Email sent for " + $Reason
		} else {
			$EmailReason = "Email sent for $ChangeType"
		}

		$ID_Params = @{}
		$EmailLink = ""
		if ($ServiceTarget -eq 'rmm') {
			$ID_Params."RMM_Device_ID" = $RMM_Device_ID
			$RMMDevice = $RMM_DevicesHash[$RMM_Device_ID]
			if ($RMMDevice.url) {
				$EmailLink = $RMMDevice.url
			} else {
				$EmailLink = "https://$($DattoAPIKey.Region).centrastage.net/csm/search?qs=uid%3A$($RMM_Device_ID)"
			}
		} elseif ($ServiceTarget -eq 'sc') {
			$ID_Params."SC_Device_ID" = $SC_Device_ID
			$SCDevice = $SC_DevicesHash[$SC_Device_ID]
			$EmailLink = "$($SCLogin.URL)/Host#Access/All%20Machines/$($SCDevice.Name)/$SC_Device_ID"
		} elseif ($ServiceTarget -eq 'sophos') {
			$ID_Params."Sophos_Device_ID" = $Sophos_Device_ID
			$EmailLink = "https://cloud.sophos.com/manage/devices/computers/$($Sophos_Device_ID)"
		} elseif ($ServiceTarget -eq 'ninite') {
			$ID_Params."Ninite_Device_ID" = $Ninite_Device_ID
			$EmailLink = ""
		}

		$EmailQuery_Params = @{
			LogHistory = $LogHistory
			StartTime = $TwoWeeksAgo
			EndTime = 'now'
			ServiceTarget = $ServiceTarget
			ChangeType = $EmailChangeType
			Hostname = $Hostname
			Reason = $EmailReason
		} + $ID_Params
		$History_Subset_Emails = log_query @EmailQuery_Params

		# no emails were already sent, continue
		if (($History_Subset_Emails | Measure-Object).count -eq 0) {
			$FilterQuery_Params = @{
				LogHistory = $LogHistory
				StartTime = $TwoWeeksAgo
				EndTime = 'now'
				ServiceTarget = $ServiceTarget
				ChangeType = $ChangeType
				Hostname = $Hostname
				Reason = $Reason
			} + $ID_Params
			$History_Filtered = log_query @FilterQuery_Params

			# if attempts have been made over at least a 10 day span AND a minimum of 5 attempts have been made
			if (($History_Filtered | Measure-Object).count -ge 5 -and (log_time_diff($History_Filtered)) -ge $TenDays) {
				# send an email
				$EmailSubject = "Device Audit - Auto-Fix Failed: $Hostname ($Company_Acronym)"
				$EmailIntro = "An auto-fix has been attempted on $Hostname more than 5 times in the past 2 weeks yet the issue is still not resolved. Please resolve this manually."

				$HTMLEmail = $EmailTemplate -f `
								$EmailIntro, 
								"Auto-Fix has repeatedly failed", 
								$ErrorMessage, 
								"<br />Link: <a href='$EmailLink'>$EmailLink</a> <br /><br />The audit will continue to attempt to automatically fix this issue, but it will likely keep failing. Please resolve this manually."

				$mailbody = @{
					"From" = $EmailFrom
					"To" = $EmailTo_FailedFixes
					"Subject" = $EmailSubject
					"HTMLContent" = $HTMLEmail
				} | ConvertTo-Json -Depth 6

				$headers = @{
					'x-api-key' = $Email_APIKey.Key
				}

				Invoke-RestMethod -Method Post -Uri $Email_APIKey.Url -Body $mailbody -Headers $headers -ContentType application/json
				Write-Host "Multiple Failed Auto-Fix Attempts Found. Email Sent." -ForegroundColor Yellow

				# log the sent email
				log_change -Company_Acronym $Company_Acronym -ServiceTarget $ServiceTarget -RMM_Device_ID $RMM_Device_ID -SC_Device_ID $SC_Device_ID -Sophos_Device_ID $Sophos_Device_ID -ChangeType $EmailChangeType -Hostname $Hostname -Reason $EmailReason
			}
		}
	}

	# Functions for comparing devices by their last active date
	# Pass the function a list of device ids
	# Each returns an ordered list with the type (rmm, sc, or sophos), device ID and last active date, ordered with newest first, $null if no date
	$UnixDateLowLimit = Get-Date -Year 1970 -Month 1 -Day 1 -Hour 0 -Minute 0 -Second 0
	function compare_activity_sc($DeviceIDs) {
		if (!$SC_DevicesHash) {
			return @()
		}

		$SCDevices = @()
		foreach ($DeviceID in $DeviceIDs) {
			$SCDevices += $SC_DevicesHash[$DeviceID]
		}
		$DevicesOutput = @()

		foreach ($Device in $SCDevices) {
			$DeviceOutputObj = [PsCustomObject]@{
				type = "sc"
				id = $Device.SessionID
				last_active = $null
			}

			if ($Device.GuestLastSeen -and [string]$Device.GuestLastSeen -as [DateTime] -and [DateTime]$Device.GuestLastSeen -gt $UnixDateLowLimit) {
				$DeviceOutputObj.last_active = [DateTime]$Device.GuestLastSeen
				$DevicesOutput += $DeviceOutputObj
			} elseif ($Device.GuestLastActivityTime -and [string]$Device.GuestLastActivityTime -as [DateTime] -and [DateTime]$Device.GuestLastActivityTime -gt $UnixDateLowLimit) {
				$DeviceOutputObj.last_active = [DateTime]$Device.GuestLastActivityTime
				$DevicesOutput += $DeviceOutputObj
			} elseif ($Device.GuestInfoUpdateTime -and [string]$Device.GuestInfoUpdateTime -as [DateTime] -and [DateTime]$Device.GuestInfoUpdateTime -gt $UnixDateLowLimit) {
				$DeviceOutputObj.last_active = [DateTime]$Device.GuestInfoUpdateTime
				$DevicesOutput += $DeviceOutputObj
			} elseif ($Device.GuestLastBootTime -and [string]$Device.GuestLastBootTime -as [DateTime] -and [DateTime]$Device.GuestLastBootTime -gt $UnixDateLowLimit) {
				$DeviceOutputObj.last_active = [DateTime]$Device.GuestLastBootTime
				$DevicesOutput += $DeviceOutputObj
			}
		}
		
		$DevicesOutput = $DevicesOutput | Sort-Object last_active -Desc

		$DevicesOutput
		return
	}

	function compare_activity_rmm($DeviceIDs) {
		if (!$RMM_DevicesHash) {
			return @()
		}

		$Now = Get-Date
		$RMMDevices = @()
		foreach ($DeviceID in $DeviceIDs) {
			$RMMDevices += $RMM_DevicesHash[$DeviceID]
		}

		$DevicesOutput = @()

		foreach ($Device in $RMMDevices) {
			$DeviceOutputObj = [PsCustomObject]@{
				type = "rmm"
				id = $Device."Device UID"
				last_active = $null
			}

			if ($Device.Status -eq "Online" -or $Device."Last Seen" -eq "Currently Online") {
				$DeviceOutputObj.last_active = $Now
				$DevicesOutput += $DeviceOutputObj
			} elseif ($Device."Last Seen" -and [string]$Device."Last Seen" -as [DateTime]) {
				$DeviceOutputObj.last_active = [DateTime]$Device."Last Seen"
				$DevicesOutput += $DeviceOutputObj
			}
		}

		$DevicesOutput = $DevicesOutput | Sort-Object last_active -Desc

		$DevicesOutput
		return
	}

	function compare_activity_sophos($DeviceIDs) {
		if (!$Sophos_DevicesHash) {
			return @()
		}

		$SophosDevices = @()
		foreach ($DeviceID in $DeviceIDs) {
			$SophosDevices += $Sophos_DevicesHash[$DeviceID]
		}
		$DevicesOutput = @()

		foreach ($Device in $SophosDevices) {
			$DeviceOutputObj = [PsCustomObject]@{
				type = "sophos"
				id = $Device.id
				last_active = $null
			}

			if ($Device.lastSeenAt -and [string]$Device.lastSeenAt -as [DateTime]) {
				$DeviceOutputObj.last_active = [DateTime]$Device.lastSeenAt
				$DevicesOutput += $DeviceOutputObj
			}
		}

		$DevicesOutput = $DevicesOutput | Sort-Object last_active -Desc

		$DevicesOutput
		return
	}

	function compare_activity_ninite($DeviceIDs) {
		if (!$Ninite_DevicesHash) {
			return @()
		}

		$NiniteDevices = @()
		foreach ($DeviceID in $DeviceIDs) {
			$NiniteDevices += $Ninite_DevicesHash[$DeviceID]
		}
		$DevicesOutput = @()

		foreach ($Device in $NiniteDevices) {
			$DeviceOutputObj = [PsCustomObject]@{
				type = "ninite"
				id = $Device.id
				last_active = $null
			}

			if ($Device.last_seen -and [string]$Device.last_seen -as [DateTime]) {
				$DeviceOutputObj.last_active = [DateTime]$Device.last_seen
				$DevicesOutput += $DeviceOutputObj
			}
		}

		$DevicesOutput = $DevicesOutput | Sort-Object last_active -Desc

		$DevicesOutput
		return
	}

	function compare_activity_jc($DeviceIDs) {
		if (!$JC_DevicesHash) {
			return @()
		}

		$JCDevices = @()
		foreach ($DeviceID in $DeviceIDs) {
			$JCDevices += $JC_DevicesHash[$DeviceID]
		}
		$DevicesOutput = @()

		foreach ($Device in $JCDevices) {
			$DeviceOutputObj = [PsCustomObject]@{
				type = "jc"
				id = $Device.id
				last_active = $null
			}

			if ($Device.lastContact -and [string]$Device.lastContact -as [DateTime]) {
				$DeviceOutputObj.last_active = [DateTime]$Device.lastContact
				$DevicesOutput += $DeviceOutputObj
			}
		}

		$DevicesOutput = $DevicesOutput | Sort-Object last_active -Desc

		$DevicesOutput
		return
	}

	function compare_activity_azure($DeviceIDs) {
		if (!$Azure_DevicesHash) {
			return @()
		}

		$AzureDevices = @()
		foreach ($DeviceID in $DeviceIDs) {
			$AzureDevices += $Azure_DevicesHash[$DeviceID]
		}
		$DevicesOutput = @()

		foreach ($Device in $AzureDevices) {
			$DeviceOutputObj = [PsCustomObject]@{
				type = "azure"
				id = $Device.id
				last_active = $null
			}

			if ($Device.ApproximateLastSignInDateTime -and [string]$Device.ApproximateLastSignInDateTime -as [DateTime]) {
				$DeviceOutputObj.last_active = [DateTime]$Device.ApproximateLastSignInDateTime
				$DevicesOutput += $DeviceOutputObj
			}
		}

		$DevicesOutput = $DevicesOutput | Sort-Object last_active -Desc

		$DevicesOutput
		return
	}

	function compare_activity_intune($DeviceIDs) {
		if (!$Intune_DevicesHash) {
			return @()
		}

		$IntuneDevices = @()
		foreach ($DeviceID in $DeviceIDs) {
			$IntuneDevices += $Intune_DevicesHash[$DeviceID]
		}
		$DevicesOutput = @()

		foreach ($Device in $IntuneDevices) {
			$DeviceOutputObj = [PsCustomObject]@{
				type = "intune"
				id = $Device.id
				last_active = $null
			}

			if ($Device.LastSyncDateTime -and [string]$Device.LastSyncDateTime -as [DateTime]) {
				$DeviceOutputObj.last_active = [DateTime]$Device.LastSyncDateTime
				$DevicesOutput += $DeviceOutputObj
			}
		}

		$DevicesOutput = $DevicesOutput | Sort-Object last_active -Desc

		$DevicesOutput
		return
	}

	# Helper function that takes a $MatchedDevices object and returns the activity comparison for SC, RMM, Sophos, and (if applicable) Azure, Intune, JC &/or Ninite
	function compare_activity($MatchedDevice) {
		$Activity = @{}

		if ($MatchedDevice.sc_matches -and $MatchedDevice.sc_matches.count -gt 0) {
			$SCActivity = compare_activity_sc $MatchedDevice.sc_matches
			$Activity.sc = $SCActivity | Sort-Object last_active -Descending | Select-Object -First 1
		}

		if ($MatchedDevice.rmm_matches -and $MatchedDevice.rmm_matches.count -gt 0) {
			$RMMActivity = compare_activity_rmm $MatchedDevice.rmm_matches
			$Activity.rmm = $RMMActivity | Sort-Object last_active -Descending | Select-Object -First 1
		}

		if ($MatchedDevice.sophos_matches -and $MatchedDevice.sophos_matches.count -gt 0) {
			$SophosActivity = compare_activity_sophos $MatchedDevice.sophos_matches
			$Activity.sophos = $SophosActivity | Sort-Object last_active -Descending | Select-Object -First 1
		}

		if ($NiniteAuthResponse -and $MatchedDevice.ninite_matches -and $MatchedDevice.ninite_matches.count -gt 0) {
			$NiniteActivity = compare_activity_ninite $MatchedDevice.ninite_matches
			$Activity.ninite = $NiniteActivity | Sort-Object last_active -Descending | Select-Object -First 1
		}

		if ($JCConnected -and $MatchedDevice.jc_matches -and $MatchedDevice.jc_matches.count -gt 0) {
			$JCActivity = compare_activity_jc $MatchedDevice.jc_matches
			$Activity.jc = $JCActivity | Sort-Object last_active -Descending | Select-Object -First 1
		}

		if ($MatchedDevice.azure_matches -and $MatchedDevice.azure_matches.count -gt 0) {
			$AzureActivity = compare_activity_azure $MatchedDevice.azure_matches
			$Activity.azure = $AzureActivity | Sort-Object last_active -Descending | Select-Object -First 1
		}

		if ($MatchedDevice.intune_matches -and $MatchedDevice.intune_matches.count -gt 0) {
			$IntuneActivity = compare_activity_intune $MatchedDevice.intune_matches
			$Activity.intune = $IntuneActivity | Sort-Object last_active -Descending | Select-Object -First 1
		}

		$Activity
		return
	}

	# Adds a device to the install queue json file (creates the file if need be)
	# Either set $SC_ID or $RMM_ID, this is the device used for the install
	# Set $ToInstall to what needs to be installed ("sc", "rmm", or "ninite")
	function add_device_to_install_queue($SC_ID = $false, $RMM_ID = $false, $ToInstall = $false) {
		$FromDeviceType = $false
		if ($SC_ID) {
			$FromDeviceType = "sc"
		} elseif ($RMM_ID) {
			$FromDeviceType = "rmm"
		} else {
			return $false
		}

		if (!$ToInstall) { return $false }

		$InstallQueue = [PSCustomObject]@{}
		if (Test-Path $InstallQueuePath) {
			$InstallQueue = Get-Content -Path $InstallQueuePath -Raw | ConvertFrom-Json
			if (!$InstallQueue) {
				$InstallQueue = [PSCustomObject]@{}
			}
		}
		
		if (!$InstallQueue.PSObject.Properties -or $InstallQueue.PSObject.Properties.Name -notcontains $ToInstall) {
			$InstallQueue | Add-Member -NotePropertyName $ToInstall -NotePropertyValue $false
			$InstallQueue.($ToInstall) = [PSCustomObject]@{}
		}

		if (!$InstallQueue.($ToInstall).PSObject.Properties -or $InstallQueue.($ToInstall).PSObject.Properties.Name -notcontains $FromDeviceType) {
			$InstallQueue.($ToInstall) | Add-Member -NotePropertyName $FromDeviceType -NotePropertyValue @()
		}

		if ($FromDeviceType -eq "sc") {
			if ($SC_ID -notin $InstallQueue.($ToInstall).($FromDeviceType)) {
				$InstallQueue.($ToInstall).($FromDeviceType) += $SC_ID
			}
		} else {
			if ($RMM_ID -notin $InstallQueue.($ToInstall).($FromDeviceType)) {
				$InstallQueue.($ToInstall).($FromDeviceType) += $RMM_ID
			}
		}

		if ($InstallQueue -and $InstallQueuePath) {
			$InstallQueue | ConvertTo-Json -Depth 5 | Out-File -FilePath $InstallQueuePath
		}

		return $true
	}

	# Removes a device from the install queue json file
	# Either set $SC_ID or $RMM_ID, this is the device used for the install
	# Set $ToInstall to what needed to be installed ("sc", "rmm", or "ninite"), if left $false will remove for all $ToInstall types
	function remove_device_from_install_queue($SC_ID = $false, $RMM_ID = $false, $ToInstall = $false) {
		$FromDeviceType = $false
		if ($SC_ID) {
			$FromDeviceType = "sc"
		} elseif ($RMM_ID) {
			$FromDeviceType = "rmm"
		} else {
			return $false
		}

		$InstallQueue = [PSCustomObject]@{}
		if (Test-Path $InstallQueuePath) {
			$InstallQueue = Get-Content -Path $InstallQueuePath -Raw | ConvertFrom-Json
			if (!$InstallQueue) {
				$InstallQueue = [PSCustomObject]@{}
			}
		}

		if ($ToInstall -and $InstallQueue.PSObject.Properties -and $InstallQueue.PSObject.Properties.Name -contains $ToInstall -and $InstallQueue.($ToInstall).PSObject.Properties -and $InstallQueue.($ToInstall).PSObject.Properties.Name -contains $FromDeviceType) {
			if ($FromDeviceType -eq "sc") {
				$InstallQueue.($ToInstall).($FromDeviceType) = @($InstallQueue.($ToInstall).($FromDeviceType) | Where-Object { $_ -notlike $SC_ID })
			} else {
				$InstallQueue.($ToInstall).($FromDeviceType) = @($InstallQueue.($ToInstall).($FromDeviceType) | Where-Object { $_ -notlike $RMM_ID })
			}
		} elseif (!$ToInstall -and $InstallQueue.PSObject.Properties) {
			foreach ($InstallType in $InstallQueue.PSObject.Properties.Name) {
				if ($InstallQueue.($InstallType).PSObject.Properties -and $InstallQueue.($InstallType).PSObject.Properties.Name -contains $FromDeviceType) {
					if ($FromDeviceType -eq "sc") {
						$InstallQueue.($InstallType).($FromDeviceType) = @($InstallQueue.($InstallType).($FromDeviceType) | Where-Object { $_ -notlike $SC_ID })
					} else {
						$InstallQueue.($InstallType).($FromDeviceType) = @($InstallQueue.($InstallType).($FromDeviceType) | Where-Object { $_ -notlike $RMM_ID })
					}
				}
			}
		}

		if ($InstallQueue -and $InstallQueuePath) {
			$InstallQueue | ConvertTo-Json -Depth 5 | Out-File -FilePath $InstallQueuePath
		}

		return $true
	}

	# Helper function that checks a device from the $MatchedDevices array against the $Ignore_Installs config value and returns true if it should be ignored
	# Also ignores Sophos on Hyper-V hosts via a regex check
	# $System should be 'sc', 'rmm', 'sophos', or 'ninite'
	function ignore_install($Device, $System) {
		if ($System -eq 'sc' -and $Ignore_Installs.SC -eq $true) {
			return $true
		} elseif ($System -eq 'rmm' -and $Ignore_Installs.RMM -eq $true) {
			return $true
		} elseif ($System -eq 'sophos' -and $Ignore_Installs.Sophos -eq $true) {
			return $true
		} elseif ($System -eq 'ninite' -and $Ignore_Installs.Ninite -eq $true) {
			return $true
		}

		if ($System -eq 'sophos' -and ($Device.rmm_hostname -match $HyperVRegex -or $Device.sc_hostname -match $HyperVRegex)) {
			return $true;
		}

		$IgnoredDevices = @()
		if ($System -eq 'sc') {
			$IgnoredDevices = $Ignore_Installs.SC
		} elseif ($System -eq 'rmm') {
			$IgnoredDevices = $Ignore_Installs.RMM
		} elseif ($System -eq 'sophos') {
			$IgnoredDevices = $Ignore_Installs.Sophos
		} elseif ($System -eq 'ninite') {
			$IgnoredDevices = $Ignore_Installs.Ninite
		}

		if ($IgnoredDevices) {
			if ($System -eq 'sc' -and ($IgnoredDevices | Where-Object { $_ -in $Device.rmm_hostname -or $_ -in $Device.rmm_matches -or $_ -in $Device.sophos_hostname -or $_ -in $Device.sophos_matches } | Measure-Object).Count -gt 0) {
				return $true
			} elseif ($System -eq 'rmm' -and ($IgnoredDevices | Where-Object { $_ -in $Device.sc_hostname -or $_ -in $Device.sc_matches -or $_ -in $Device.sophos_hostname -or $_ -in $Device.sophos_matches } | Measure-Object).Count -gt 0) {
				return $true
			} elseif ($System -eq 'sophos' -and ($IgnoredDevices | Where-Object { $_ -in $Device.sc_hostname -or $_ -in $Device.sc_matches -or $_ -in $Device.rmm_hostname -or $_ -in $Device.rmm_matches  } | Measure-Object).Count -gt 0) {
				return $true
			} elseif ($System -eq 'ninite' -and ($IgnoredDevices | Where-Object { $_ -in $Device.sc_hostname -or $_ -in $Device.sc_matches -or $_ -in $Device.rmm_hostname -or $_ -in $Device.rmm_matches -or $_ -in $Device.sophos_hostname -or $_ -in $Device.sophos_matches } | Measure-Object).Count -gt 0) {
				return $true
			}
		} else {
			return $false
		}
	}

	# Deletes a device from ScreenConnect
	function delete_from_sc($SC_ID, $SCWebSession) {
		# Get an anti-forgery token from the website
		$Response = Invoke-WebRequest "$($SCLogin.URL)/Host#Access/All%20Machines//$SC_ID" -WebSession $SCWebSession -Method 'POST' -ContentType 'application/json'
		$Response.RawContent -match '"antiForgeryToken":"(.+?)"' | Out-Null
		$AntiForgeryToken = $matches[1]

		if ($AntiForgeryToken) {
			$FormBody = '[["All Machines"],[{"SessionID": "' + $SC_ID + '","EventType":21,"Data":null}]]'
			$Response = Invoke-WebRequest "$($SCLogin.URL)/Services/PageService.ashx/AddSessionEvents" -WebSession $SCWebSession -Headers @{"X-Anti-Forgery-Token" = $AntiForgeryToken} -Body $FormBody -Method 'POST' -ContentType 'application/json'
			$Removed = remove_device_from_install_queue -SC_ID $SC_ID -ToInstall $false
			return $true
		} else {
			Write-Warning "Could not get an anti-forgery token from Screenconnect. Failed to delete device from SC: $SC_ID"
			return $false
		}
	}

	# This doesn't truly delete a device from RMM (we can't using the API), instead it sets the Delete Me UDF which adds the device into the device filter of devices we should delete
	function delete_from_rmm($RMM_Device_ID) {
		Set-DrmmDeviceUdf -deviceUid $RMM_Device_ID -udf30 "True"
		$Removed = remove_device_from_install_queue -RMM_ID $RMM_Device_ID -ToInstall $false
	}

	# Deletes a device from Sophos (be careful with this, make sure it no longer is installed on the device!)
	# Only works if using the sophos API. Pass in the same headers used for getting the endpoints.
	function delete_from_sophos($Sophos_Device_ID, $TenantApiHost, $SophosHeader) {
		if ($Sophos_Device_ID -and $TenantApiHost -and $SophosHeader) {
			try {
				$Response = Invoke-RestMethod -Method DELETE -Headers $SophosHeader -uri ($TenantApiHost + "/endpoint/v1/endpoints/$Sophos_Device_ID")
				if ($Response.deleted -eq "True") {
					return $true
				}
			} catch {
				Write-PSFMessage -Level Error -Message "Could not auto-delete Sophos device '$Sophos_Device_ID' for the reason: " + $_.Exception.Message
			}
		}
		return $false
	}

	# Deletes a device from JumpCloud
	function delete_from_jc($JC_ID) {
		$Deleted = $false
		if ($JC_ID) {
			$Deleted = Remove-JCSystem -SystemID $JC_ID -Force
		}

		if ($Deleted -and $Deleted.Results -like "Deleted") {
			return $true
		} else {
			Write-Warning "Could not delete device '$($JC_ID)' from JumpCloud."
			return $false
		}
	}

	# Deletes a device from Ninite
	function delete_from_ninite($Ninite_ID, $NiniteWebSession, $NiniteHeader) {
		$FormBody = @{
			id = 1
			jsonrpc = "2.0"
			method = "delete_machine"
			params = @{
				machine_id = $Ninite_ID
			}
		} | ConvertTo-Json
	
		try {
			$NiniteResponse = Invoke-WebRequest "$($Ninite_Login.BaseURI)remote/rpc_web" -WebSession $NiniteWebSession -Headers $NiniteHeader -Body $FormBody -Method 'POST' -ContentType 'application/json; charset=utf-8'
		} catch {
			Write-Warning "Could not delete device '$($Ninite_ID)' from Ninite."
			return $false
		}
		$DeleteResponse = $NiniteResponse.Content | ConvertFrom-Json
		if ($DeleteResponse -and $null -eq $DeleteResponse.result) {
			return $true
		}
	}

	# Archives a configuration in ITG
	function archive_itg($ITG_Device_ID) {
		$UpdatedConfig = @{
			'type' = 'configurations'
			'attributes' = @{
				'archived' = 'true'
			}
		}

		try {
			Set-ITGlueConfigurations -id $ITG_Device_ID -data $UpdatedConfig
			return $true
		} catch {
			Write-PSFMessage -Level Error -Message "Could not archive ITG configuration '$ITG_Device_ID' for the reason: " + $_.Exception.Message
			return $false
		}
	}

	# Cleans up the name of a Manufacturer
	function manufacturer_cleanup($Manufacturer) {
		if ($Manufacturer) {
			$CleanedManufacturer = $Manufacturer
			if ($CleanedManufacturer -like "*/*") {
				$CleanedManufacturer = ($CleanedManufacturer -split '/')[0]
			}
			$CleanedManufacturer = $CleanedManufacturer.Trim()
			$CleanedManufacturer = $CleanedManufacturer -replace ",? ?(Inc\.?$|Corporation$|Corp\.?$|Co\.$|Ltd\.?$)", ""
			$CleanedManufacturer = $CleanedManufacturer.Trim()
			$CleanedManufacturer = $CleanedManufacturer -replace ",? ?(Inc\.?$|Corporation$|Corp\.?$|Co\.$|Ltd\.?$)", ""
			$CleanedManufacturer = $CleanedManufacturer.Trim()

			return $CleanedManufacturer
		} else {
			return $null
		}
	}

	# Converts a subnet mask into a Cidr range
	function Convert-SubnetMaskToCidr($Subnet) {
		# From: https://codeandkeep.com/PowerShell-Get-Subnet-NetworkID/
		$NetMaskIP = [IPAddress]$Subnet
		$BinaryString = [String]::Empty
		$NetMaskIP.GetAddressBytes() | ForEach-Object {
			$BinaryString += [Convert]::ToString($_, 2)
		}
		return $binaryString.TrimEnd('0').Length
	}

	# Levenshtein distance function for comparing similarity between two strings
	function Measure-StringDistance {
		<#
			.SYNOPSIS
				Compute the distance between two strings using the Levenshtein distance formula.
			
			.DESCRIPTION
				Compute the distance between two strings using the Levenshtein distance formula.

			.PARAMETER Source
				The source string.

			.PARAMETER Compare
				The comparison string.

			.EXAMPLE
				PS C:\> Measure-StringDistance -Source "Michael" -Compare "Micheal"

				2

				There are two characters that are different, "a" and "e".

			.EXAMPLE
				PS C:\> Measure-StringDistance -Source "Michael" -Compare "Michal"

				1

				There is one character that is different, "e".

			.NOTES
				Author:
				Michael West
		#>

		[CmdletBinding(SupportsShouldProcess=$true)]
		[OutputType([int])]
		param (
			[Parameter(ValueFromPipelineByPropertyName=$true)]
			[string]$Source = "",
			[string]$Compare = ""
		)
		$n = $Source.Length;
		$m = $Compare.Length;
		$d = New-Object 'int[,]' $($n+1),$($m+1)
			
		if ($n -eq 0){
		return $m
		}
		if ($m -eq 0){
			return $n
		}

		for ([int]$i = 0; $i -le $n; $i++){
			$d[$i, 0] = $i
		}
		for ([int]$j = 0; $j -le $m; $j++){
			$d[0, $j] = $j
		}

		for ([int]$i = 1; $i -le $n; $i++){
			for ([int]$j = 1; $j -le $m; $j++){
				if ($Compare[$($j - 1)] -eq $Source[$($i - 1)]){
					$cost = 0
				}
				else{
					$cost = 1
				}
				$d[$i, $j] = [Math]::Min([Math]::Min($($d[$($i-1), $j] + 1), $($d[$i, $($j-1)] + 1)),$($d[$($i-1), $($j-1)]+$cost))
			}
		}
			
		return $d[$n, $m]
	}

	# Functions for installing/reinstalling SC/RMM/Sophos

	# Installs RMM on a device using ScreenConnect
	# $SC_ID the GUID of the device in screenconnect
	# $RMM_ORG_ID the GUID of the organization in RMM (found in the organization under Settings > General > ID)
	# $SCWebSession the web session used to authenticate with Screenconnect previously
	function install_rmm_using_sc($SC_ID, $RMM_ORG_ID, $SCWebSession) {
		# Get an anti-forgery token from the website
		$Response = Invoke-WebRequest "$($SCLogin.URL)/Host#Access/All%20Machines//$SC_ID" -WebSession $SCWebSession -Method 'POST' -ContentType 'application/json'
		$Response.RawContent -match '"antiForgeryToken":"(.+?)"' | Out-Null
		$AntiForgeryToken = $matches[1]

		if ($AntiForgeryToken) {
			$RMMInstallCmd = "#timeout=100000\npowershell -command \`"[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://$($DattoAPIKey.Region).centrastage.net/csm/profile/downloadAgent/$RMM_ORG_ID' -OutFile c:\\windows\\temp\\AEM-Installer.exe; c:\\windows\\temp\\AEM-Installer.exe /s; Write-Host 'RMM Install Complete';\`""

			$FormBody = '[["All Machines"],[{"SessionID": "' + $SC_ID + '","EventType":44,"Data":"' + $RMMInstallCmd + '"}]]'
			$Response = Invoke-WebRequest "$($SCLogin.URL)/Services/PageService.ashx/AddSessionEvents" -WebSession $SCWebSession -Headers @{"X-Anti-Forgery-Token" = $AntiForgeryToken} -Body $FormBody -Method 'POST' -ContentType 'application/json'
			$Removed = remove_device_from_install_queue -SC_ID $SC_ID -ToInstall "rmm"
			return $true
		} else {
			Write-Warning "Could not get an anti-forgery token from Screenconnect. Failed to install RMM for SC device ID: $SC_ID"
			return $false
		}
	}

	function install_rmm_using_sc_mac($SC_ID, $RMM_ORG_ID, $SCWebSession) {
		# Get an anti-forgery token from the website
		$Response = Invoke-WebRequest "$($SCLogin.URL)/Host#Access/All%20Machines//$SC_ID" -WebSession $SCWebSession -Method 'POST' -ContentType 'application/json'
		$Response.RawContent -match '"antiForgeryToken":"(.+?)"' | Out-Null
		$AntiForgeryToken = $matches[1]
	
		if ($AntiForgeryToken) {
			$RMMInstallCmd = "#timeout=100000\n#!bash\ncd /tmp\ncurl -o aem-installer.zip 'https://$($DattoAPIKey.Region).centrastage.net/csm/profile/downloadMacAgent/$RMM_ORG_ID'\nunzip -a aem-installer.zip\ncd AgentSetup\nsudo installer -pkg CAG.pkg -target /"
	
			$FormBody = '[["All Machines"],[{"SessionID": "' + $SC_ID + '","EventType":44,"Data":"' + $RMMInstallCmd + '"}]]'
			$Response = Invoke-WebRequest "$($SCLogin.URL)/Services/PageService.ashx/AddSessionEvents" -WebSession $SCWebSession -Headers @{"X-Anti-Forgery-Token" = $AntiForgeryToken} -Body $FormBody -Method 'POST' -ContentType 'application/json'
			$Removed = remove_device_from_install_queue -SC_ID $SC_ID -ToInstall "rmm"

			return $true
		} else {
			Write-Warning "Could not get an anti-forgery token from Screenconnect. Failed to install RMM for SC device ID: $SC_ID"
			return $false
		}
	}

	function is_sc_installed($RMM_Device) {
		$DeviceSoftware = Get-DrmmAuditDeviceSoftware -DeviceUid $RMM_Device."Device UID"
		if (($DeviceSoftware | Where-Object { $_.name -like "ScreenConnect Client*" } | Measure-Object).Count -gt 0) {
			return $true
		} else {
			return $false
		}
	}

	function log_recent_rmm_job($RMM_Device, $JobType, $JobID) {
		$RecentRMMJobs = [PSCustomObject]@{}

		if (Test-Path $RecentRMMJobsPath) {
			$RecentRMMJobs = Get-Content -Path $RecentRMMJobsPath -Raw | ConvertFrom-Json
			if (!$RecentRMMJobs) {
				$RecentRMMJobs = [PSCustomObject]@{}
			}
		}
		
		if (!$RecentRMMJobs.PSObject.Properties -or $RecentRMMJobs.PSObject.Properties.Name -notcontains $RMM_Device."Device UID") {
			$RecentRMMJobs | Add-Member -NotePropertyName $RMM_Device."Device UID" -NotePropertyValue $false
			$RecentRMMJobs.($RMM_Device."Device UID") = [PSCustomObject]@{}
		}

		if (!$RecentRMMJobs.($RMM_Device."Device UID").PSObject.Properties -or $RecentRMMJobs.($RMM_Device."Device UID").PSObject.Properties.Name -notcontains $JobType) {
			$RecentRMMJobs.($RMM_Device."Device UID") | Add-Member -NotePropertyName $JobType -NotePropertyValue $false	
		}

		$RecentRMMJobs.($RMM_Device."Device UID").($JobType) = $JobID

		if ($RecentRMMJobs -and $RecentRMMJobsPath) {
			$RecentRMMJobs | ConvertTo-Json -Depth 5 | Out-File -FilePath $RecentRMMJobsPath
		}
	}

	function is_existing_rmm_job_active($RMM_Device, $JobType) {
		$RecentRMMJobs = $false
		if (Test-Path -Path $RecentRMMJobsPath) {
			$RecentRMMJobs = Get-Content -Path $RecentRMMJobsPath -Raw | ConvertFrom-Json
		}

		if ($RecentRMMJobs -and $RecentRMMJobs.($RMM_Device."Device UID") -and $RecentRMMJobs.($RMM_Device."Device UID").($JobType)) {
			$JobID = $RecentRMMJobs.($RMM_Device."Device UID").($JobType)
			$JobStatus = Get-DrmmJobStatus -jobUid $JobID

			if ($JobStatus -and $JobStatus.status -and $JobStatus.status -eq "active") {
				return $true
			}
		}

		return $false
	}

	function uninstall_sc_using_rmm($RMM_Device) {
		if ($RMM_Device."Operating System" -like "*Windows*" -and (is_sc_installed -RMM_Device $RMM_Device)) {
			if (is_existing_rmm_job_active -RMM_Device $RMM_Device -JobType "uninstall_sc") {
				return $false
			}
			$Job = Set-DrmmDeviceQuickJob -DeviceUid $RMM_Device."Device UID" -jobName "Uninstall ScreenConnect on $($RMM_Device."Device Hostname")" -ComponentName "ConnectWise Control (ScreenConnect) Uninstaller [WIN]"
			if ($Job -and $Job.job -and $Job.job.uid) {
				log_recent_rmm_job -RMM_Device $RMM_Device -JobType "uninstall_sc" -JobID $Job.job.uid
				return $true
			}
		}
		return $false
	}

	function install_sc_using_rmm($RMM_Device) {
		if (is_existing_rmm_job_active -RMM_Device $RMM_Device -JobType "install_sc") {
			return $false
		}

		if ($RMM_Device."Operating System" -like "*Windows*") {
			$Job = Set-DrmmDeviceQuickJob -DeviceUid $RMM_Device."Device UID" -jobName "Install ScreenConnect on $($RMM_Device."Device Hostname")" -ComponentName "ScreenConnect Install - WIN"
			if ($Job -and $Job.job -and $Job.job.uid) {
				$Removed = remove_device_from_install_queue -RMM_ID $RMM_Device."Device UID" -ToInstall "sc"
				log_recent_rmm_job -RMM_Device $RMM_Device -JobType "install_sc" -JobID $Job.job.uid
				return $true
			}
		} elseif ($RMM_Device."Operating System" -like "*Mac OS*") {
			$Job = Set-DrmmDeviceQuickJob -DeviceUid $RMM_Device."Device UID" -jobName "Install ScreenConnect on $($RMM_Device."Device Hostname")" -ComponentName "ScreenConnect Install - MAC"
			if ($Job -and $Job.job -and $Job.job.uid) {
				$Removed = remove_device_from_install_queue -RMM_ID $RMM_Device."Device UID" -ToInstall "sc"
				log_recent_rmm_job -RMM_Device $RMM_Device -JobType "install_sc" -JobID $Job.job.uid
				return $true
			}
		}
		return $false
	}

	function install_ninite_using_rmm($RMM_Device) {
		if (is_existing_rmm_job_active -RMM_Device $RMM_Device -JobType "install_ninite") {
			return $false
		}

		if ($RMM_Device."Operating System" -like "*Windows*" -and $RMM_Device."Device Type" -notlike "*Server*") {
			$Job = Set-DrmmDeviceQuickJob -DeviceUid $RMM_Device."Device UID" -jobName "Install Ninite on $($RMM_Device."Device Hostname")" -ComponentName "Ninite Agent Installer [WIN]"
			if ($Job -and $Job.job -and $Job.job.uid) {
				$Removed = remove_device_from_install_queue -RMM_ID $RMM_Device."Device UID" -ToInstall "ninite"
				log_recent_rmm_job -RMM_Device $RMM_Device -JobType "install_ninite" -JobID $Job.job.uid
				return $true
			}
		}
		return $false
	}
}

# Add a last seen field to Ninite devices
foreach ($Machine in $Ninite_Machines) {
	# Parse the last seen and add a field for it
	if (!$Machine.last_seen) {
		$Machine | Add-Member -NotePropertyName "last_seen" -NotePropertyValue $false
	}
	$Machine.last_seen = if ($Machine.connected) { Get-Date } elseif ($Machine.last_disconnect) { Convert-UTCtoLocal $UnixDateLowLimit.AddSeconds($Machine.last_disconnect) } else { $false }
}

$DeviceCount_Overview = @()
$DeviceAuditSpreadsheetsUpdated = $false

### This code is unique for each company, lets loop through each company and run this code on each
foreach ($ConfigFile in $CompaniesToAudit) {
	. "$PSScriptRoot\Config Files\Global-Config.ps1" # Reimport Global Config to reset anything that was overridden
	. "$PSScriptRoot\Config Files\$ConfigFile" # Import company config
	Write-Output "============================="
	Write-Output "Starting audit for $Company_Acronym" 
	Write-PSFMessage -Level Verbose -Message "Starting audit on: $Company_Acronym"

	# Connect to JumpCloud (if applicable)
	$JCConnected = $false
	if ($JumpCloudAPIKey -and $JumpCloudAPIKey.Key) {
		try {
			Connect-JCOnline -JumpCloudApiKey $JumpCloudAPIKey.Key -Force -ErrorAction Stop
			$JCConnected = $true
		} catch {
			$JCConnected = $false
		}
	}

	if ($Sophos_Company) {
		$OrgFullName = $Sophos_Company
	} else {
		$OrgFullName = $Company_Acronym
	}

	# Connect to Microsoft Graph (for Azure/Intune)
	$AzureConnected = $false
	if ($AzureAppCredentials -and $Azure_TenantID) {
		$AuthBody = @{
			grant_type		= "client_credentials"
			scope			= "https://graph.microsoft.com/.default"
			client_id		= $AzureAppCredentials.AppID
			client_secret	= $AzureAppCredentials.ClientSecret
		}

		$conn = Invoke-RestMethod `
			-Uri "https://login.microsoftonline.com/$Azure_TenantID/oauth2/v2.0/token" `
			-Method POST `
			-Body $AuthBody

		$AzureToken = ConvertTo-SecureString -String $conn.access_token -AsPlainText -Force
		$MgGraphConnect = Connect-MgGraph -AccessToken $AzureToken
		if ($MgGraphConnect -like "Welcome To Microsoft Graph!*") {
			$AzureConnected = $true
		}
	}
	$AzureConnected = $false # Disable for now until fixed

	############
	# Connect to the Sophos API to get the device list from Sophos
	############

	# Refresh token if it has expired
	if ($SophosToken.expiry -lt (Get-Date)) {
		$SophosToken = Invoke-RestMethod -Method POST -Body $SophosGetTokenBody -ContentType "application/x-www-form-urlencoded" -uri "https://id.sophos.com/api/v2/oauth2/token"
		$SophosJWT = $SophosToken.access_token
		$SophosToken | Add-Member -NotePropertyName expiry -NotePropertyValue $null
		$SophosToken.expiry = (Get-Date).AddSeconds($SophosToken.expires_in)
	}

	# Get the tenants ID and URL
	if ($SophosTenants  -and $SophosTenants.items -and $Sophos_Company) {
		$CompanyInfo = $SophosTenants.items | Where-Object { $_.name -like $Sophos_Company }
		$SophosTenantID = $CompanyInfo.id
		$TenantApiHost = $CompanyInfo.apiHost
	} else {
		$SophosTenantID = $false
		Write-PSFMessage -Level Error -Message "Failed to connect to: Sophos (Tenant not found)"
	}

	# Get the Sophos endpoints
	$SophosEndpoints = $false
	$Sophos_Devices = @()
	if ($SophosTenantID -and $TenantApiHost) {
		$SophosHeader = @{
			Authorization = "Bearer $SophosJWT"
			"X-Tenant-ID" = $SophosTenantID
		}
		$SophosEndpoints = Invoke-RestMethod -Method GET -Headers $SophosHeader -uri ($TenantApiHost + "/endpoint/v1/endpoints?pageSize=500")

		$NextKey = $false
		if ($SophosEndpoints.pages.nextKey) {
			$SophosEndpoints.items = [System.Collections.Generic.List[PSCustomObject]]$SophosEndpoints.items
			$NextKey = $SophosEndpoints.pages.nextKey
		}
		while ($NextKey) {
			$SophosEndpoints_NextPage = $false
			$SophosEndpoints_NextPage = Invoke-RestMethod -Method GET -Headers $SophosHeader -uri ($TenantApiHost + "/endpoint/v1/endpoints?pageFromKey=$NextKey")
			foreach ($Endpoint in $SophosEndpoints_NextPage.items) {
				$SophosEndpoints.items.Add($Endpoint)
			}

			$NextKey = $false
			if ($SophosEndpoints_NextPage.pages.nextKey) {
				$NextKey = $SophosEndpoints_NextPage.pages.nextKey
			}
		}

		if (!$SophosEndpoints) {
			Write-PSFMessage -Level Error -Message "Failed to get: Device List from Sophos"
		}
	} else {
		Write-PSFMessage -Level Error -Message "Failed to connect to: Sophos (No Tenant ID or API Host)"
	}

	if ($SophosEndpoints -and $SophosEndpoints.items) {
		$Sophos_Devices = $SophosEndpoints.items | Where-Object { $_.type -eq "computer" -or $_.type -eq "server" }
	} else {
		$Sophos_Devices = @()
		Write-Warning "Warning! Could not get device list from Sophos!"
	}

	############
	# End Sophos device collection
	###########

	# Get RMM devices
	$attempts = 0
	$RMM_Devices = @()
	while (!$RMM_Devices -or $attempts -le 5) {
		$attempts++
		$Response = Set-DrmmApiParameters -Url $DattoAPIKey.URL -Key $DattoAPIKey.Key -SecretKey $DattoAPIKey.SecretKey 6>&1
		if ($RMM_ID) {
			if ($RMM_ID -match "^\d+$") {
				$CompanyInfo = Get-DrmmAccountSites | Where-Object { $_.id -eq $RMM_ID }
				$RMM_ID = $CompanyInfo.uid
			}
			$RMM_Devices = Get-DrmmSiteDevices $RMM_ID | Where-Object { $_.deviceClass -eq 'device' -and $_.deviceType.category -in @("Laptop", "Desktop", "Server") }
		}

		if (!$RMM_Devices) {
			Start-Sleep -Seconds 5
		}
	}

	if (!$RMM_Devices) {
		Write-PSFMessage -Level Error -Message "Failed to get: Device List from RMM"
		Write-PSFMessage -Level Error -Message "Error: $Response"
	}

	# Get RMM device details if using the API (or grab from cache)
	if ($RMM_Devices) {
		if (!(Test-Path -Path $RMMDeviceDetailsLocation)) {
			New-Item -ItemType Directory -Force -Path $RMMDeviceDetailsLocation | Out-Null
		}
		
		$RMMDeviceDetailsPath = "$($RMMDeviceDetailsLocation)\$($Company_Acronym)_rmm_device_details.json"
		$RMMDeviceDetailsCache = @{}
		if (Test-Path $RMMDeviceDetailsPath) {
			$RMMDeviceDetailsCache = Get-Content -Path $RMMDeviceDetailsPath -Raw | ConvertFrom-Json
		}

		$CurrentDate = Get-Date
		$i = 0
		foreach ($Device in $RMM_Devices) {
			$i++
			[int]$PercentComplete = ($i / $RMM_Devices.count * 100)
			Write-Progress -Activity "Getting RMM device details" -PercentComplete $PercentComplete -Status ("Working - " + $PercentComplete + "%")
			$Device | Add-Member -NotePropertyName serialNumber -NotePropertyValue $false
			$Device | Add-Member -NotePropertyName manufacturer -NotePropertyValue $false
			$Device | Add-Member -NotePropertyName model -NotePropertyValue $false
			$Device | Add-Member -NotePropertyName MacAddresses -NotePropertyValue @()
			$Device | Add-Member -NotePropertyName memory -NotePropertyValue $false
			$Device | Add-Member -NotePropertyName cpus -NotePropertyValue $false
			$Device | Add-Member -NotePropertyName cpuCores -NotePropertyValue $false
			$Device | Add-Member -NotePropertyName url -NotePropertyValue $false

			$LoadFromCache = $false
			if ($RMMDeviceDetailsCache.($Device.uid)) {
				$CacheAge = $false
				if ($RMMDeviceDetailsCache.($Device.uid).lastUpdated) {
					$CacheAge = New-TimeSpan -Start (Get-Date $RMMDeviceDetailsCache.($Device.uid).lastUpdated) -End $CurrentDate
				}
				if (!$CacheAge -or $CacheAge.Days -ge 7) {
					$RMMDeviceDetailsCache.PSObject.Properties.Remove($Device.uid)
				} else {
					$LoadFromCache = $true
				}
			}

			if (!$LoadFromCache) {
				$AuditDevice = Get-DrmmAuditDevice $Device.uid
				if ($AuditDevice) {
					if (!$RMMDeviceDetailsCache.($Device.uid)) {
						if ($RMMDeviceDetailsCache.GetType().Name -like "Hashtable") {
							$RMMDeviceDetailsCache.($Device.uid) = $false
						} else {
							$RMMDeviceDetailsCache | Add-Member -NotePropertyName $Device.uid -NotePropertyValue $false
						}
					}
					$RMMDeviceDetailsCache.($Device.uid) = $AuditDevice
					if (!$RMMDeviceDetailsCache.($Device.uid).lastUpdated) {
						if ($RMMDeviceDetailsCache.($Device.uid).GetType().Name -like "Hashtable") {
							$RMMDeviceDetailsCache.($Device.uid).lastUpdated = $false
						} else {
							$RMMDeviceDetailsCache.($Device.uid) | Add-Member -NotePropertyName lastUpdated -NotePropertyValue $false
						}
					}
					$RMMDeviceDetailsCache.($Device.uid).lastUpdated = $CurrentDate
				}
			} else {
				$CachedDevice = $RMMDeviceDetailsCache.($Device.uid)
			}
			if ($LoadFromCache -or $AuditDevice) {
				$Nics = if ($LoadFromCache) { $CachedDevice.nics } else { $AuditDevice.nics }
				$Device.serialNumber = if ($LoadFromCache) { $CachedDevice.bios.serialNumber } else { $AuditDevice.bios.serialNumber }
				$Device.manufacturer = if ($LoadFromCache) { $CachedDevice.systemInfo.manufacturer } else { $AuditDevice.systemInfo.manufacturer }
				$Device.model = if ($LoadFromCache) { $CachedDevice.systemInfo.model } else { $AuditDevice.systemInfo.model }
				$Device.MacAddresses = @($Nics | Where-Object { $Nic = $_; $_.macAddress -and ($NetworkAdapterBlacklist | Where-Object { $Nic.instance -like $_ }).Count -eq 0 } | Select-Object instance, macAddress)
				$Device.memory = if ($LoadFromCache) { $CachedDevice.systemInfo.totalPhysicalMemory } else { $AuditDevice.systemInfo.totalPhysicalMemory }
				$Device.cpus = if ($LoadFromCache) { $CachedDevice.processors } else { $AuditDevice.processors }
				$Device.cpuCores = if ($LoadFromCache) { $CachedDevice.systemInfo.totalCpuCores } else { $AuditDevice.systemInfo.totalCpuCores }
				$Device.url = if ($LoadFromCache) { $CachedDevice.portalUrl } else { $AuditDevice.portalUrl }
			}
		}

		if ($RMMDeviceDetailsCache -and $RMMDeviceDetailsPath) {
			$RMMDeviceDetailsCache | ConvertTo-Json -Depth 8 | Out-File -FilePath $RMMDeviceDetailsPath
		}
		Write-Progress -Activity "Getting RMM device details" -Status "Ready" -Completed
	}

	# Get all devices from ITG
	$ITG_Devices = @()
	if ($ITGConnected -and $ITG_ID) {
		$ITG_Devices = Get-ITGlueConfigurations -page_size "1000" -organization_id $ITG_ID
		$i = 1
		while ($ITG_Devices.links.next) {
			$i++
			$Configurations_Next = Get-ITGlueConfigurations -page_size "1000" -page_number $i -organization_id $ITG_ID
			if (!$Configurations_Next -or $Configurations_Next.Error) {
				# We got an error querying configurations, wait and try again
				Start-Sleep -Seconds 2
				$Configurations_Next = Get-ITGlueConfigurations -page_size "1000" -page_number $i -organization_id $ITG_ID
		
				if (!$Configurations_Next -or $Configurations_Next.Error) {
					Write-PSFMessage -Level Error -Message "An error occurred trying to get the existing configurations from ITG. Exiting..."
					Write-PSFMessage -Level Error -Message $Configurations_Next.Error
					exit 1
				}
			}
			$ITG_Devices.data += $Configurations_Next.data
			$ITG_Devices.links = $Configurations_Next.links
		}
		if ($ITG_Devices -and $ITG_Devices.data) {
			$ITG_Devices = $ITG_Devices.data
		}
		if (!$ITG_Devices) {
			Write-Warning "There was an issue getting the Configurations from ITG. Skipping org..."
			continue
		}
	}
	$ITG_DevicesHash = @{}
	foreach ($Device in $ITG_Devices) { 
		$ITG_DevicesHash[$Device.id] = $Device
	}

	# Get all devices from Autotask + locations & contacts for spreadsheet exports
	$Autotask_Devices = @()
	if ($AutotaskConnected -and $Autotask_ID) {
		$Autotask_Devices = Get-AutotaskAPIResource -Resource ConfigurationItems -SimpleSearch "companyID eq $Autotask_ID"
		$Autotask_Devices = $Autotask_Devices | Where-Object { $_.isActive -eq "True" }
		$Autotask_Locations = Get-AutotaskAPIResource -Resource CompanyLocations -SimpleSearch "companyID eq $Autotask_ID"
		$Autotask_Locations = $Autotask_Locations | Where-Object { $_.isActive -eq "True" }
		$Autotask_Contacts = Get-AutotaskAPIResource -Resource Contacts -SimpleSearch "companyID eq $Autotask_ID"
		$Autotask_Contacts = $Autotask_Contacts | Where-Object { $_.isActive -eq 1 }
	}
	$Autotask_DevicesHash = @{}
	foreach ($Device in $Autotask_Devices) { 
		$Autotask_DevicesHash[$Device.id] = $Device
	}

	# Get all devices from Azure & Intune
	$Azure_Devices = @()
	$Intune_Devices = @()
	if ($AzureConnected) {
		try {
			$Azure_Devices = Get-MgDevice -All | Where-Object { $_.OperatingSystem -notin @("Android", "iOS") }
		} catch {
			Write-Warning "GDAP is not properly setup. Could not query Azure devices."
			$Azure_Devices = @()
		}
		try {
			$Intune_Devices = Get-MgDeviceManagementManagedDevice | Where-Object { $_.OperatingSystem -notin @("Android", "iOS") }
		} catch {
			$Intune_Devices = @()
		}
	}
	$Azure_DevicesHash = @{}
	$Intune_DevicesHash = @{}
	foreach ($Device in $Azure_Devices) { 
		$Azure_DevicesHash[$Device.id] = $Device
	}
	foreach ($Device in $Intune_Devices) { 
		$Intune_DevicesHash[$Device.Id] = $Device
	}

	# Get all devices from JumpCloud
	$JC_Devices = @()
	if ($JCConnected) {
		Write-Host "Getting JC System"
		$JC_Devices = Get-JCSystem | Where-Object { $_.desktopCapable }
	}
	$JC_DevicesHash = @{}
	foreach ($Device in $JC_Devices) { 
		$JC_DevicesHash[$Device.id] = $Device
	}

	$JC_Users = @()
	if (($JC_Devices | Measure-Object).Count -gt 0) {
		Write-Host "Getting JC Users"
		foreach ($Device in $JC_Devices) {
			$UserInfo = Get-JCSystemUser -SystemID $Device.id
			if ($UserInfo) {
				$JC_Users += $UserInfo
			}
		}
	}

	Write-Output "Imported all devices."
	Write-Output "===================="

	# Filter Screen Connect Devices
	if ($SC_Company.GetType().Name -like "String") {
		$SC_Devices = $SC_Devices_Full | Where-Object { $_.CustomProperty1 -like $SC_Company }
	} else {
		$SC_Devices_Temp = @()
		foreach ($Company in $SC_Company) {
			$SC_Devices_Temp += $SC_Devices_Full | Where-Object { $_.CustomProperty1 -like $Company }
		}
		$SC_Devices = $SC_Devices_Temp
	}

	# Filter columns to only the one's we want
	$SC_Devices = $SC_Devices | Select-Object SessionID, Name, GuestMachineName, GuestMachineSerialNumber, GuestHardwareNetworkAddress, 
												@{Name="DeviceType"; E={if ($_.GuestOperatingSystemName -like "*Server*") { "Server" } else { "Workstation" } }}, 
												@{Name="GuestLastActivityTime"; E={Convert-UTCtoLocal($_.GuestLastActivityTime)}}, @{Name="GuestInfoUpdateTime"; E={Convert-UTCtoLocal($_.GuestInfoUpdateTime)}}, @{Name="GuestLastBootTime"; E={Convert-UTCtoLocal($_.GuestLastBootTime)}},
												GuestLoggedOnUserName, GuestLoggedOnUserDomain, GuestOperatingSystemName, GuestMachineManufacturerName, GuestMachineModel, GuestMachineDescription, GuestSystemMemoryTotalMegabytes, GuestProcessorName, GuestProcessorVirtualCount
	# Sometimes the LastActivityTime field is not set even though the device is on, in these cases it's set to Year 1 
	# Also, if a computer is online but inactive, the infoupdate time can be more recent and a better option
	# We'll create a new GuestLastSeen property here that is the most recent date of the 3 available
	$SC_Devices | Add-Member -NotePropertyName GuestLastSeen -NotePropertyValue $null
	$SC_Devices | ForEach-Object { 
		$MostRecentDate = @($_.GuestLastActivityTime, $_.GuestInfoUpdateTime, $_.GuestLastBootTime) | Sort-Object | Select-Object -Last 1
		$_.GuestLastSeen = $MostRecentDate
	}
	$SC_DevicesHash = @{}
	foreach ($Device in $SC_Devices) { 
		$SC_DevicesHash[$Device.SessionID] = $Device
	}

	$RMM_Devices = $RMM_Devices |
						Select-Object @{Name="Device UID"; E={$_.uid}}, @{Name="Device Hostname"; E={$_.hostname}}, @{Name="Serial Number"; E={$_.serialNumber}}, MacAddresses, 
										@{Name="Device Type"; E={$_.deviceType.category}}, @{Name="Status"; E={$_.online}}, @{Name="Last Seen"; E={ if ($_.online -eq "True") { Get-Date } else { Convert-UTCtoLocal(([datetime]'1/1/1970').AddMilliseconds($_.lastSeen)) } }}, 
										extIpAddress, intIpAddress,
										@{Name="Last User"; E={$_.lastLoggedInUser}}, Domain, @{Name="Operating System"; E={$_.operatingSystem}}, 
										Manufacturer, @{Name="Device Model"; E={$_.model}}, @{Name="Warranty Expiry"; E={$_.warrantyDate}}, @{Name="Device Description"; E={$_.description}}, 
										memory, cpus, cpuCores, url, @{Name="Antivirus"; E={$_.antivirus.antivirusProduct}},
										@{Name="ScreenConnectID"; E={
											$SC = $_.udf.udf13;
											if ($SC -and $SC -like "*$($SCLogin.URL.TrimStart('http').TrimStart('s').TrimStart('://'))*") {
												$Found = $SC -match '\/\/((\{){0,1}[0-9a-fA-F]{8}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{4}\-[0-9a-fA-F]{12}(\}){0,1})\/Join'
												if ($Found -and $Matches[1]) {
													$Matches[1]
												}
											}
										}}, @{Name="SophosEndpointID"; E={ $_.udf.udf4 }}, @{Name="ToDelete"; E={ if ($_.udf.udf30 -eq "True") { $true } else { $false } }}, suspended
	$RMM_DevicesHash = @{}
	foreach ($Device in $RMM_Devices) { 
		$RMM_DevicesHash[$Device."Device UID"] = $Device
	}
	
	$Sophos_Devices = $Sophos_Devices | Select-Object id, @{Name="hostname"; E={$_.hostname -replace '[^\x00-\x7F]+', ''}}, macAddresses, 
											@{Name="type"; E={if ($_.type -eq "computer") { "Workstation"} else { "Server" }}}, 
											lastSeenAt, @{Name="LastUser"; E={($_.associatedPerson.viaLogin -split '\\')[1]}}, @{Name="OS"; E={if ($_.os.name) { $_.os.name } else { "$($_.os.platform) $($_.os.majorVersion).$($_.os.minorVersion)" }}}
	$Sophos_DevicesHash = @{}
	foreach ($Device in $Sophos_Devices) { 
		$Sophos_DevicesHash[$Device.id] = $Device
	}

	foreach ($Device in $Sophos_Devices) {
		$Device | Add-Member -NotePropertyName webID -NotePropertyValue $false
		$EndpointID = $Device.id
		$WebEndpointID = convert_sophos_id_to_web $EndpointID
		$Device.webID = $WebEndpointID
	}

	##############
	# Matching Section
	##############

	# Match devices between the device lists
	Write-Host "Matching devices..."
	$PerformMatching = $true
	$MatchedDevices = @()

	# If we already matched devices today, use the exported json matching file
	if ($MatchedDevicesLocation) {
		if (!(Test-Path -Path $MatchedDevicesLocation)) {
			New-Item -ItemType Directory -Force -Path $MatchedDevicesLocation | Out-Null
		}
		$Day = Get-Date -Format "dd"
		$Month = Get-Date -Format "MM"
		$Year = Get-Date -Format "yyyy"

		$MatchedDevicesJsonPath = "$($MatchedDevicesLocation)\$($Company_Acronym)_matched_devices_$($Year)_$($Month)_$($Day).json"
		if ($MatchedDevicesJsonPath -and (Test-Path -Path $MatchedDevicesJsonPath)) {
			$MatchedDevices = Get-Content -Path $MatchedDevicesJsonPath -Raw | ConvertFrom-Json
			if ($MatchedDevices -and ($MatchedDevices | Measure-Object).Count -gt 0) {
				$PerformMatching = $false
			} else {
				$MatchedDevices = @()
			}
		}
	}

	# Match ScreenConnect devices with themselves to find any duplicates
	foreach ($Device in $SC_Devices) {

		if ($Device.SessionID -in $MatchedDevices.sc_matches) {
			continue
		}

		$Related_SCDevices = @()
		$ForcedMatches = force_match -DeviceID $Device.SessionID -Type "SC"
		$ForcedMatches = $ForcedMatches | Where-Object { $_.type -like 'sc' }

		# Check for force matches first
		if ($ForcedMatches) {
			# Match IDs
			foreach ($Match in ($ForcedMatches | Where-Object { $_.id -ne $false })) {
				$Related_SCDevices += $SC_DevicesHash[$Match.id]
			}
			# If $ForcedMatches contains the id = $false, stop checking for duplicates
			if ((($ForcedMatches | Where-Object { $_.id -eq $false }) | Measure-Object).Count -gt 0) {
				Continue
			}
		}

		$Related_SCDevices += @($SC_Devices | Where-Object { 
			$Device.SessionID -notlike $_.SessionID -and (
				($Device.GuestMachineSerialNumber.Trim() -and $Device.GuestMachineSerialNumber -notin $IgnoreSerials -and $Device.GuestMachineSerialNumber -notlike "123456789*" -and $_.GuestMachineSerialNumber -like $Device.GuestMachineSerialNumber) -or
				($Device.Name.Trim() -and ($_.Name -eq $Device.Name -or $_.GuestMachineName -eq $Device.Name) -and ($_.GuestMachineSerialNumber -like $Device.GuestMachineSerialNumber -or $_.GuestHardwareNetworkAddress -eq $Device.GuestHardwareNetworkAddress)) -or
				($Device.GuestMachineName.Trim() -and ($_.GuestMachineName -eq $Device.GuestMachineName -or $_.Name -eq $Device.GuestMachineName) -and ($_.GuestMachineSerialNumber -like $Device.GuestMachineSerialNumber -or $_.GuestHardwareNetworkAddress -eq $Device.GuestHardwareNetworkAddress))
			)
		})

		# Get mac address matches only separately, then see if we can cross-reference them with RMM
		$MacRelated_SCDevices = @($SC_Devices | Where-Object { 
			$Device.SessionID -notlike $_.SessionID -and (
				($Device.GuestHardwareNetworkAddress -and $_.GuestHardwareNetworkAddress -eq $Device.GuestHardwareNetworkAddress -and $Device.GuestMachineModel -notlike "Virtual Machine") 
			)
		})
		$MacRelated_SCDevices = $MacRelated_SCDevices | Where-Object {
			$Related_RMMDeviceMacs = $RMM_Devices.MacAddresses | Where-Object { $_.macAddress -like $Device.GuestHardwareNetworkAddress }
			if (($Related_RMMDeviceMacs | Measure-Object).Count -gt 0 ) {
				$_
				return
			}
		}
		if (($MacRelated_SCDevices | Measure-Object).Count -gt 0) {
			$Related_SCDevices += $MacRelated_SCDevices
		}
		$Related_SCDevices = @($Related_SCDevices | Sort-Object SessionID -Unique)


		if (($Related_SCDevices | Measure-Object).Count -gt 0) {
			$Related_SCDevices += $Device
			$MatchedDevices += [PsCustomObject]@{
				id = New-Guid
				sc_matches = @($Related_SCDevices.SessionID)
				sc_hostname = @($Related_SCDevices.Name)
				rmm_matches = @()
				rmm_hostname = @()
				sophos_matches = @()
				sophos_hostname = @()
				itg_matches = @()
				itg_hostname = @()
				autotask_matches = @()
				autotask_hostname = @()
				jc_matches = @()
				jc_hostname = @()
				azure_matches = @()
				azure_hostname = @()
				azure_match_warning = @()
				intune_matches = @()
				intune_hostname = @()
				ninite_matches = @()
				ninite_hostname = @()
			}

		} else {
			$MatchedDevices += [PsCustomObject]@{
				id = New-Guid
				sc_matches = @($Device.SessionID)
				sc_hostname = @($Device.Name)
				rmm_matches = @()
				rmm_hostname = @()
				sophos_matches = @()
				sophos_hostname = @()
				itg_matches = @()
				itg_hostname = @()
				autotask_matches = @()
				autotask_hostname = @()
				jc_matches = @()
				jc_hostname = @()
				azure_matches = @()
				azure_hostname = @()
				azure_match_warning = @()
				intune_matches = @()
				intune_hostname = @()
				ninite_matches = @()
				ninite_hostname = @()
			}
		}
	}

	# Match ScreenConnect devices to RMM
	foreach ($MatchedDevice in $MatchedDevices) {
		if (!$PerformMatching -and ($MatchedDevice.rmm_matches | Measure-Object).Count -gt 0) {
			continue
		}

		$Matched_SC_Devices = @()
		foreach ($DeviceID in $MatchedDevice.sc_matches) {
			$Matched_SC_Devices += $SC_DevicesHash[$DeviceID]
		}

		foreach ($Device in $Matched_SC_Devices) {
			$Related_RMMDevices = @()

			$ForcedMatches = force_match -DeviceID $Device.SessionID -Type "SC"
			$ForcedMatches = $ForcedMatches | Where-Object { $_.type -like 'rmm' }
			$IgnoreRMM = @(($ForcedMatches | Where-Object { $_.match -eq $false }).id)
			$ForcedMatches = @($ForcedMatches | Where-Object { $_.id -ne $false -and $_.match -ne $false })

			while (!$Related_RMMDevices) {
				# Forced matches
				if ($ForcedMatches) {
					# Match IDs
					foreach ($Match in $ForcedMatches) {
						$Related_RMMDevices += $RMM_DevicesHash[$Match.id]
					}
				}
				# If $IgnoreRMM contains $False, stop here as that means we dont want to match with any more rmm devices
				if ($IgnoreRMM -contains $false) {
					break;
				}
				# Remove false entries in $IgnoreRMM now so we can easily check against the list of IDs
				$IgnoreRMM = @($IgnoreRMM | Where-Object { $_ })
				# Screen connect session ID
				$Related_RMMDevices += $RMM_Devices | Where-Object { $_.ScreenConnectID -like $Device.SessionID -and $_."Device UID" -notin $IgnoreRMM }
				# Serial number
				if ($Device.GuestMachineSerialNumber.Trim() -and $Device.GuestMachineSerialNumber -notin $IgnoreSerials -and $Device.GuestMachineSerialNumber -notlike "123456789*") {
					$Related_RMMDevices += $RMM_Devices | Where-Object { $_."Serial Number" -like $Device.GuestMachineSerialNumber -and $_."Device UID" -notin $IgnoreRMM }
				}
				# Hostname
				if ($Device.Name.Trim() -and ($Device.GuestOperatingSystemName -notlike "*Mac OS*" -or ($Device.Name -replace "[^0-9]" , '' | Measure-Object -Character).Characters -gt 2)) {
					$Related_RMMDevices += $RMM_Devices | Where-Object { $_."Device Hostname" -eq $Device.Name -and $_."Device UID" -notin $IgnoreRMM }
				}
				if ($Device.GuestMachineName.Trim() -and ($Device.GuestOperatingSystemName -notlike "*Mac OS*" -or ($Device.GuestMachineName -replace "[^0-9]" , '' | Measure-Object -Character).Characters -gt 2)) {
					$Related_RMMDevices += $RMM_Devices | Where-Object { $_."Device Hostname" -eq $Device.GuestMachineName -and $_."Device UID" -notin $IgnoreRMM }
				}
				# Mac address  (if this is a VM, only check this if we haven't found any related devices so far. VM's can cause false positives with this search.)
				if ($Device.GuestHardwareNetworkAddress -and (!$Related_RMMDevices -or $Device.GuestMachineModel -notlike "Virtual Machine")) {
					$MacRelated_RMMDevices = $RMM_Devices | Where-Object { $_.MacAddresses.macAddress -contains $Device.GuestHardwareNetworkAddress -and $_."Device UID" -notin $IgnoreRMM }
					if ($MacRelated_RMMDevices.MacAddresses.instance) {
						$MacRelated_RMMDevices = $MacRelated_RMMDevices | Where-Object { 
							# Remove any usb adapter mac matches unless the hostname also matches
							$ConnectedMac = $_.MacAddresses | Where-Object { $_.macAddress -like $Device.GuestHardwareNetworkAddress }
							if (($ConnectedMac.instance -like "*USB*" -or $ConnectedMac.instance -like "*Ethernet Adapter*" -or $ConnectedMac.instance -like "*Modem Mobile Broadband Device*") -and $Device.Name -notlike $_."Device Hostname" -and $Device.GuestMachineName -notlike $_."Device Hostname") {
								$false
								return
							} else {
								$_
								return
							}
						}
					}
					$Related_RMMDevices += $MacRelated_RMMDevices
				}

				# Description searches as a backup
				if (!$Related_RMMDevices) {
					if ($Device.Name.Trim() -and ($Device.GuestOperatingSystemName -notlike "*Mac OS*" -or ($Device.Name -replace "[^0-9]" , '' | Measure-Object -Character).Characters -gt 2)) {
						$EscapedName = $Device.Name.replace("[", "````[").replace("]", "````]")
						if ($EscapedName -notlike "MacBook-Pro*") {
							$Related_RMMDevices += $RMM_Devices | Where-Object { $_."Device Description" -like "*$($EscapedName)*" -and $_."Device UID" -notin $IgnoreRMM }
						}
					}
					if ($Device.GuestMachineName.Trim() -and ($Device.GuestOperatingSystemName -notlike "*Mac OS*" -or ($Device.GuestMachineName -replace "[^0-9]" , '' | Measure-Object -Character).Characters -gt 2)) {
						$EscapedName2 = $Device.GuestMachineName.replace("[", "````[").replace("]", "````]")
						if ($EscapedName2 -notlike "MacBook-Pro*") {
							$Related_RMMDevices += $RMM_Devices | Where-Object { $_."Device Description" -like "*$($EscapedName2)*" -and $_."Device UID" -notin $IgnoreRMM }
						}
					}
					if (($Related_RMMDevices | Measure-Object).Count -gt 4) {
						# Sanity check in case the name of the device is a little too generic and we get a ton of matches
						$Related_RMMDevices = @()
					}
				}
				if (!$Related_RMMDevices -and $Device.GuestMachineDescription.Trim() -and $Device.GuestMachineDescription.length -gt 5 -and $Device.GuestMachineDescription -like "*-*" -and $Device.GuestMachineDescription.Trim() -notlike "* *") {
					$Related_RMMDevices += $RMM_Devices | Where-Object { $_."Device Description" -like "*$($Device.GuestMachineDescription.Trim())*" -and $_."Device UID" -notin $IgnoreRMM }
				}
				
				$Related_RMMDevices = $Related_RMMDevices | Sort-Object "Device UID" -Unique

				break;
			}

			# If there was more than 1 related device found, try to filter the results down (particularly matches found on hostname)
			if (($Related_RMMDevices | Measure-Object).Count -gt 1) {
				$Related_RMMDevices_Filtered = $Related_RMMDevices | Where-Object { 
					$_.ScreenConnectID -like $Device.SessionID -or
					($Device.GuestMachineSerialNumber.Trim() -and $Device.GuestMachineSerialNumber -notin $IgnoreSerials -and $Device.GuestMachineSerialNumber -notlike "123456789*" -and $_."Serial Number" -like $Device.GuestMachineSerialNumber) -or
					($Device.GuestHardwareNetworkAddress -and $_.MacAddresses.macAddress -contains $Device.GuestHardwareNetworkAddress -and $Device.GuestMachineModel -notlike "Virtual Machine") -or
					($Device.Name.Trim() -and $_."Device Hostname" -eq $Device.Name -and ($_."Serial Number" -like $Device.GuestMachineSerialNumber -or $_.MacAddresses.macAddress -contains $Device.GuestHardwareNetworkAddress)) -or
					($Device.GuestMachineName.Trim() -and $_."Device Hostname" -eq $Device.GuestMachineName -and ($_."Serial Number" -like $Device.GuestMachineSerialNumber -or $_.MacAddresses.macAddress -contains $Device.GuestHardwareNetworkAddress)) -or
					$_."Device UID" -in $ForcedMatches.id
				}
				if (($Related_RMMDevices_Filtered | Measure-Object).Count -gt 0) {
					$Related_RMMDevices = $Related_RMMDevices_Filtered
				}
			}

			# If we found related devices, add them to the matched device list
			if (($Related_RMMDevices | Measure-Object).Count -gt 0) {
				$MatchedDevice.rmm_matches = @($Related_RMMDevices."Device UID")
				$MatchedDevice.rmm_hostname = @($Related_RMMDevices."Device Hostname")
			}
		}
	}

	# Add any missing RMM devices that no matches were found for
	foreach ($Device in $RMM_Devices) {
		if ($Device."Device UID" -in $MatchedDevices.rmm_matches) {
			continue
		}

		$MatchedDevices += [PsCustomObject]@{
			id = New-Guid
			sc_matches = @()
			sc_hostname = @()
			rmm_matches = @($Device."Device UID")
			rmm_hostname = @($Device."Device Hostname")
			sophos_matches = @()
			sophos_hostname = @()
			itg_matches = @()
			itg_hostname = @()
			autotask_matches = @()
			autotask_hostname = @()
			jc_matches = @()
			jc_hostname = @()
			azure_matches = @()
			azure_hostname = @()
			azure_match_warning = @()
			intune_matches = @()
			intune_hostname = @()
			ninite_matches = @()
			ninite_hostname = @()
		}
	}

	# Match Sophos devices
	foreach ($Device in $Sophos_Devices) {
		if (!$PerformMatching -and $Device.id -in $MatchedDevices.sophos_matches) {
			continue
		}

		$CleanDeviceName = $Device.hostname -replace '\W', ''
		$RelatedDevices = @()
		$AddedForcedMatches = @()

		$ForcedMatches = force_match -DeviceID $Device.id -Type "Sophos"
		$ForcedMatches = $ForcedMatches | Where-Object { $_.type -like 'sc' -or $_.type -like 'rmm' }
		$IgnoreSC = @(($ForcedMatches | Where-Object { $_.type -like 'sc' -and $_.match -eq $false }).id)
		$IgnoreRMM = @(($ForcedMatches | Where-Object { $_.type -like 'rmm' -and $_.match -eq $false }).id)
		$ForcedMatches = @($ForcedMatches | Where-Object { $_.id -ne $false -and $_.match -ne $false })

		# Forced matches
		if ($ForcedMatches) {
			# Match IDs
			foreach ($Match in $ForcedMatches) {
				if ($Match.type -like 'rmm') {
					$RMMMatches = @($MatchedDevices | Where-Object { $_.rmm_matches -contains $Match.id })
					$RelatedDevices += $RMMMatches
					$AddedForcedMatches += $RMMMatches.id
				} elseif ($Match.type -like 'sc') {
					$SCMatches = @($MatchedDevices | Where-Object { $_.sc_matches -contains $Match.id })
					$RelatedDevices += $SCMatches
					$AddedForcedMatches += $SCMatches.id
				}
			}
		}
		# If $IgnoreRMM and $IgnoreSC both contain $False, stop here as that means we dont want to match with any more devices. Create an empty entry first if we havent force matched any devices already.
		if ($IgnoreRMM -contains $false -and $IgnoreSC -contains $false) {
			if (!$DidForceMatches) {
				$MatchedDevices += [PsCustomObject]@{
					id = New-Guid
					sc_matches = @()
					sc_hostname = @()
					rmm_matches = @()
					rmm_hostname = @()
					sophos_matches = @($Device.id)
					sophos_hostname = @($Device.hostname)
					itg_matches = @()
					itg_hostname = @()
					autotask_matches = @()
					autotask_hostname = @()
					jc_matches = @()
					jc_hostname = @()
					azure_matches = @()
					azure_hostname = @()
					azure_match_warning = @()
					intune_matches = @()
					intune_hostname = @()
					ninite_matches = @()
					ninite_hostname = @()
				}
			}
			continue;
		}

		# Try first to match the Sophos device to an RMM device by endpoint ID (in UDF 4)
		$Related_RMMDevice = $RMM_Devices | Where-Object { $_.SophosEndpointID -eq $Device.webId }

		if (($Related_RMMDevice | Measure-Object).Count -gt 0) {
			$Related_RMMDevice | Foreach-Object {
				$RMMDevice = $_
				$RelatedDevices += $MatchedDevices | Where-Object { $_.rmm_matches -contains $RMMDevice.'Device UID' }
			}
		} else {

			# Sophos to SC and RMM Matches (Fallback for no endpoint ID match to RMM)
			# If the device name is more than 15 characters, do a partial search as Sophos will get the full computer name, but SC and RMM will get the hostname (which is limited to 15 characters)

			# Sophos to SC Matches
			if ($IgnoreSC -notcontains $false -and ($Device.hostname -in $MatchedDevices.sc_hostname -or $CleanDeviceName -in ($MatchedDevices.sc_hostname -replace '\W', '') -or 
				($Device.hostname.length -gt 15 -and (($MatchedDevices.sc_hostname | Where-Object { $Device.hostname -like "$([Management.Automation.WildcardPattern]::Escape($_))*" }).count -gt 0))))
			{
				$RelatedDevices += ($MatchedDevices | Where-Object { 
					($Device.hostname -in $_.sc_hostname -or $CleanDeviceName -in ($_.sc_hostname -replace '\W', '')) -and 
					(!$_.sc_matches -or !$IgnoreSC -or ($_.sc_matches | Where-Object { $_ -notin $IgnoreSC })) -and 
					(!$_.rmm_matches -or !$IgnoreRMM -or ($_.rmm_matches | Where-Object { $_ -notin $IgnoreRMM })) -and
					($IgnoreRMM -notcontains $false -or !$_.rmm_matches) -and ($IgnoreSC -notcontains $false -or !$_.sc_matches)
				})
				# Try a partial hostname match for long hostnames (where they might get cutoff)
				if ($Device.hostname.length -gt 15) {
					$RelatedDevices += ($MatchedDevices | Where-Object { 
						($_.sc_hostname | Where-Object { $Device.hostname -like "$([Management.Automation.WildcardPattern]::Escape($_))*" }).count -gt 0 -and 
						(!$_.sc_matches -or !$IgnoreSC -or ($_.sc_matches | Where-Object { $_ -notin $IgnoreSC })) -and 
						(!$_.rmm_matches -or !$IgnoreRMM -or ($_.rmm_matches | Where-Object { $_ -notin $IgnoreRMM })) -and
						($IgnoreRMM -notcontains $false -or !$_.rmm_matches) -and ($IgnoreSC -notcontains $false -or !$_.sc_matches)
					})
				}
			}

			# Sophos to RMM Matches
			if ($IgnoreRMM -notcontains $false -and ($Device.hostname -in $MatchedDevices.rmm_hostname -or $CleanDeviceName -in ($MatchedDevices.rmm_hostname -replace '\W', '') -or
				($Device.hostname.length -gt 15 -and ($MatchedDevices.rmm_hostname | Where-Object { $Device.hostname -like "$([Management.Automation.WildcardPattern]::Escape($_))*" }).count -gt 0))) 
			{
				$RelatedDevices += ($MatchedDevices | Where-Object { 
					($Device.hostname -in $_.rmm_hostname -or $CleanDeviceName -in ($_.rmm_hostname -replace '\W', '')) -and 
					(!$_.sc_matches -or !$IgnoreSC -or ($_.sc_matches | Where-Object { $_ -notin $IgnoreSC })) -and 
					(!$_.rmm_matches -or !$IgnoreRMM -or ($_.rmm_matches | Where-Object { $_ -notin $IgnoreRMM })) -and
					($IgnoreRMM -notcontains $false -or !$_.rmm_matches) -and ($IgnoreSC -notcontains $false -or !$_.sc_matches)
				})
				# Try a partial hostname match for long hostnames (where they might get cutoff)
				if (!$RelatedDevices -and $Device.hostname.length -gt 15) {
					$RelatedDevices += ($MatchedDevices | Where-Object { 
						($_.rmm_hostname | Where-Object { $Device.hostname -like "$([Management.Automation.WildcardPattern]::Escape($_))*" }).count -gt 0 -and 
						(!$_.sc_matches -or !$IgnoreSC -or ($_.sc_matches | Where-Object { $_ -notin $IgnoreSC })) -and 
						(!$_.rmm_matches -or !$IgnoreRMM -or ($_.rmm_matches | Where-Object { $_ -notin $IgnoreRMM })) -and
						($IgnoreRMM -notcontains $false -or !$_.rmm_matches) -and ($IgnoreSC -notcontains $false -or !$_.sc_matches)
					})
				}
			}
		}

		# If multiple related devices, narrow down to those that match on Mac Address as well and keep forced matches
		if ($Device.macAddresses -and $RelatedDevices -and ($RelatedDevices | Measure-Object).Count -gt 1) {
			$RMMMacMatches = $RMM_Devices | Where-Object { $_.MacAddresses.macAddress | Where-Object { $Device.macAddresses -contains $_ } } 
			$SCMacMatches = $SC_Devices | Where-Object { $Device.macAddresses -contains $_.GuestHardwareNetworkAddress }

			$RelatedDevices_MACMatch = @($RelatedDevices | Where-Object { 
				$RelatedDevice = $_;
				($RelatedDevice.sc_matches | Where-Object { $SCMacMatches.SessionID -contains $_ }) -or 
				($RelatedDevice.rmm_matches | Where-Object { $RMMMacMatches."Device UID" -contains $_ }) 
			})

			if (($RelatedDevices_MACMatch | Measure-Object).count -gt 0) {
				$RelatedDevices_MACMatch += @($RelatedDevices | Where-Object {$_.id -in $AddedForcedMatches }) # Add forced matches in
				$RelatedDevices = $RelatedDevices_MACMatch
			}
		}

		# If we could not match the hostname and this is a macOS devices, lets try matching on MAC address (as MacOS tend to be a bit more difficult to match on hostname)
		if (!$RelatedDevices -and $Device.OS -like "*macOS*" -and $Device.macAddresses -and (($Device.macAddresses | Where-Object { $RMM_Devices.MacAddresses.macAddress -contains $_ }) -or ($Device.macAddresses | Where-Object { $SC_Devices.GuestHardwareNetworkAddress -contains $_ }))) {
			$RMMMacMatches = $RMM_Devices | Where-Object { $_.MacAddresses | Where-Object { $Device.macAddresses -contains $_.macAddress } } 
			$SCMacMatches = $SC_Devices | Where-Object { $Device.macAddresses -contains $_.GuestHardwareNetworkAddress }

			$RelatedDevices += $MatchedDevices | Where-Object { 
				$RelatedDevice = $_;
				(($RelatedDevice.sc_matches | Where-Object { $SCMacMatches.SessionID -contains $_ }) -or 
				($RelatedDevice.rmm_matches | Where-Object { $RMMMacMatches."Device UID" -contains $_ })) -and
				(!$_.sc_matches -or !$IgnoreSC -or ($_.sc_matches | Where-Object { $_ -notin $IgnoreSC })) -and 
				(!$_.rmm_matches -or !$IgnoreRMM -or ($_.rmm_matches | Where-Object { $_ -notin $IgnoreRMM })) -and
				($IgnoreRMM -notcontains $false -or !$_.rmm_matches) -and ($IgnoreSC -notcontains $false -or !$_.sc_matches)
			}
		}

		$RelatedDevices = $RelatedDevices | Sort-Object id -Unique

		# Got all related devices, updated $MatchedDevices
		if (($RelatedDevices | Measure-Object).Count -gt 0) {
			foreach ($MatchedDevice in $RelatedDevices) {
				$MatchedDevice.sophos_matches += @($Device.id)
				$MatchedDevice.sophos_hostname += @($Device.hostname)
			}
		} else {
			# No related devices found, try checking RMM descriptions (for manual matches)
			$Related_RMMDevices = $RMM_Devices | Where-Object { $_."Device Description" -like "*$($Device.hostname)*" -or $_."Device Description" -like "*$($CleanDeviceName)*" -or ($_."Device Description" -replace '\W', '') -like "*$($CleanDeviceName)*" }
			$Related_RMMDevices = $Related_RMMDevices | Sort-Object "Device UID" -Unique

			$RelatedDevices = @()
			if (($Related_RMMDevices | Measure-Object).Count -gt 0) {
				foreach ($RMMDevice in $Related_RMMDevices) {
					$RelatedDevices += ($MatchedDevices | Where-Object { 
						$RMMDevice."Device UID" -in $_.rmm_matches -and
						(!$_.sc_matches -or !$IgnoreSC -or ($_.sc_matches | Where-Object { $_ -notin $IgnoreSC })) -and 
						(!$_.rmm_matches -or !$IgnoreRMM -or ($_.rmm_matches | Where-Object { $_ -notin $IgnoreRMM })) -and
						($IgnoreRMM -notcontains $false -or !$_.rmm_matches) -and ($IgnoreSC -notcontains $false -or !$_.sc_matches)
					})
				}
			}

			if (($RelatedDevices | Measure-Object).Count -gt 0) {
				foreach ($MatchedDevice in $RelatedDevices) {
					$MatchedDevice.sophos_matches += @($Device.id)
					$MatchedDevice.sophos_hostname += @($Device.hostname)
				}
			} else {

				# Still no related devices found, add an empty match
				$MatchedDevices += [PsCustomObject]@{
					id = New-Guid
					sc_matches = @()
					sc_hostname = @()
					rmm_matches = @()
					rmm_hostname = @()
					sophos_matches = @($Device.id)
					sophos_hostname = @($Device.hostname)
					itg_matches = @()
					itg_hostname = @()
					autotask_matches = @()
					autotask_hostname = @()
					jc_matches = @()
					jc_hostname = @()
					azure_matches = @()
					azure_hostname = @()
					azure_match_warning = @()
					intune_matches = @()
					intune_hostname = @()
					ninite_matches = @()
					ninite_hostname = @()
				}
			}
		}
	}

	# Match devices to ITG
	if ($ITGConnected) {
		foreach ($Device in $ITG_Devices) {
			if (!$PerformMatching -and $Device.id -in $MatchedDevices.itg_matches) {
				continue
			}

			$RelatedDevices = @()

			# ITG to RMM Matches
			$Related_RMMDevices = @()
			$Related_RMMDevices += ($RMM_Devices | Where-Object {
				$Device.attributes.'asset-tag' -eq $_.'Device UID' -or 
				$Device.attributes.name -like $_.'Device Hostname' -or 
				($Device.attributes.hostname -like $_.'Device Hostname' -and $Device.attributes.hostname) -or 
				$Device.attributes.name -like $_.'Device Description' -or 
				($Device.attributes.hostname -like $_.'Device Description' -and $Device.attributes.hostname) -or 
				($Device.attributes.'serial-number' -like $_.'Serial Number' -and $Device.attributes.'serial-number' -and $Device.attributes.'serial-number' -notin $IgnoreSerials -and $Device.attributes.'serial-number' -notlike "123456789*")
			})

			# Narrow down if more than 1 device found
			if (($Related_RMMDevices | Measure-Object).Count -gt 1) {
				$Related_RMMDevices_Filtered = $Related_RMMDevices | Where-Object { 
					$Device.attributes.name -like $_.'Device Hostname' -and
					$Device.attributes.'serial-number' -like $_.'Serial Number'
				}
				if (($Related_RMMDevices_Filtered | Measure-Object).Count -gt 0) {
					$Related_RMMDevices = $Related_RMMDevices_Filtered
				}
			}
			if (($Related_RMMDevices | Measure-Object).Count -gt 1) {
				$Related_RMMDevices_Filtered = $Related_RMMDevices | Where-Object { 
					$Device.attributes.'asset-tag' -eq $_.'Device UID'
				}
				if (($Related_RMMDevices_Filtered | Measure-Object).Count -gt 0) {
					$Related_RMMDevices = $Related_RMMDevices_Filtered
				}
			}

			# Get existing matches and connect
			$Related_RMMDevices | ForEach-Object {
				$RMM_DeviceID = $_."Device UID"
				$RelatedDevices += ($MatchedDevices | Where-Object { $RMM_DeviceID -in $_.rmm_matches })
			}


			# ITG to SC Matches (fallback)
			if (!$RelatedDevices) {
				$Related_SCDevices = @()
				$Related_SCDevices += ($SC_Devices | Where-Object {
					$Device.attributes.name -like $_.Name -or 
					($Device.attributes.hostname -like $_.Name -and $Device.attributes.hostname) -or 
					$Device.attributes.name -like $_.GuestMachineName -or 
					($Device.attributes.hostname -like $_.GuestMachineName -and $Device.attributes.hostname) -or 
					($Device.attributes.'serial-number' -like $_.GuestMachineSerialNumber -and $Device.attributes.'serial-number' -and $Device.attributes.'serial-number' -notin $IgnoreSerials -and $Device.attributes.'serial-number' -notlike "123456789*")
				})

				# Narrow down if more than 1 device found
				if (($Related_SCDevices | Measure-Object).Count -gt 1) {
					$Related_SCDevices_Filtered = $Related_SCDevices | Where-Object { 
						$Device.attributes.'serial-number' -like $_.GuestMachineSerialNumber
					}
					if (($Related_SCDevices_Filtered | Measure-Object).Count -gt 0) {
						$Related_SCDevices = $Related_SCDevices_Filtered
					}
				}

				# Get existing matches and connect
				$Related_SCDevices | ForEach-Object {
					$SC_DeviceID = $_.SessionID
					$RelatedDevices += ($MatchedDevices | Where-Object { $SC_DeviceID -in $_.sc_matches })
				}
			}

			# ITG to Sophos Matches (fallback)
			if (!$RelatedDevices) {
				$Related_SophosDevices = @()
				$Related_SophosDevices += ($Sophos_Devices | Where-Object {
					$Device.attributes.name -eq $_.hostname -or
					($Device.attributes.hostname -eq $_.hostname -and $Device.attributes.hostname)
				})

				# If matching is for MacOS devices and multiple are found, skip matching
				if (($Related_SophosDevices | Measure-Object).Count -gt 1 -and $Related_SophosDevices.OS -like "*macOS*") {
					continue
				}

				# Get existing matches and connect
				$Related_SophosDevices | ForEach-Object {
					$Sophos_DeviceID = $_.id
					$RelatedDevices += ($MatchedDevices | Where-Object { $Sophos_DeviceID -in $_.sophos_matches })
				}
			}

			$RelatedDevices = $RelatedDevices | Sort-Object id -Unique

			# Got all related devices, updated $MatchedDevices
			if (($RelatedDevices | Measure-Object).Count -gt 0) {
				foreach ($MatchedDevice in $RelatedDevices) {
					$MatchedDevice.itg_matches += @($Device.id)
					$MatchedDevice.itg_hostname += @($Device.attributes.name)
				}
			}
		}
	}

	# Match devices to Autotask
	if ($AutotaskConnected) {
		foreach ($Device in $Autotask_Devices) {
			if (!$PerformMatching -and $Device.id -in $MatchedDevices.autotask_matches) {
				continue
			}
			$RelatedDevices = @()

			# Autotask to RMM Matches
			$Related_RMMDevices = @()
			$Related_RMMDevices += ($RMM_Devices | Where-Object {
				($Device.rmmDeviceUID -eq $_.'Device UID' -and $Device.rmmDeviceUID) -or 
				($Device.referenceNumber -eq $_.'Device UID' -and $Device.referenceNumber) -or 
				$Device.referenceTitle -like $_.'Device Hostname' -or 
				($Device.rmmDeviceAuditHostname -like $_.'Device Hostname' -and $Device.rmmDeviceAuditHostname) -or 
				($Device.serialNumber -like $_.'Serial Number' -and $Device.serialNumber -and $Device.serialNumber -notin $IgnoreSerials -and $Device.serialNumber -notlike "123456789*")
			})

			# Narrow down if more than 1 device found
			if (($Related_RMMDevices | Measure-Object).Count -gt 1) {
				$Related_RMMDevices_Filtered = $Related_RMMDevices | Where-Object { 
					$Device.rmmDeviceUID -eq $_.'Device UID'
				}
				if (($Related_RMMDevices_Filtered | Measure-Object).Count -gt 0) {
					$Related_RMMDevices = $Related_RMMDevices_Filtered
				}
			}
			if (($Related_RMMDevices | Measure-Object).Count -gt 1) {
				$Related_RMMDevices_Filtered = $Related_RMMDevices | Where-Object { 
					$Device.referenceTitle -like $_.'Device Hostname' -and
					$Device.serialNumber -like $_.'Serial Number'
				}
				if (($Related_RMMDevices_Filtered | Measure-Object).Count -gt 0) {
					$Related_RMMDevices = $Related_RMMDevices_Filtered
				}
			}
			if (($Related_RMMDevices | Measure-Object).Count -gt 1) {
				$Related_RMMDevices_Filtered = $Related_RMMDevices | Where-Object { 
					$Device.referenceNumber -eq $_.'Device UID'
				}
				if (($Related_RMMDevices_Filtered | Measure-Object).Count -gt 0) {
					$Related_RMMDevices = $Related_RMMDevices_Filtered
				}
			}

			# Get existing matches and connect
			$Related_RMMDevices | ForEach-Object {
				$RMM_DeviceID = $_."Device UID"
				$RelatedDevices += ($MatchedDevices | Where-Object { $RMM_DeviceID -in $_.rmm_matches })
			}

			# Autotask to ITG Matches (fallback)
			$Related_ITGDevices = @()
			$Related_ITGDevices += ($ITG_Devices | Where-Object {
				($Device.rmmDeviceUID -eq $_.attributes.'asset-tag' -and $Device.rmmDeviceUID) -or 
				($Device.referenceNumber -eq $_.attributes.'asset-tag' -and $Device.referenceNumber) -or 
				$Device.referenceTitle -like $_.attributes.name -or 
				$Device.referenceTitle -like $_.attributes.hostname -or 
				($Device.rmmDeviceAuditHostname -like $_.attributes.name -and $Device.rmmDeviceAuditHostname) -or 
				($Device.rmmDeviceAuditHostname -like $_.attributes.hostname -and $Device.rmmDeviceAuditHostname) -or 
				($Device.rmmDeviceAuditDescription -like $_.attributes.name -and $Device.rmmDeviceAuditDescription) -or 
				($Device.rmmDeviceAuditDescription -like $_.attributes.hostname -and $Device.rmmDeviceAuditDescription) -or 
				($Device.serialNumber -like $_.attributes.'serial-number' -and $Device.serialNumber -and $Device.serialNumber -notin $IgnoreSerials -and $Device.serialNumber -notlike "123456789*")
			})

			# Narrow down if more than 1 device found
			if (($Related_ITGDevices | Measure-Object).Count -gt 1) {
				$Related_ITGDevices_Filtered = $Related_ITGDevices | Where-Object { 
					$Device.referenceTitle -like $_.attributes.name -and
					$Device.serialNumber -like $_.attributes.'serial-number'
				}
				if (($Related_ITGDevices_Filtered | Measure-Object).Count -gt 0) {
					$Related_ITGDevices = $Related_ITGDevices_Filtered
				}
			}
			if (($Related_ITGDevices | Measure-Object).Count -gt 1) {
				$Related_ITGDevices_Filtered = $Related_ITGDevices | Where-Object { 
					$Device.rmmDeviceUID -eq $_.attributes.'asset-tag' -or
					$Device.referenceNumber -eq $_.attributes.'asset-tag'
				}
				if (($Related_ITGDevices_Filtered | Measure-Object).Count -gt 0) {
					$Related_ITGDevices = $Related_ITGDevices_Filtered
				}
			}

			# Get existing matches and connect
			$Related_ITGDevices | ForEach-Object {
				$ITG_DeviceID = $_.id
				$RelatedDevices += ($MatchedDevices | Where-Object { $ITG_DeviceID -in $_.itg_matches })
			}

			$RelatedDevices = $RelatedDevices | Sort-Object id -Unique

			# Got all related devices, updated $MatchedDevices
			if (($RelatedDevices | Measure-Object).Count -gt 0) {
				foreach ($MatchedDevice in $RelatedDevices) {
					$MatchedDevice.autotask_matches += @($Device.id)
					$MatchedDevice.autotask_hostname += @($Device.referenceTitle)
				}
			}
		}
	}

	# Match devices to JumpCloud
	if ($JCConnected) {
		foreach ($Device in $JC_Devices) {
			if (!$PerformMatching -and $Device.id -in $MatchedDevices.jc_matches) {
				continue
			}
			$RelatedDevices = @()

			# JumpCloud to RMM Matches
			$Related_RMMDevices = @()
			$Related_RMMDevices += ($RMM_Devices | Where-Object { 
				$Device.displayName -like $_.'Device Hostname' -or
				($Device.hostname -like $_.'Device Hostname' -and $Device.hostname) -or 
				$Device.displayName -like $_.'Device Description' -or 
				($Device.hostname -like $_.'Device Description' -and $Device.hostname) -or 
				($Device.serialNumber -like $_.'Serial Number' -and $Device.serialNumber -and $Device.serialNumber -notin $IgnoreSerials -and $Device.serialNumber -notlike "123456789*")
			})

			# Narrow down if more than 1 device found
			if (($Related_RMMDevices | Measure-Object).Count -gt 1) {
				$Related_RMMDevices_Filtered = $Related_RMMDevices | Where-Object { 
					$Device.hostname -like $_.'Device Hostname' -and
					$Device.serialNumber -like $_.'Serial Number'
				}
				if (($Related_RMMDevices_Filtered | Measure-Object).Count -gt 0) {
					$Related_RMMDevices = $Related_RMMDevices_Filtered
				}
			}
			if (($Related_RMMDevices | Measure-Object).Count -gt 1) {
				$Related_RMMDevices_Filtered = $Related_RMMDevices | Where-Object { 
					$Device.serialNumber -eq $_.'Serial Number'
				}
				if (($Related_RMMDevices_Filtered | Measure-Object).Count -gt 0) {
					$Related_RMMDevices = $Related_RMMDevices_Filtered
				}
			}

			# Get existing matches and connect
			$Related_RMMDevices | ForEach-Object {
				$RMM_DeviceID = $_."Device UID"
				$RelatedDevices += ($MatchedDevices | Where-Object { $RMM_DeviceID -in $_.rmm_matches })
			}


			# JumpCloud to SC Matches (fallback)
			if (!$RelatedDevices) {
				$Related_SCDevices = @()
				$Related_SCDevices += ($SC_Devices | Where-Object {
					$Device.displayName -like $_.Name -or 
					($Device.hostname -like $_.Name -and $Device.hostname) -or 
					$Device.displayName -like $_.GuestMachineName -or 
					($Device.hostname -like $_.GuestMachineName -and $Device.hostname) -or 
					($Device.serialNumber -like $_.GuestMachineSerialNumber -and $Device.serialNumber -and $Device.serialNumber -notin $IgnoreSerials -and $Device.serialNumber -notlike "123456789*")
				})

				# Narrow down if more than 1 device found
				if (($Related_SCDevices | Measure-Object).Count -gt 1) {
					$Related_SCDevices_Filtered = $Related_SCDevices | Where-Object { 
						$Device.hostname -like $_.Name -and
						$Device.serialNumber -like $_.GuestMachineSerialNumber
					}
					if (($Related_SCDevices_Filtered | Measure-Object).Count -gt 0) {
						$Related_SCDevices = $Related_SCDevices_Filtered
					}
				}
				if (($Related_SCDevices | Measure-Object).Count -gt 1) {
					$Related_SCDevices_Filtered = $Related_SCDevices | Where-Object { 
						$Device.hostname -like $_.GuestMachineName -and
						$Device.serialNumber -like $_.GuestMachineSerialNumber
					}
					if (($Related_SCDevices_Filtered | Measure-Object).Count -gt 0) {
						$Related_SCDevices = $Related_SCDevices_Filtered
					}
				}
				if (($Related_SCDevices | Measure-Object).Count -gt 1) {
					$Related_SCDevices_Filtered = $Related_SCDevices | Where-Object { 
						$Device.serialNumber -like $_.GuestMachineSerialNumber
					}
					if (($Related_SCDevices_Filtered | Measure-Object).Count -gt 0) {
						$Related_SCDevices = $Related_SCDevices_Filtered
					}
				}

				# Get existing matches and connect
				$Related_SCDevices | ForEach-Object {
					$SC_DeviceID = $_.SessionID
					$RelatedDevices += ($MatchedDevices | Where-Object { $SC_DeviceID -in $_.sc_matches })
				}
			}

			# JumpCloud to Sophos Matches (fallback)
			if (!$RelatedDevices) {
				$Related_SophosDevices = @()
				$Related_SophosDevices += ($Sophos_Devices | Where-Object {
					$Device.displayName -eq $_.hostname -or
					($Device.hostname -like $_.hostname -and $Device.hostname)
				})

				# If matching is for MacOS devices and multiple are found, skip matching
				if (($Related_SophosDevices | Measure-Object).Count -gt 1 -and $Related_SophosDevices.OS -like "*macOS*") {
					continue
				}

				# Get existing matches and connect
				$Related_SophosDevices | ForEach-Object {
					$Sophos_DeviceID = $_.id
					$RelatedDevices += ($MatchedDevices | Where-Object { $Sophos_DeviceID -in $_.sophos_matches })
				}
			}

			$RelatedDevices = $RelatedDevices | Sort-Object id -Unique

			# Got all related devices, updated $MatchedDevices
			if (($RelatedDevices | Measure-Object).Count -gt 0) {
				foreach ($MatchedDevice in $RelatedDevices) {
					$MatchedDevice.jc_matches += @($Device.id)
					$MatchedDevice.jc_hostname += @(if ($Device.hostname) { $Device.hostname } else { $Device.displayName })
				}
			}
		}

		# Add any missing JC devices that no matches were found for
		foreach ($Device in $JC_Devices) {
			if ($Device.id -in $MatchedDevices.jc_matches) {
				continue
			}

			$MatchedDevices += [PsCustomObject]@{
				id = New-Guid
				sc_matches = @()
				sc_hostname = @()
				rmm_matches = @()
				rmm_hostname = @()
				sophos_matches = @()
				sophos_hostname = @()
				itg_matches = @()
				itg_hostname = @()
				autotask_matches = @()
				autotask_hostname = @()
				jc_matches = @($Device.id)
				jc_hostname = @(if ($Device.hostname) { $Device.hostname } else { $Device.displayName })
				azure_matches = @()
				azure_hostname = @()
				azure_match_warning = @()
				intune_matches = @()
				intune_hostname = @()
				ninite_matches = @()
				ninite_hostname = @()
			}
		}
	}

	# Match devices to Intune
	if ($AzureConnected) {
		foreach ($Device in $Intune_Devices) {
			$RelatedDevices = @()

			# Intune to RMM Matches
			$Related_RMMDevices = @()
			$Related_RMMDevices += ($RMM_Devices | Where-Object { 
				$Device.DeviceName -like $_.'Device Hostname' -or
				$Device.DeviceName -like $_.'Device Description' -or 
				($Device.SerialNumber -like $_.'Serial Number' -and $Device.SerialNumber -and $Device.SerialNumber -notin $IgnoreSerials -and $Device.SerialNumber -notlike "123456789*")
			})

			# Narrow down if more than 1 device found
			if (($Related_RMMDevices | Measure-Object).Count -gt 1) {
				$Related_RMMDevices_Filtered = $Related_RMMDevices | Where-Object { 
					$Device.DeviceName -like $_.'Device Hostname' -and
					$Device.SerialNumber -like $_.'Serial Number'
				}
				if (($Related_RMMDevices_Filtered | Measure-Object).Count -gt 0) {
					$Related_RMMDevices = $Related_RMMDevices_Filtered
				}
			}
			if (($Related_RMMDevices | Measure-Object).Count -gt 1) {
				$Related_RMMDevices_Filtered = $Related_RMMDevices | Where-Object { 
					$Device.SerialNumber -eq $_.'Serial Number'
				}
				if (($Related_RMMDevices_Filtered | Measure-Object).Count -gt 0) {
					$Related_RMMDevices = $Related_RMMDevices_Filtered
				}
			}

			# Get existing matches and connect
			$Related_RMMDevices | ForEach-Object {
				$RMM_DeviceID = $_."Device UID"
				$RelatedDevices += ($MatchedDevices | Where-Object { $RMM_DeviceID -in $_.rmm_matches })
			}


			# Intune to SC Matches (fallback)
			if (!$RelatedDevices) {
				$Related_SCDevices = @()
				$Related_SCDevices += ($SC_Devices | Where-Object {
					$Device.DeviceName -like $_.Name -or 
					$Device.DeviceName -like $_.GuestMachineName -or 
					($Device.SerialNumber -like $_.GuestMachineSerialNumber -and $Device.SerialNumber -and $Device.SerialNumber -notin $IgnoreSerials -and $Device.SerialNumber -notlike "123456789*")
				})

				# Narrow down if more than 1 device found
				if (($Related_SCDevices | Measure-Object).Count -gt 1) {
					$Related_SCDevices_Filtered = $Related_SCDevices | Where-Object { 
						$Device.DeviceName -like $_.Name -and
						$Device.SerialNumber -like $_.GuestMachineSerialNumber
					}
					if (($Related_SCDevices_Filtered | Measure-Object).Count -gt 0) {
						$Related_SCDevices = $Related_SCDevices_Filtered
					}
				}
				if (($Related_SCDevices | Measure-Object).Count -gt 1) {
					$Related_SCDevices_Filtered = $Related_SCDevices | Where-Object { 
						$Device.DeviceName -like $_.GuestMachineName -and
						$Device.SerialNumber -like $_.GuestMachineSerialNumber
					}
					if (($Related_SCDevices_Filtered | Measure-Object).Count -gt 0) {
						$Related_SCDevices = $Related_SCDevices_Filtered
					}
				}
				if (($Related_SCDevices | Measure-Object).Count -gt 1) {
					$Related_SCDevices_Filtered = $Related_SCDevices | Where-Object { 
						$Device.SerialNumber -like $_.GuestMachineSerialNumber
					}
					if (($Related_SCDevices_Filtered | Measure-Object).Count -gt 0) {
						$Related_SCDevices = $Related_SCDevices_Filtered
					}
				}

				# Get existing matches and connect
				$Related_SCDevices | ForEach-Object {
					$SC_DeviceID = $_.SessionID
					$RelatedDevices += ($MatchedDevices | Where-Object { $SC_DeviceID -in $_.sc_matches })
				}
			}

			# Intune to Sophos Matches (fallback)
			if (!$RelatedDevices) {
				$Related_SophosDevices = @()
				$Related_SophosDevices += ($Sophos_Devices | Where-Object {
					$Device.DeviceName -eq $_.hostname
				})

				# If matching is for MacOS devices and multiple are found, skip matching
				if (($Related_SophosDevices | Measure-Object).Count -gt 1 -and $Related_SophosDevices.OS -like "*macOS*") {
					continue
				}

				# Get existing matches and connect
				$Related_SophosDevices | ForEach-Object {
					$Sophos_DeviceID = $_.id
					$RelatedDevices += ($MatchedDevices | Where-Object { $Sophos_DeviceID -in $_.sophos_matches })
				}
			}

			$RelatedDevices = $RelatedDevices | Sort-Object id -Unique

			# Got all related devices, update $MatchedDevices
			if (($RelatedDevices | Measure-Object).Count -gt 0) {
				foreach ($MatchedDevice in $RelatedDevices) {
					$MatchedDevice.intune_matches += @($Device.id)
					$MatchedDevice.intune_hostname += @($Device.DeviceName)
				}
			}
		}
	}

	# Match devices to Azure
	if ($AzureConnected) {
		foreach ($Device in $Azure_Devices) {
			$RelatedDevices = @()
			$MatchWarning = $false

			# Azure to Intune Matches
			$Related_IntuneDevices = @()
			$Related_IntuneDevices += ($Intune_Devices | Where-Object {
				$Device.DeviceId -like $_.AzureAdDeviceId
			})

			# Get existing matches and connect
			$Related_IntuneDevices | ForEach-Object {
				$Azure_DeviceID = $_.Id
				$RelatedDevices += ($MatchedDevices | Where-Object { $Azure_DeviceID -in $_.intune_matches })
			}

			# Azure to RMM Matches
			if (!$RelatedDevices) {
				$Related_RMMDevices = @()
				$Related_RMMDevices += ($RMM_Devices | Where-Object { 
					$Device.DisplayName -like $_.'Device Hostname' -or
					$Device.DisplayName -like $_.'Device Description'
				})

				# Narrow down if more than 1 device found
				if (($Related_RMMDevices | Measure-Object).Count -gt 1) {
					$Related_RMMDevices_Filtered = $Related_RMMDevices | Where-Object { 
						$Device.DisplayName -like $_.'Device Hostname'
					}
					if (($Related_RMMDevices_Filtered | Measure-Object).Count -gt 0) {
						$Related_RMMDevices = $Related_RMMDevices_Filtered
					}
				}

				if (($Related_RMMDevices | Measure-Object).Count -gt 1 -and ($Related_RMMDevices."Serial Number" | Sort-Object -Unique | Measure-Object).Count -gt 1) {
					$MatchWarning = $true
				}

				# Get existing matches and connect
				$Related_RMMDevices | ForEach-Object {
					$RMM_DeviceID = $_."Device UID"
					$RelatedDevices += ($MatchedDevices | Where-Object { $RMM_DeviceID -in $_.rmm_matches })
				}
			}


			# Intune to SC Matches (fallback)
			if (!$RelatedDevices) {
				$Related_SCDevices = @()
				$Related_SCDevices += ($SC_Devices | Where-Object {
					$Device.DisplayName -like $_.Name -or 
					$Device.DisplayName -like $_.GuestMachineName
				})

				# Narrow down if more than 1 device found
				if (($Related_SCDevices | Measure-Object).Count -gt 1) {
					$Related_SCDevices_Filtered = $Related_SCDevices | Where-Object { 
						$Device.DisplayName -like $_.Name
					}
					if (($Related_SCDevices_Filtered | Measure-Object).Count -gt 0) {
						$Related_SCDevices = $Related_SCDevices_Filtered
					}
				}
				if (($Related_SCDevices | Measure-Object).Count -gt 1) {
					$Related_SCDevices_Filtered = $Related_SCDevices | Where-Object { 
						$Device.DisplayName -like $_.GuestMachineName
					}
					if (($Related_SCDevices_Filtered | Measure-Object).Count -gt 0) {
						$Related_SCDevices = $Related_SCDevices_Filtered
					}
				}

				if (($Related_SCDevices | Measure-Object).Count -gt 1 -and ($Related_SCDevices.GuestMachineSerialNumber | Sort-Object -Unique | Measure-Object).Count -gt 1) {
					$MatchWarning = $true
				}

				# Get existing matches and connect
				$Related_SCDevices | ForEach-Object {
					$SC_DeviceID = $_.SessionID
					$RelatedDevices += ($MatchedDevices | Where-Object { $SC_DeviceID -in $_.sc_matches })
				}
			}

			# Intune to Sophos Matches (fallback)
			if (!$RelatedDevices) {
				$Related_SophosDevices = @()
				$Related_SophosDevices += ($Sophos_Devices | Where-Object {
					$Device.DisplayName -eq $_.hostname
				})

				# If matching is for MacOS devices and multiple are found, skip matching
				if (($Related_SophosDevices | Measure-Object).Count -gt 1 -and $Related_SophosDevices.OS -like "*macOS*") {
					continue
				}

				if (($Related_SophosDevices | Measure-Object).Count -gt 1) {
					$MatchWarning = $true
				}

				# Get existing matches and connect
				$Related_SophosDevices | ForEach-Object {
					$Sophos_DeviceID = $_.id
					$RelatedDevices += ($MatchedDevices | Where-Object { $Sophos_DeviceID -in $_.sophos_matches })
				}
			}

			$RelatedDevices = $RelatedDevices | Sort-Object id -Unique

			# Got all related devices, update $MatchedDevices
			if (($RelatedDevices | Measure-Object).Count -gt 0) {
				foreach ($MatchedDevice in $RelatedDevices) {
					$MatchedDevice.azure_matches += @($Device.id)
					$MatchedDevice.azure_hostname += @($Device.DisplayName)
					$MatchedDevice.azure_match_warning = $MatchWarning
				}
			}
		}
	}

	# Match devices to Ninite
	if ($Ninite_Machines) {
		foreach ($MatchedDevice in $MatchedDevices) {
			if (!$PerformMatching -and ($MatchedDevice.ninite_matches | Measure-Object).Count -gt 0 -and ($MatchedDevice.ninite_matches | Where-Object { $_ -notin $Ninite_Machines.id } | Measure-Object).Count -eq 0) {
				continue
			}
			$RelatedDevices = New-Object -TypeName System.Collections.ArrayList

			# Ninite to RMM Matches
			if (!$RelatedDevices -and $MatchedDevice.rmm_matches) {
				$Related_ToRMMDevices = New-Object -TypeName System.Collections.ArrayList
				foreach ($RMMDeviceID in $MatchedDevice.rmm_matches) {
					$Related_ToRMMDevice = New-Object -TypeName System.Collections.ArrayList
					$RMMDevice = ($RMM_Devices | Where-Object { $_."Device UID" -eq $RMMDeviceID })
					$Related_ToRMMDevice.Add(($Ninite_Machines | Where-Object { 
						$_.name -like $RMMDevice.'Device Hostname' -or
						$_.name -like $RMMDevice.'Device Description' -or
						$_.name2 -like $RMMDevice.'Device Hostname' -or
						$_.name2 -like $RMMDevice.'Device Description' -or
						$_.machine_name -like $RMMDevice.'Device Hostname' -or
						$_.machine_name -like $RMMDevice.'Device Description' -or
						$_.user_machine_name -like $RMMDevice.'Device Hostname' -or
						$_.user_machine_name -like $RMMDevice.'Device Description'
					})) | Out-Null

					# Narrow down if more than 1 device found
					if (($Related_ToRMMDevice | Measure-Object).Count -gt 1) {
						$Related_ToRMMDevice_Filtered = $Related_ToRMMDevice | Where-Object { 
							$_.machine_name -like $RMMDevice.'Device Hostname'
						}
						if (($Related_ToRMMDevice_Filtered | Measure-Object).Count -gt 0) {
							$Related_ToRMMDevice = $Related_ToRMMDevice_Filtered
						}
					}
					if (($Related_ToRMMDevice | Measure-Object).Count -gt 1) {
						$Related_ToRMMDevice_Filtered = $Related_ToRMMDevice | Where-Object { 
							$_.name -like $RMMDevice.'Device Hostname'
						}
						if (($Related_ToRMMDevice_Filtered | Measure-Object).Count -gt 0) {
							$Related_ToRMMDevice = $Related_ToRMMDevice_Filtered
						}
					}

					$Related_ToRMMDevices.Add($Related_ToRMMDevice) | Out-Null
				}
				$Related_ToRMMDevices = @($Related_ToRMMDevices | Sort-Object id -Unique)

				$Related_ToRMMDevices | ForEach-Object {
					$RelatedDevices.Add($_) | Out-Null
				}
			}

			# Ninite to SC Matches (fallback)
			if (!$RelatedDevices -and $MatchedDevice.sc_matches) {
				$Related_ToSCDevices = New-Object -TypeName System.Collections.ArrayList
				foreach ($SCDeviceID in $MatchedDevice.sc_matches) {
					$Related_ToSCDevice = New-Object -TypeName System.Collections.ArrayList
					$SCDevice = ($SC_Devices | Where-Object { $_.SessionID -eq $SCDeviceID })
					$Related_ToSCDevice.Add(($Ninite_Machines | Where-Object {
						$_.name -like $SCDevice.Name -or 
						$_.name -like $SCDevice.GuestMachineName -or
						$_.name2 -like $SCDevice.Name -or 
						$_.name2 -like $SCDevice.GuestMachineName -or
						$_.machine_name -like $SCDevice.Name -or 
						$_.machine_name -like $SCDevice.GuestMachineName -or
						$_.user_machine_name -like $SCDevice.Name -or 
						$_.user_machine_name -like $SCDevice.GuestMachineName
					})) | Out-Null

					# Narrow down if more than 1 device found
					if (($Related_ToSCDevice | Measure-Object).Count -gt 1) {
						$Related_ToSCDevice_Filtered = $Related_ToSCDevice | Where-Object { 
							$_.machine_name -like $SCDevice.Name
						}
						if (($Related_ToSCDevice_Filtered | Measure-Object).Count -gt 0) {
							$Related_ToSCDevice = $Related_ToSCDevice_Filtered
						}
					}
					if (($Related_ToSCDevice | Measure-Object).Count -gt 1) {
						$Related_ToSCDevice_Filtered = $Related_ToSCDevice | Where-Object { 
							$_.name -like $SCDevice.Name
						}
						if (($Related_ToSCDevice_Filtered | Measure-Object).Count -gt 0) {
							$Related_ToSCDevice = $Related_ToSCDevice_Filtered
						}
					}
					if (($Related_ToSCDevice | Measure-Object).Count -gt 1) {
						$Related_ToSCDevice_Filtered = $Related_ToSCDevice | Where-Object { 
							$_.machine_name -like $SCDevice.GuestMachineName
						}
						if (($Related_ToSCDevice_Filtered | Measure-Object).Count -gt 0) {
							$Related_ToSCDevice = $Related_ToSCDevice_Filtered
						}
					}
					if (($Related_ToSCDevice | Measure-Object).Count -gt 1) {
						$Related_ToSCDevice_Filtered = $Related_ToSCDevice | Where-Object { 
							$_.name -like $SCDevice.GuestMachineName
						}
						if (($Related_ToSCDevice_Filtered | Measure-Object).Count -gt 0) {
							$Related_ToSCDevice = $Related_ToSCDevice_Filtered
						}
					}

					$Related_ToSCDevices.Add($Related_ToSCDevice) | Out-Null
				}
				$Related_ToSCDevices = @($Related_ToSCDevices | Sort-Object id -Unique)

				$Related_ToSCDevices | ForEach-Object {
					$RelatedDevices.Add($_) | Out-Null
				}
			}

			# Ninite to Sophos Matches (fallback)
			if (!$RelatedDevices -and $MatchedDevice.sophos_matches) {
				$Related_ToSophosDevices = New-Object -TypeName System.Collections.ArrayList
				foreach ($SophosDeviceID in $MatchedDevice.sophos_matches) {
					$Related_ToSophosDevice = New-Object -TypeName System.Collections.ArrayList
					$SophosDevice = ($Sophos_Devices | Where-Object { $_.id -eq $SophosDeviceID })
					$Related_ToSophosDevice.Add(($Ninite_Machines | Where-Object {
						$_.name -eq $SophosDevice.hostname -or
						$_.name2 -eq $SophosDevice.hostname -or
						$_.machine_name -eq $SophosDevice.hostname -or
						$_.user_machine_name -eq $SophosDevice.hostname
					})) | Out-Null

					# If matching is for MacOS devices and multiple are found, skip matching
					if (($Related_ToSophosDevice | Measure-Object).Count -gt 1 -and $SophosDevice.OS -like "*macOS*") {
						continue
					}

					# Narrow down if more than 1 device found
					if (($Related_ToSophosDevice | Measure-Object).Count -gt 1) {
						$Related_ToSophosDevice_Filtered = $Related_ToSophosDevice | Where-Object { 
							$_.machine_name -like $SophosDevice.hostname
						}
						if (($Related_ToSophosDevice_Filtered | Measure-Object).Count -gt 0) {
							$Related_ToSophosDevice = $Related_ToSophosDevice_Filtered
						}
					}
					if (($Related_ToSophosDevice | Measure-Object).Count -gt 1) {
						$Related_ToSophosDevice_Filtered = $Related_ToSophosDevice | Where-Object { 
							$_.name -like $SophosDevice.hostname
						}
						if (($Related_ToSophosDevice_Filtered | Measure-Object).Count -gt 0) {
							$Related_ToSophosDevice = $Related_ToSophosDevice_Filtered
						}
					}

					$Related_ToSophosDevices.Add($Related_ToSophosDevice) | Out-Null
				}
				$Related_ToSophosDevices = @($Related_ToSophosDevices | Sort-Object id -Unique)

				# Get existing matches and connect
				$Related_ToSophosDevices | ForEach-Object {
					$RelatedDevices.Add($_) | Out-Null
				}
			}

			$RelatedDevices = $RelatedDevices | Sort-Object id -Unique

			# Got all related devices, update $MatchedDevices
			if (($RelatedDevices | Measure-Object).Count -gt 0) {
				foreach ($NiniteDevice in $RelatedDevices) {
					$MatchedDevice.ninite_matches += @($NiniteDevice.id)
					$MatchedDevice.ninite_hostname += @($NiniteDevice.name)
				}
			}
		}
	}


	# Export matched devices json to file
	if ($MatchedDevicesLocation) {
		$MatchedDevices | ConvertTo-Json | Out-File -FilePath $MatchedDevicesJsonPath
		Write-Host "Exported the matched devices json file."

		# Delete any old matched devices json files
		Get-ChildItem $MatchedDevicesLocation | Where-Object { $_.Name -Match "^$($Company_Acronym)_matched_devices_\d{4}_\d{2}_\d{2}\.json" -and $_.FullName -ne $MatchedDevicesJsonPath -and !$_.PSIsContainer } | Remove-Item
	}

	Write-Host "Matching Complete!"
	Write-Host "===================="

	# Get a list of Autotask tickets related to RMM, SC, Sophos or Ninite agent issues
	$RepairTickets = Get-AutotaskAPIResource -Resource Tickets -SearchQuery '{"filter":[{"op":"noteq","field":"Status","value":5},{"op":"or","items": [{"op":"contains","field":"title","value":"RMM"},{"op":"contains","field":"title","value":"SC"},{"op":"contains","field":"title","value":"ScreenConnect"},{"op":"contains","field":"title","value":"Sophos"},{"op":"contains","field":"title","value":"Ninite"}]}]}'
	$RepairTickets = $RepairTickets | Where-Object {
		$_.title -like "*Reinstall RMM*" -or $_.title -like "*Install RMM*" -or $_.title -like"*Audit RMM*" -or $_.title -like "*Troubleshoot RMM*" -or $_.title -like "*Repair RMM*" -or
		$_.title -like "*Reinstall SC*" -or $_.title -like "*Install SC*" -or $_.title -like"*Audit SC*" -or $_.title -like "*Troubleshoot SC*" -or $_.title -like "*Repair SC*" -or
		$_.title -like "*Reinstall ScreenConnect*" -or $_.title -like "*Install ScreenConnect*" -or $_.title -like"*Audit ScreenConnect*" -or $_.title -like "*Troubleshoot ScreenConnect*" -or $_.title -like "*Repair ScreenConnect*" -or
		$_.title -like "*Reinstall Sophos*" -or $_.title -like "*Install Sophos*" -or $_.title -like"*Audit Sophos*" -or $_.title -like "*Troubleshoot Sophos*" -or $_.title -like "*Repair Sophos*" -or
		$_.title -like "*Reinstall Ninite*" -or $_.title -like "*Install Ninite*" -or $_.title -like"*Audit Ninite*" -or $_.title -like "*Troubleshoot Ninite*" -or $_.title -like "*Repair Ninite*"
	}

	# Get the existing log
	$LogFilePath = "$($LogLocation)\$($Company_Acronym)_log.json"
	if ($LogLocation -and (Test-Path -Path $LogFilePath)) {
		$LogHistory = Get-Content -Path $LogFilePath -Raw | ConvertFrom-Json

		# Cleanup log history (remove everything older than 6 months)
		$SixMonthsAgo = [int](New-TimeSpan -Start (Get-Date "01/01/1970") -End ((Get-Date).AddMonths(-6)).ToUniversalTime()).TotalSeconds
		$LogHistory = $LogHistory | Where-Object { $_.datetime -ge $SixMonthsAgo }
		$LogHistory | ConvertTo-Json -Depth 5 | Out-File -FilePath $LogFilePath
	} else {
		$LogHistory = @{}
	}

	# Prepare install queue
	if (!(Test-Path -Path $InstallQueueLocation)) {
		New-Item -ItemType Directory -Force -Path $InstallQueueLocation | Out-Null
	}
	$InstallQueuePath = "$($InstallQueueLocation)\$($Company_Acronym)_install_queue.json"

	# Prepare recent RMM jobs log
	if (!(Test-Path -Path $RecentRMMJobsLocation)) {
		New-Item -ItemType Directory -Force -Path $RecentRMMJobsLocation | Out-Null
	}
	$RecentRMMJobsPath = "$($RecentRMMJobsLocation)\$($Company_Acronym)_recent_rmm_jobs.json"


	# Find any duplicates that need to be removed
	if ($DODuplicateSearch) {
		Write-Host "Searching for duplicates..."
		$Duplicates = @()
		foreach ($Device in $MatchedDevices) {
			if ($Device.sc_matches.count -gt 1 -or $Device.rmm_matches.count -gt 1 <# -or $Device.sophos_matches.count -gt 1 #> -or ($JCConnected -and $Device.jc_matches.count -gt 1) -or ($NiniteAuthResponse -and $Device.ninite_matches.count -gt 1)) { 
				$Duplicates += $Device
			}
		}

		if (($Duplicates | Measure-Object).count -gt 0) {
			$DuplicatesTable = @()

			foreach ($Device in $Duplicates) {
				# ScreenConnect
				if ($Device.sc_matches.count -gt 1) {
					$OrderedDevices = compare_activity_sc($Device.sc_matches)
					$i = 0
					foreach ($OrderedDevice in $OrderedDevices) {
						$SCDevice = $SC_DevicesHash[$OrderedDevice.id]
						$Deleted = $false
						$AllowDeletion = $true
						if ($DontAutoDelete -and ($DontAutoDelete.Hostnames -contains $SCDevice.Name -or $DontAutoDelete.SC -contains $SCDevice.Name -or $DontAutoDelete.SC -contains $OrderedDevice.id)) {
							$AllowDeletion = $false
						}
						if ($i -gt 0 -and !$ReadOnly -and $AllowDeletion) {
							$Deleted = delete_from_sc -SC_ID $OrderedDevice.id  -SCWebSession $SCWebSession
							if ($Deleted) {
								log_change -Company_Acronym $Company_Acronym -ServiceTarget "sc" -RMM_Device_ID $Device.rmm_matches -SC_Device_ID $OrderedDevice.id -Sophos_Device_ID $Device.sophos_matches -ChangeType "delete" -Hostname $SCDevice.Name -Reason "Duplicate"
							}
						}
						$DuplicatesTable += [PsCustomObject]@{
							type = "SC"
							hostname = $SCDevice.Name
							id = $OrderedDevice.id 
							last_active = $OrderedDevice.last_active
							remove = if ($i -eq 0) { "No" } else { "Yes" }
							auto_deleted = $Deleted
							link = "$($SCLogin.URL)/Host#Access/All%20Machines/$($SCDevice.Name)/$($OrderedDevice.id)"
						}
						$i++
					}
				}

				# RMM
				if ($Device.rmm_matches.count -gt 1) {
					$OrderedDevices = compare_activity_rmm($Device.rmm_matches)
					$i = 0
					foreach ($OrderedDevice in $OrderedDevices) {
						$RMMDevice = $RMM_DevicesHash[$OrderedDevice.id]
						$Deleted = $false
						$AllowDeletion = $true
						if ($DontAutoDelete -and ($DontAutoDelete.Hostnames -contains $RMMDevice."Device Hostname" -or $DontAutoDelete.RMM -contains $RMMDevice."Device Hostname" -or $DontAutoDelete.RMM -contains $OrderedDevice.id)) {
							$AllowDeletion = $false
						}
						if ($i -gt 0 -and !$ReadOnly -and !$RMMDevice.ToDelete -and $AllowDeletion) {
							delete_from_rmm -RMM_Device_ID $OrderedDevice.id
							$Deleted = "Set DeleteMe UDF"
							log_change -Company_Acronym $Company_Acronym -ServiceTarget "rmm" -RMM_Device_ID $OrderedDevice.id -SC_Device_ID $Device.sc_matches -Sophos_Device_ID $Device.sophos_matches  -ChangeType "delete" -Hostname $RMMDevice."Device Hostname" -Reason "Duplicate"
						} elseif ($RMMDevice.ToDelete) {
							$Deleted = "Pending Deletion"
						}
						if ($RMMDevice.url) {
							$EmailLink = $RMMDevice.url
						} else {
							$EmailLink = "https://$($DattoAPIKey.Region).centrastage.net/csm/search?qs=uid%3A$($OrderedDevice.id)"
						}
						$DuplicatesTable += [PsCustomObject]@{
							type = "RMM"
							hostname = $RMMDevice."Device Hostname"
							id = $OrderedDevice.id 
							last_active = $OrderedDevice.last_active
							remove = if ($i -eq 0) { "No" } else { "Yes" }
							auto_deleted = $Deleted
							link = $EmailLink
						}
						$i++
					}
				}

				# Sophos (Disabled. Sophos really doesn't like you deleting duplicates so best to just leave them)
				<# if ($Device.sophos_matches.count -gt 1) {
					$OrderedDevices = compare_activity_sophos($Device.sophos_matches)
					$i = 0
					foreach ($OrderedDevice in $OrderedDevices) {
						$SophosDevice = $Sophos_DevicesHash[$OrderedDevice.id]
						$DuplicatesTable += [PsCustomObject]@{
							type = "Sophos"
							hostname = $SophosDevice.hostname
							id = $OrderedDevice.id 
							last_active = $OrderedDevice.last_active
							remove = if ($i -eq 0) { "No" } else { "Yes" }
							auto_deleted = $false
							link = "https://cloud.sophos.com/manage/devices/computers/$($SophosDevice.webID)"
						}
						$i++
					}
				} #>

				# JumpCloud
				if ($JCConnected -and $Device.jc_matches.count -gt 1) {
					$OrderedDevices = compare_activity_jc($Device.jc_matches)
					$i = 0
					foreach ($OrderedDevice in $OrderedDevices) {
						$JCDevice = $JC_DevicesHash[$OrderedDevice.id]
						$Deleted = $false
						$AllowDeletion = $true
						if ($DontAutoDelete -and (($JCDevice.hostname -and $DontAutoDelete.Hostnames -contains $JCDevice.hostname) -or $DontAutoDelete.Hostnames -contains $JCDevice.displayName -or ($JCDevice.hostname -and $DontAutoDelete.JC -contains $JCDevice.hostname) -or $DontAutoDelete.JC -contains $JCDevice.displayName -or $DontAutoDelete.JC -contains $OrderedDevice.id)) {
							$AllowDeletion = $false
						}
						if ($i -gt 0 -and !$ReadOnly -and $AllowDeletion) {
							$Deleted = delete_from_jc -JC_ID $OrderedDevice.id
							if ($Deleted) {
								log_change -Company_Acronym $Company_Acronym -ServiceTarget "jc" -RMM_Device_ID $Device.rmm_matches -SC_Device_ID $OrderedDevice.id -Sophos_Device_ID $Device.sophos_matches -JC_Device_ID $Device.jc_matches -ChangeType "delete" -Hostname if ($JCDevice.hostname) { $JCDevice.hostname } else { $JCDevice.displayName } -Reason "Duplicate"
							}
						}
						$DuplicatesTable += [PsCustomObject]@{
							type = "JC"
							hostname = if ($JCDevice.hostname) { $JCDevice.hostname } else { $JCDevice.displayName }
							id = $OrderedDevice.id 
							last_active = $OrderedDevice.last_active
							remove = if ($i -eq 0) { "No" } else { "Yes" }
							auto_deleted = $Deleted
							link = "https://console.jumpcloud.com/#/devices/$($JCDevice.id)/details"
						}
						$i++
					}
				}

				# Ninite
				if ($NiniteAuthResponse -and $Device.ninite_matches.count -gt 1) {
					$OrderedDevices = compare_activity_ninite($Device.ninite_matches)
					$i = 0
					foreach ($OrderedDevice in $OrderedDevices) {
						$NiniteDevice = $Ninite_DevicesHash[$OrderedDevice.id]
						$Deleted = $false
						$AllowDeletion = $true
						if ($DontAutoDelete -and (
							($NiniteDevice.name -and $DontAutoDelete.Hostnames -contains $NiniteDevice.name) -or 
							($NiniteDevice.name2 -and $DontAutoDelete.Hostnames -contains $NiniteDevice.name2) -or
							($NiniteDevice.machine_name -and $DontAutoDelete.Hostnames -contains $NiniteDevice.machine_name) -or  
							($NiniteDevice.name -and $DontAutoDelete.Ninite -contains $NiniteDevice.name) -or 
							($NiniteDevice.name2 -and $DontAutoDelete.Ninite -contains $NiniteDevice.name2) -or
							($NiniteDevice.machine_name -and $DontAutoDelete.Ninite -contains $NiniteDevice.machine_name) -or  
							$DontAutoDelete.Ninite -contains $OrderedDevice.id
						)) {
							$AllowDeletion = $false
						}
						$Hostname = if ($NiniteDevice.name) { $NiniteDevice.name } elseif ($NiniteDevice.name2) { $NiniteDevice.name } else { $NiniteDevice.machine_name }
						if ($i -gt 0 -and !$ReadOnly -and $AllowDeletion) {
							$Deleted = delete_from_ninite -Ninite_ID $OrderedDevice.id  -NiniteWebSession $NiniteWebSession -NiniteHeader $NiniteHeader
							if ($Deleted) {
								log_change -Company_Acronym $Company_Acronym -ServiceTarget "ninite" -RMM_Device_ID $Device.rmm_matches -SC_Device_ID $OrderedDevice.id -Sophos_Device_ID $Device.sophos_matches -Ninite_Device_ID $Device.ninite_matches -ChangeType "delete" -Hostname $Hostname -Reason "Duplicate"
							}
						}
						$DuplicatesTable += [PsCustomObject]@{
							type = "Ninite"
							hostname = $Hostname
							id = $OrderedDevice.id 
							last_active = $OrderedDevice.last_active
							remove = if ($i -eq 0) { "No" } else { "Yes" }
							auto_deleted = $Deleted
						}
						$i++
					}
				}
			}

			Write-Host "Warning! Duplicates were found!" -ForegroundColor Red

			# Now remove duplicates from $MatchedDevices as we can ignore them for the rest of this script
			$UpdatedMatchedDevices = $false
			foreach ($Device in $DuplicatesTable) {
				if ($Device.Remove -eq "No") {
					continue
				}

				if ($Device.type -eq "SC") {
					$MatchedDevice = $MatchedDevices | Where-Object { $Device.id -in $_.sc_matches }
					$SCDevices = @()
					foreach ($DeviceID in $MatchedDevice.sc_matches) {
						$SCDevices += $SC_DevicesHash[$DeviceID]
					}
					foreach ($MDevice in $MatchedDevice) {
						$MDevice.sc_matches = $MatchedDevice.sc_matches | Where-Object { $_ -ne $Device.id }
						$MDevice.sc_hostname = @($SCDevices.Name)
					}
					if (($MatchedDevice | Measure-Object).Count -gt 0) {
						$UpdatedMatchedDevices = $true
					}
				}

				if ($Device.type -eq "RMM") {
					$MatchedDevice = $MatchedDevices | Where-Object { $Device.id -in $_.rmm_matches }
					$RMMDevices = @()
					foreach ($DeviceID in $MatchedDevice.rmm_matches) {
						$RMMDevices += $RMM_DevicesHash[$DeviceID]
					}
					foreach ($MDevice in $MatchedDevice) {
						$MDevice.rmm_matches = $MatchedDevice.rmm_matches | Where-Object { $_ -ne $Device.id }
						$MDevice.rmm_hostname = @($RMMDevices."Device Hostname")
					}
					if (($MatchedDevice | Measure-Object).Count -gt 0) {
						$UpdatedMatchedDevices = $true
					}
				}

				if ($Device.type -eq "Sophos") {
					$MatchedDevice = $MatchedDevices | Where-Object { $Device.id -in $_.sophos_matches }
					$SophosDevices = @()
					foreach ($DeviceID in $MatchedDevice.sophos_matches) {
						$SophosDevices += $Sophos_DevicesHash[$DeviceID]
					}
					foreach ($MDevice in $MatchedDevice) {
						$MDevice.sophos_matches = $MatchedDevice.sophos_matches | Where-Object { $_ -ne $Device.id }
						$MDevice.sophos_hostname = @($SophosDevices.hostname)
					}
					if (($MatchedDevice | Measure-Object).Count -gt 0) {
						$UpdatedMatchedDevices = $true
					}
				}

				if ($Device.type -eq "JC") {
					$MatchedDevice = $MatchedDevices | Where-Object { $Device.id -in $_.jc_matches }
					$JCDevices = @()
					foreach ($DeviceID in $MatchedDevice.jc_matches) {
						$JCDevices += $JC_DevicesHash[$DeviceID]
					}
					foreach ($MDevice in $MatchedDevice) {
						$MDevice.jc_matches = $MatchedDevice.jc_matches | Where-Object { $_ -ne $Device.id }
						$MDevice.jc_hostname = @($JCDevices | Foreach-Object { if ($_.hostname) { $_.hostname } else { $_.displayName } })
					}
					if (($MatchedDevice | Measure-Object).Count -gt 0) {
						$UpdatedMatchedDevices = $true
					}
				}

				if ($Device.type -eq "Ninite") {
					$MatchedDevice = $MatchedDevices | Where-Object { $Device.id -in $_.ninite_matches }
					$NiniteDevices = @()
					foreach ($DeviceID in $MatchedDevice.ninite_matches) {
						$NiniteDevices += $Ninite_DevicesHash[$DeviceID]
					}
					foreach ($MDevice in $MatchedDevice) {
						$MDevice.ninite_matches = $MatchedDevice.ninite_matches | Where-Object { $_ -ne $Device.id }
						$MDevice.ninite_hostname = @($NiniteDevices | Foreach-Object { if ($_.name) { $_.name } else { $_.machine_name } })
					}
					if (($MatchedDevice | Measure-Object).Count -gt 0) {
						$UpdatedMatchedDevices = $true
					}
				}
			}

			if ($UpdatedMatchedDevices -and $MatchedDevicesJsonPath) {
				# Update the exported MatchedDevices json file
				$MatchedDevices | ConvertTo-Json | Out-File -FilePath $MatchedDevicesJsonPath
			}
		}

		Write-Host "Duplicate check complete."
		Write-Host "======================"
	}

	# Check for devices that look like they should not be under this company
	if ($DOWrongCompanySearch) {
		Write-Host "Searching for any devices that look like they belong in a different company..."
		$MoveDevices = @()

		:matchedDeviceLoop foreach ($Device in $MatchedDevices) {
			$Hostnames = @()
			$SCDeviceIDs = @($Device.sc_matches)
			$RMMDeviceIDs = @($Device.rmm_matches)
			$SophosDeviceIDs = @($Device.sophos_matches)

			$DeviceType = $false
			$OperatingSystem = $false

			foreach ($Acronym in $Device_Acronyms) {
				if ($Device.sc_hostname -like "$($Acronym)-*" -or $Device.rmm_hostname -like "$($Acronym)-*" -or $Device.sophos_hostname -like "$($Acronym)-*") {
					continue matchedDeviceLoop
				}
			}

			if ($SCDeviceIDs) {
				$SCDevices = @()
				foreach ($DeviceID in $SCDeviceIDs) {
					$SCDevices += $SC_DevicesHash[$DeviceID]
				}			
				$Hostnames += $SCDevices.Name
				$OperatingSystem = $SCDevices[0].GuestOperatingSystemName
				$DeviceType = $SCDevices[0].DeviceType
			}
			if ($RMMDeviceIDs) {
				$RMMDevices = @()
				foreach ($DeviceID in $RMMDeviceIDs) {
					$RMMDevices += $RMM_DevicesHash[$DeviceID]
				}
				$Hostnames += $RMMDevices."Device Hostname"
				if (!$OperatingSystem) {
					$OperatingSystem = $RMMDevices[0]."Operating System"
				}
				if ($DeviceType) {
					$DeviceType = $RMMDevices[0]."Device Type"
				}
			}
			if ($SophosDeviceIDs) {
				$SophosDevices = @()
				foreach ($DeviceID in $SophosDeviceIDs) {
					$SophosDevices += $Sophos_DevicesHash[$DeviceID]
				}
				$Hostnames += $SophosDevices.hostname
				if (!$OperatingSystem) {
					$OperatingSystem = $SophosDevices[0].OS
				}
				if (!$DeviceType) {
					$DeviceType = $SophosDevices[0].type
				}
			}
			$Hostnames = $HostNames | Sort-Object -Unique

			if (!$DeviceType) {
				if ($OperatingSystem -and $OperatingSystem -like "*Server*") {
					$DeviceType = "Server"
				} else {
					$DeviceType = "Workstation"
				}
			}

			# Ignore Macs
			if ($OperatingSystem -like "Mac OS*" -or $OperatingSystem -like "macOS*") {
				continue
			}

			# Check if the hostname uses this customers acronym
			$GoodHostname = $false
			foreach ($Acronym in $Device_Acronyms) {
				if ((($Hostnames | Where-Object { $_ -like "$($Acronym)-*" }) | Measure-Object).Count -gt 0) {
					$GoodHostname = $true
					continue
				}
			}

			if (!$GoodHostname -and (($Hostnames | Where-Object { $_ -in $Device_Whitelist }) | Measure-Object).Count -gt 0) {
				$GoodHostname = $true
			}

			if ($GoodHostname) {
				continue
			}

			# Check for default hostnames and exceptions
			if ((($Hostnames | Where-Object { $_ -notlike "*-*" -or $_ -like "DESKTOP-*" -or $_ -like "LAPTOP-*" -or $_ -like "*MacBook*" -or  $_ -like "STS-*" }) | Measure-Object).Count -gt 0) {
				continue
			}

			# Ignore servers
			if ($DeviceType -eq "Server") {
				continue
			}

			$SCLink = ""
			$RMMLink = ""
			$SophosLink = ""
			if ($SCDeviceIDs) {
				$SCLink = "$($SCLogin.URL)/Host#Access/All%20Machines/$($SCDevices[0].Name)/$($SCDeviceIDs[0])"
			}
			if ($RMMDeviceIDs) {
				if ($RMMDevices[0].url) {
					$RMMLink = $RMMDevices[0].url
				} else {
					$RMMLink = "https://$($DattoAPIKey.Region).centrastage.net/csm/search?qs=uid%3A$($RMMDeviceIDs[0])"
				}
			}
			if ($SophosDeviceIDs) {
				$SophosLink = "https://cloud.sophos.com/manage/devices/computers/$($SophosDevices[0].webID)"
			}
			$RMMAntivirus = $false
			if (!$SophosDeviceIDs -and $RMMDeviceIDs) {
				$RMMAntivirus = $RMMDevices[0].Antivirus
			}

			# This device does not look like it belongs here, lets flag it
			$MoveDevices += [PsCustomObject]@{
				ID = $Device.id
				Hostnames = $Hostnames -join ', '
				DeviceType = $DeviceType
				InSC = if ($SCDeviceIDs) { "Yes" } else { "No" }
				InRMM = if ($RMMDeviceIDs) { "Yes" } else { "No" }
				InSophos = if ($SophosDeviceIDs) { "Yes" } elseif ($RMMAntivirus -and $RMMAntivirus -like "Sophos*") { "Yes, missing from portal" } else { "No" }
				SC_Link = $SCLink
				RMM_Link = $RMMLink
				Sophos_Link = $SophosLink
			}
		}

		if (($MoveDevices | Where-Object { $_.Hostnames -notlike "STS-*" } | Measure-Object).count -gt 0) { # ignore sts loaners
			Write-Host "Warning! Devices found that may not belong in this company!" -ForegroundColor Red

			# Try sending an email
			$TwoWeeksAgo = [int](New-TimeSpan -Start (Get-Date "01/01/1970") -End (Get-Date).AddDays(-14).ToUniversalTime()).TotalSeconds
			$EmailChangeType = "wrong-company-email"
			$Reason = "Email sent for devices found under wrong company"

			$EmailQuery_Params = @{
				LogHistory = $LogHistory
				StartTime = $TwoWeeksAgo
				EndTime = 'now'
				ServiceTarget = 'email'
				ChangeType = $EmailChangeType
				Reason = $EmailReason
			}
			$History_Subset_Emails = log_query @EmailQuery_Params

			# no emails were already sent, continue
			if (($History_Subset_Emails | Measure-Object).count -eq 0) {
				# send an email
				$EmailSubject = "Device Audit on $Company_Acronym - Devices Found that belong to a different company"
				$EmailIntro = "Devices were found that look like they may not belong in this company. Please review:"
				$DeviceTable = @($MoveDevices) | Sort-Object Hostnames,DeviceType | ConvertTo-HTML -Fragment -As Table | Out-String

				$HTMLEmail = $EmailTemplate -f `
								$EmailIntro, 
								"Devices Found with odd Hostnames", 
								$DeviceTable, 
								"<br />Please review these devices manually. Either fix them or update the script's config file to whitelist them."

				$mailbody = @{
					"From" = $EmailFrom
					"To" = $EmailTo_FailedFixes
					"Subject" = $EmailSubject
					"HTMLContent" = $HTMLEmail
				} | ConvertTo-Json -Depth 6

				$headers = @{
					'x-api-key' = $Email_APIKey.Key
				}

				Invoke-RestMethod -Method Post -Uri $Email_APIKey.Url -Body $mailbody -Headers $headers -ContentType application/json
				Write-Host "Email Sent." -ForegroundColor Yellow

				# log the sent email
				log_change -Company_Acronym $Company_Acronym -ServiceTarget 'email' -RMM_Device_ID "" -SC_Device_ID "" -Sophos_Device_ID "" -ChangeType $EmailChangeType -Hostname "" -Reason $EmailReason
			}
		}

		Write-Host "Check for devices that don't belong is complete."
		Write-Host "======================"
	}


	# Get activity comparisons and store for later (so we aren't repeating this over and over)
	if ($DOBrokenConnectionSearch -or $DOMissingConnectionSearch -or $DOInactiveSearch -or $DOUsageDBSave -or $DOBillingExport) {
		foreach ($Device in $MatchedDevices) {
			$ActivityComparison = compare_activity($Device)
			$ActivityComparison.Values = @($ActivityComparison.Values)
			if (!$Device.activity_comparison) {
				$Device | Add-Member -NotePropertyName activity_comparison -NotePropertyValue $null
			}
			$Device.activity_comparison = $ActivityComparison
		}
	}

	$MatchedDevicesHash = @{}
	foreach ($Device in $MatchedDevices) { 
		$MatchedDevicesHash[$Device.id] = $Device
	}

	# Find broken device connections (e.g. online recently in ScreenConnect but not in RMM)
	if ($DOBrokenConnectionSearch) {
		Write-Host "Searching for broken connections..."
		$BrokenConnections = @()
		$SendEmail = $false
		$Now = Get-Date
		foreach ($Device in $MatchedDevices) {
			$ActivityComparison = $Device.activity_comparison
			$Activity = $ActivityComparison.Values | Sort-Object last_active

			if (($Activity | Measure-Object).count -gt 1) {
				$LastIndex = ($Activity | Measure-Object).count-1
				$NewestDate = [DateTime]($Activity.last_active | Sort-Object | Select-Object -Last 1)
				for ($i=0; $i -lt $LastIndex; $i++) {
					$ComparisonDate = [DateTime]$Activity[$i].last_active
					$Timespan = New-TimeSpan -Start $ComparisonDate -End $NewestDate

					if ($Timespan.Days -gt $BrokenThreshold) {
						$Hostname = ''
						$DeviceType = $Activity[$i].type
						$DeviceID = $Activity[$i].id
						if ($DeviceType -eq 'sc') {
							$Hostname = ($SC_DevicesHash[$DeviceID]).Name
						} elseif ($DeviceType -eq 'rmm') {
							$RMMDevice = $RMM_DevicesHash[$DeviceID]
							$Hostname = $RMMDevice."Device Hostname"
						} elseif ($DeviceType -eq 'sophos') {
							$SophosDevice = $Sophos_DevicesHash[$DeviceID]
							$Hostname = $SophosDevice.hostname
						} elseif ($DeviceType -eq 'azure') {
							$AzureDevice = $Azure_DevicesHash[$DeviceID]
							$Hostname = $AzureDevice.DisplayName
						} elseif ($DeviceType -eq 'intune') {
							$InTuneDevice = $InTune_DevicesHash[$DeviceID]
							$Hostname = $InTuneDevice.DeviceName
						} elseif ($DeviceType -eq 'jc') {
							$JCDevice = $JC_DevicesHash[$DeviceID]
							$Hostname = $JCDevice.displayName
						} elseif ($DeviceType -eq 'ninite') {
							$NiniteDevice = $Ninite_DevicesHash[$DeviceID]
							$Hostname = $NiniteDevice.name
						}

						$Link = ''
						if ($DeviceType -eq 'sc') {
							$Link = "$($SCLogin.URL)/Host#Access/All%20Machines/$($Hostname)/$($DeviceID)"
						} elseif ($DeviceType -eq 'rmm') {
							if ($RMMDevice.url) {
								$Link = $RMMDevice.url
							} else {
								$Link = "https://$($DattoAPIKey.Region).centrastage.net/csm/search?qs=uid%3A$($DeviceID)"
							}
						} elseif ($DeviceType -eq 'sophos') {
							$Link = "https://cloud.sophos.com/manage/devices/computers/$($SophosDevice.webID)"
						} else {
							$Link = ""
						}

						# See if we can try to automatically fix this issue
						$AutoFix = $false
						if (!$ReadOnly -and $DeviceType -eq 'rmm' -and $RMM_ID -and ($Device.sc_matches | Measure-Object).Count -gt 0 -and $SCLogin.Username -and $SCWebSession -and $Device.id -notin $MoveDevices.ID) {
							# Device broken in rmm but is in SC and we are using the SC api account, have the rmm org id, and this device is not in the $MoveDevices array (devices that look like they dont belong)
							$SC_Device = @()
							foreach ($DeviceID in $Device.sc_matches) {
								$SC_Device += $SC_DevicesHash[$DeviceID]
							}
							
							# Only continue if the device was seen recently in SC (this will only work if it is active) and is using Windows
							foreach ($SCDevice in $SC_Device) {
								$LogParams = @{
									ServiceTarget = "sc"
									SC_Device_ID = $SCDevice.SessionID
									ChangeType = "install_rmm"
									Hostname = $SCDevice.Name
								}
								$AttemptCount = log_attempt_count @LogParams -LogHistory $LogHistory
								$EmailError = "RMM is broken on $($LogParams.Hostname). The Device Audit script has tried to reinstall RMM via SC $AttemptCount times now but it has not succeeded."
								$LogParams.RMM_Device_ID = $Device.rmm_matches
								$LogParams.Sophos_Device_ID = $Device.sophos_matches
								$LogParams.Reason = "RMM connection broken"

								if ($SCDevice.GuestOperatingSystemName -like "*Windows*" -and $SCDevice.GuestOperatingSystemName -notlike "*Windows Embedded*") {
									if ($SCDevice.GuestLastSeen -gt (Get-Date).AddHours(-3)) {
										if (install_rmm_using_sc -SC_ID $SCDevice.SessionID -RMM_ORG_ID $RMM_ID -SCWebSession $SCWebSession) {
											$AutoFix = $true
											check_failed_attempts @LogParams -LogHistory $LogHistory -Company_Acronym $Company_Acronym -ErrorMessage $EmailError
											log_change @LogParams -Company_Acronym $Company_Acronym
										}
									} else {
										add_device_to_install_queue -SC_ID $SCDevice.SessionID -ToInstall 'rmm'
									}
								} elseif ($SCDevice.GuestOperatingSystemName -like "*Mac OS*") {
									if ($SCDevice.GuestLastSeen -gt (Get-Date).AddHours(-3)) {
										if (install_rmm_using_sc_mac -SC_ID $SCDevice.SessionID -RMM_ORG_ID $RMM_ID -SCWebSession $SCWebSession) {
											$AutoFix = $true
											check_failed_attempts @LogParams -LogHistory $LogHistory -Company_Acronym $Company_Acronym -ErrorMessage $EmailError
											log_change @LogParams -Company_Acronym $Company_Acronym
										}
									} else {
										add_device_to_install_queue -SC_ID $SCDevice.SessionID -ToInstall 'rmm'
									}
								} 
							}
						}

						if (!$ReadOnly -and $DeviceType -eq 'sc' -and $RMM_ID -and ($Device.rmm_matches | Measure-Object).Count -gt 0 -and $Device.id -notin $MoveDevices.ID) {
							# Device broken in sc but is in RMM and we are using the rmm api, and this device is not in the $MoveDevices array (devices that look like they dont belong)
							$RMM_Device = @()
							foreach ($DeviceID in $Device.rmm_matches) {
								$RMM_Device += $RMM_DevicesHash[$DeviceID]
							}
	
							# Only continue if the device was seen in RMM in the last 24 hours
							foreach ($RMMDevice in $RMM_Device) {
								if ($RMMDevice.suspended -ne "True") {
									if ($RMMDevice.Status -eq "Online" -or $RMMDevice."Last Seen" -eq "Currently Online" -or ($RMMDevice."Last Seen" -as [DateTime]) -gt (Get-Date).AddHours(-24)) {
										$LogParams = @{
											ServiceTarget = "rmm"
											RMM_Device_ID = $RMMDevice."Device UID"
											ChangeType = "install_sc"
											Hostname = $RMMDevice."Device Hostname"
										}
										$AttemptCount = log_attempt_count @LogParams -LogHistory $LogHistory

										if ($AttemptCount -gt 3) {
											uninstall_sc_using_rmm -RMM_Device $RMMDevice
										}
										if (install_sc_using_rmm -RMM_Device $RMMDevice) {
											$AttemptCount = log_attempt_count @LogParams -LogHistory $LogHistory
											$EmailError = "ScreenConnect is broken on $($LogParams.Hostname). The Device Audit script has tried to reinstall SC via RMM $AttemptCount times now but it has not succeeded."
											$LogParams.SC_Device_ID = $Device.sc_matches
											$LogParams.Sophos_Device_ID = $Device.sophos_matches
											$LogParams.Reason = "SC connection broken"
		
											$AutoFix = $true
											check_failed_attempts @LogParams -LogHistory $LogHistory -Company_Acronym $Company_Acronym -ErrorMessage $EmailError
											log_change @LogParams -Company_Acronym $Company_Acronym
										}
									} else {
										add_device_to_install_queue -RMM_ID $RMMDevice."Device UID" -ToInstall 'sc'
									}
								}
							}
						}

						if (!$ReadOnly -and $DeviceType -eq 'ninite' -and $RMM_ID -and ($Device.rmm_matches | Measure-Object).Count -gt 0 -and $Device.id -notin $MoveDevices.ID) {
							# Device broken in ninite but is in RMM and we are using the rmm api, and this device is not in the $MoveDevices array (devices that look like they dont belong)
							$RMM_Device = @()
							foreach ($DeviceID in $Device.rmm_matches) {
								$RMM_Device += $RMM_DevicesHash[$DeviceID]
							}
	
							# Only continue if the device was seen in RMM in the last 24 hours
							foreach ($RMMDevice in $RMM_Device) {
								if ($RMMDevice.suspended -ne "True" -and $RMMDevice."Operating System" -like "*Windows*" -and $RMMDevice."Device Type" -notlike "*Server*") {
									if ($RMMDevice.Status -eq "Online" -or $RMMDevice."Last Seen" -eq "Currently Online" -or ($RMMDevice."Last Seen" -as [DateTime]) -gt (Get-Date).AddHours(-24)) {
										$LogParams = @{
											ServiceTarget = "rmm"
											RMM_Device_ID = $RMMDevice."Device UID"
											ChangeType = "install_ninite"
											Hostname = $RMMDevice."Device Hostname"
										}
										$AttemptCount = log_attempt_count @LogParams -LogHistory $LogHistory

										if (install_ninite_using_rmm -RMM_Device $RMMDevice) {
											$AttemptCount = log_attempt_count @LogParams -LogHistory $LogHistory
											$EmailError = "Ninite is broken on $($LogParams.Hostname). The Device Audit script has tried to reinstall Ninite via RMM $AttemptCount times now but it has not succeeded."
											$LogParams.SC_Device_ID = $Device.sc_matches
											$LogParams.Sophos_Device_ID = $Device.sophos_matches
											$LogParams.Ninite_Device_ID = $Device.ninite_matches
											$LogParams.Reason = "Ninite connection broken"
		
											$AutoFix = $true
											check_failed_attempts @LogParams -LogHistory $LogHistory -Company_Acronym $Company_Acronym -ErrorMessage $EmailError
											log_change @LogParams -Company_Acronym $Company_Acronym
										}
									} else {
										add_device_to_install_queue -RMM_ID $RMMDevice."Device UID" -ToInstall 'ninite'
									}
								}
							}
						}
						
						$RepairTickets_Subset = @()
						if ($DeviceType -in @("rmm", "sc", "sophos", "ninite")) {
							$RepairTickets_Subset = repair_tickets -ServiceTarget $DeviceType -Hostname $Hostname
						}

						$MostRecentTimespan = New-TimeSpan -Start $NewestDate -End $Now
						if (!$AutoFix -and $Device.id -notin $MoveDevices.ID -and $MostRecentTimespan.Days -le 7 -and ($RepairTickets_Subset | Measure-Object).Count -eq 0) {
							$SendEmail = $true
						}

						$BrokenConnection = [PsCustomObject]@{
							BrokenType = $DeviceType
							Hostname = $Hostname
							LastActive = $Activity[$i].last_active
							AutoFix_Attempted = $AutoFix
							SC_Time = if ($ActivityComparison.sc) { $ActivityComparison.sc[0].last_active } else { "NA" }
							RMM_Time = if ($ActivityComparison.rmm) { $ActivityComparison.rmm[0].last_active } else { "NA" }
							Sophos_Time = if ($ActivityComparison.sophos) { $ActivityComparison.sophos[0].last_active } else { "NA" }
						}

						if ($AzureConnected) {
							if (!$BrokenConnection.Azure_Time) {
								$BrokenConnection | Add-Member -NotePropertyName Azure_Time -NotePropertyValue "NA"
							}
							if (!$BrokenConnection.Intune_Time) {
								$BrokenConnection | Add-Member -NotePropertyName Intune_Time -NotePropertyValue "NA"
							}
							if ($ActivityComparison.azure) {
								$BrokenConnection.Azure_Time = $ActivityComparison.azure[0].last_active
							}
							if ($ActivityComparison.intune) {
								$BrokenConnection.Intune_Time = $ActivityComparison.intune[0].last_active
							}
						}
						if ($JCConnected) {
							if (!$BrokenConnection.JC_Time) {
								$BrokenConnection | Add-Member -NotePropertyName JC_Time -NotePropertyValue "NA"
							}
							if ($ActivityComparison.jc) {
								$BrokenConnection.JC_Time = $ActivityComparison.jc[0].last_active
							}
						}
						if ($Ninite_Machines) {
							if (!$BrokenConnection.Ninite_Time) {
								$BrokenConnection | Add-Member -NotePropertyName Ninite_Time -NotePropertyValue "NA"
							}
							if ($ActivityComparison.ninite) {
								$BrokenConnection.Ninite_Time = $ActivityComparison.ninite[0].last_active
							}
						}

						if (!$BrokenConnection.RepairTicket) {
							$BrokenConnection | Add-Member -NotePropertyName RepairTicket -NotePropertyValue "NA"
						}
						if (!$BrokenConnection.Link) {
							$BrokenConnection | Add-Member -NotePropertyName Link -NotePropertyValue ""
						}
						$BrokenConnection.RepairTicket = if (($RepairTickets_Subset | Measure-Object).Count -gt 0) { $RepairTickets_Subset.ticketNumber -join ", " }
						$BrokenConnection.Link = $Link
						$BrokenConnections += $BrokenConnection
					}
				}
			}
		}

		if ($SendEmail) {
			Write-Host "Warning! Broken connections were found!" -ForegroundColor Red

			# Try sending an email
			$TwoWeeksAgo = [int](New-TimeSpan -Start (Get-Date "01/01/1970") -End (Get-Date).AddDays(-14).ToUniversalTime()).TotalSeconds
			$EmailChangeType = "broken-connections-email"
			$Reason = "Email sent for devices found with a broken connection"

			$EmailQuery_Params = @{
				LogHistory = $LogHistory
				StartTime = $TwoWeeksAgo
				EndTime = 'now'
				ServiceTarget = 'email'
				ChangeType = $EmailChangeType
				Reason = $EmailReason
			}
			$History_Subset_Emails = log_query @EmailQuery_Params

			# no emails were already sent, continue
			if (($History_Subset_Emails | Measure-Object).count -eq 0) {
				# send an email
				$EmailSubject = "Device Audit on $Company_Acronym - Devices Found with a broken connection"
				$EmailIntro = "Devices with a broken connection were found. Auto-fixes have been attempted where possible. Please review:"
				$DeviceTable = @($BrokenConnections) | ConvertTo-HTML -Fragment -As Table | Out-String

				$HTMLEmail = $EmailTemplate -f `
								$EmailIntro, 
								"Devices Found with Broken Connections", 
								$DeviceTable, 
								"<br />Please review and fix these devices manually where necessary."

				$mailbody = @{
					"From" = $EmailFrom
					"To" = $EmailTo_FailedFixes
					"Subject" = $EmailSubject
					"HTMLContent" = $HTMLEmail
				} | ConvertTo-Json -Depth 6

				$headers = @{
					'x-api-key' = $Email_APIKey.Key
				}

				Invoke-RestMethod -Method Post -Uri $Email_APIKey.Url -Body $mailbody -Headers $headers -ContentType application/json
				Write-Host "Email Sent." -ForegroundColor Yellow

				# log the sent email
				log_change -Company_Acronym $Company_Acronym -ServiceTarget 'email' -RMM_Device_ID "" -SC_Device_ID "" -Sophos_Device_ID "" -ChangeType $EmailChangeType -Hostname "" -Reason $EmailReason
			}
		}

		Write-Host "Broken connections check complete."
		Write-Host "======================"
	}

	# Find devices that are in one system but not another
	if ($DOMissingConnectionSearch) {
		Write-Host "Searching for devices missing a connection..."
		$MissingConnections = @()
		$SendEmail = $false
		$Now = Get-Date

		foreach ($Device in $MatchedDevices) {
			$SCDeviceIDs = @($Device.sc_matches)
			$RMMDeviceIDs = @($Device.rmm_matches)
			$SophosDeviceIDs = @($Device.sophos_matches)
			$NiniteDeviceIDs = @($Device.ninite_matches)

			$ActivityComparison = $Device.activity_comparison
			$Activity = $ActivityComparison.Values | Sort-Object last_active
			$NewestDate = [DateTime]($Activity.last_active | Sort-Object | Select-Object -Last 1)
			$Timespan = New-TimeSpan -Start $NewestDate -End $Now

			if ($Timespan.Days -gt $InactiveDeleteDays) {
				# Inactive device, ignore (it'll get picked up in the next section)
				continue
			}
		
			if (($SCDeviceIDs | Measure-Object).count -eq 0 -or ($RMMDeviceIDs | Measure-Object).count -eq 0 -or ($SophosDeviceIDs | Measure-Object).count -eq 0 -or ($NiniteDeviceIDs | Measure-Object).count -eq 0) {
				$MissingTypes = @()

				if (($SCDeviceIDs | Measure-Object).count -eq 0 -and !(ignore_install -Device $Device -System 'sc')) {
					$MissingTypes += 'sc'
				}
				if (($RMMDeviceIDs | Measure-Object).count -eq 0 -and !(ignore_install -Device $Device -System 'rmm')) {
					$MissingTypes += 'rmm'
				}
				if (($SophosDeviceIDs | Measure-Object).count -eq 0 -and !(ignore_install -Device $Device -System 'sophos')) {
					$MissingTypes += 'sophos'
				}
				if (($NiniteDeviceIDs | Measure-Object).count -eq 0 -and !(ignore_install -Device $Device -System 'ninite')) {
					$MissingTypes += 'ninite'
				}

				if ($MissingTypes -contains 'sc' -and $MissingTypes -contains 'rmm' -and $MissingTypes -notcontains 'sophos' -and $Timespan.Days -gt 7) {
					# If this device is only in Sophos and hasn't been seen in the past week, lets just skip it.
					# It likely was decomissioned and Sophos wasn't removed
					continue
				}

				if (($MissingTypes | Measure-Object).count -gt 0) {
					$Hostnames = @()
					$DeviceType = $false
					$OS = $false
					
					if ($SCDeviceIDs) {
						$SCDevices = @()
						foreach ($DeviceID in $SCDeviceIDs) {
							$SCDevices += $SC_DevicesHash[$DeviceID]
						}
						$Hostnames += $SCDevices.Name
						$DeviceType = $SCDevices[0].DeviceType
						$OS = $SCDevices[0].GuestOperatingSystemName
					}
					if ($RMMDeviceIDs) {
						$RMMDevices = @()
						foreach ($DeviceID in $RMMDeviceIDs) {
							$RMMDevices += $RMM_DevicesHash[$DeviceID]
						}
						$Hostnames += $RMMDevices."Device Hostname"
						if ($DeviceType) {
							$DeviceType = $RMMDevices[0]."Device Type"
						}
						if (!$OS) {
							$OS = $RMMDevices[0]."Operating System"
						}
					}
					if ($SophosDeviceIDs) {
						$SophosDevices = @()
						foreach ($DeviceID in $SophosDeviceIDs) {
							$SophosDevices += $Sophos_DevicesHash[$DeviceID]
						}						
						$Hostnames += $SophosDevices.hostname
						if (!$DeviceType) {
							$DeviceType = $SophosDevices[0].type
						}
						if (!$OS) {
							$OS = $SophosDevices[0].OS
						}
					}
					if ($NiniteDeviceIDs) {
						$NiniteDevices = @()
						foreach ($DeviceID in $NiniteDeviceIDs) {
							$NiniteDevices += $Ninite_DevicesHash[$DeviceID]
						}						
						$Hostnames += $NiniteDevices.name
						if (!$DeviceType) {
							$DeviceType = if ($NiniteDevices[0].win_type -like "Server" -or $NiniteDevices[0].win_type -like "DomainController") {"Server"} else {"Workstation"}
						}
					}
					$Hostnames = $HostNames | Sort-Object -Unique

					# Don't mark Ninite as missing if this device isn't on Windows
					if ($MissingTypes -contains "ninite" -and $OS -notlike "*Windows*") {
						$MissingTypes = $MissingTypes | Where-Object {$_ -ne "ninite"}
					}
					if (!$MissingTypes) {
						continue
					}

					$SCLink = ""
					$RMMLink = ""
					$SophosLink = ""
					if ($SCDeviceIDs) {
						$SCLink = "$($SCLogin.URL)/Host#Access/All%20Machines/$($SCDevices[0].Name)/$($SCDeviceIDs[0])"
					}
					if ($RMMDeviceIDs) {
						if ($RMMDevices[0].url) {
							$RMMLink = $RMMDevices[0].url
						} else {
							$RMMLink = "https://$($DattoAPIKey.Region).centrastage.net/csm/search?qs=uid%3A$($RMMDeviceIDs[0])"
						}
					}
					if ($SophosDeviceIDs) {
						$SophosLink = "https://cloud.sophos.com/manage/devices/computers/$($SophosDevices[0].webID)"
					}
					$RMMAntivirus = $false
					if (!$SophosDeviceIDs -and $RMMDeviceIDs) {
						$RMMAntivirus = $RMMDevices[0].Antivirus
					}

					# See if we can try to automatically fix this issue
					$AutoFix = $false
					if (!$ReadOnly -and $MissingTypes -contains 'rmm' -and $MissingTypes -notcontains 'sc' -and $RMM_ID -and $SCLogin.Username -and $SCWebSession -and $Device.id -notin $MoveDevices.ID -and $Timespan.Days -lt $InactiveDeleteDaysRMM) {
						# Device missing in rmm but is in SC and we are using the SC api account, have the rmm org id, and this device is not in the $MoveDevices array (devices that look like they dont belong)
						# Only continue of the device was seen recently in SC (this will only work if it is active) and is using Windows
						foreach ($SCDevice in $SCDevices) {
							$LogParams = @{
								ServiceTarget = "sc"
								SC_Device_ID = $SCDevice.SessionID
								ChangeType = "install_rmm"
								Hostname = $SCDevice.Name
							}
							$AttemptCount = log_attempt_count @LogParams -LogHistory $LogHistory
							$EmailError = "RMM is not installed on $($LogParams.Hostname). The Device Audit script has tried to install RMM via SC $AttemptCount times now but it has not succeeded."
							$LogParams.RMM_Device_ID = $RMMDeviceIDs
							$LogParams.Sophos_Device_ID = $SophosDeviceIDs
							$LogParams.Reason = "RMM not installed"

							if ($SCDevice.GuestOperatingSystemName -like "*Windows*" -and $SCDevice.GuestOperatingSystemName -notlike "*Windows Embedded*") {
								if ($SCDevice.GuestLastSeen -gt (Get-Date).AddHours(-3)) {
									if (install_rmm_using_sc -SC_ID $SCDevice.SessionID -RMM_ORG_ID $RMM_ID -SCWebSession $SCWebSession) {
										$AutoFix = $true
										check_failed_attempts @LogParams -LogHistory $LogHistory -Company_Acronym $Company_Acronym -ErrorMessage $EmailError
										log_change @LogParams -Company_Acronym $Company_Acronym
									}
								} else {
									add_device_to_install_queue -SC_ID $SCDevice.SessionID -ToInstall 'rmm'
								}
							} elseif ($SCDevice.GuestOperatingSystemName -like "*Mac OS*") {
								if ($SCDevice.GuestLastSeen -gt (Get-Date).AddHours(-3)) {
									if (install_rmm_using_sc_mac -SC_ID $SCDevice.SessionID -RMM_ORG_ID $RMM_ID -SCWebSession $SCWebSession) {
										$AutoFix = $true
										check_failed_attempts @LogParams -LogHistory $LogHistory -Company_Acronym $Company_Acronym -ErrorMessage $EmailError
										log_change @LogParams -Company_Acronym $Company_Acronym
									}
								} else {
									add_device_to_install_queue -SC_ID $SCDevice.SessionID -ToInstall 'rmm'
								}
							}
						}
					}

					if (!$ReadOnly -and $MissingTypes -contains 'sc' -and $MissingTypes -notcontains 'rmm' -and $RMM_ID -and $Device.id -notin $MoveDevices.ID) {
						# Device missing in sc but is in RMM and we are using the rmm api, and this device is not in the $MoveDevices array (devices that look like they dont belong)
						# Only continue of the device was seen in RMM in the last 24 hours
						foreach ($RMMDevice in $RMMDevices) {
							if ($RMMDevice.suspended -ne "True") {
								if ($RMMDevice.Status -eq "Online" -or $RMMDevice."Last Seen" -eq "Currently Online" -or ($RMMDevice."Last Seen" -as [DateTime]) -gt (Get-Date).AddHours(-24)) {
									$LogParams = @{
										ServiceTarget = "rmm"
										RMM_Device_ID = $RMMDevice."Device UID"
										ChangeType = "install_sc"
										Hostname = $RMMDevice."Device Hostname"
									}
									$AttemptCount = log_attempt_count @LogParams -LogHistory $LogHistory

									if ($AttemptCount -gt 3) {
										uninstall_sc_using_rmm -RMM_Device $RMMDevice
									}
									if (install_sc_using_rmm -RMM_Device $RMMDevice) {
										$AttemptCount = log_attempt_count @LogParams -LogHistory $LogHistory
										$EmailError = "ScreenConnect is not installed on $($LogParams.Hostname). The Device Audit script has tried to install SC via RMM $AttemptCount times now but it has not succeeded."
										$LogParams.SC_Device_ID = $SCDeviceIDs
										$LogParams.Sophos_Device_ID = $SophosDeviceIDs
										$LogParams.Reason = "SC not installed"
		
										$AutoFix = $true
										check_failed_attempts @LogParams -LogHistory $LogHistory -Company_Acronym $Company_Acronym -ErrorMessage $EmailError
										log_change @LogParams -Company_Acronym $Company_Acronym
									}
								} else {
									add_device_to_install_queue -RMM_ID $RMMDevice."Device UID" -ToInstall 'sc'
								}
							}
						}
					}

					if (!$ReadOnly -and $MissingTypes -contains 'ninite' -and $MissingTypes -notcontains 'rmm' -and $RMM_ID -and $Device.id -notin $MoveDevices.ID) {
						# Device missing in ninite but is in RMM and we are using the rmm api, and this device is not in the $MoveDevices array (devices that look like they dont belong)`
						# Only continue if the device was seen in RMM in the last 24 hours
						foreach ($RMMDevice in $RMMDevices) {
							if ($RMMDevice.suspended -ne "True" -and $RMMDevice."Operating System" -like "*Windows*" -and $RMMDevice."Device Type" -notlike "*Server*") {
								if ($RMMDevice.Status -eq "Online" -or $RMMDevice."Last Seen" -eq "Currently Online" -or ($RMMDevice."Last Seen" -as [DateTime]) -gt (Get-Date).AddHours(-24)) {
									$LogParams = @{
										ServiceTarget = "rmm"
										RMM_Device_ID = $RMMDevice."Device UID"
										ChangeType = "install_ninite"
										Hostname = $RMMDevice."Device Hostname"
									}
									$AttemptCount = log_attempt_count @LogParams -LogHistory $LogHistory

									if (install_ninite_using_rmm -RMM_Device $RMMDevice) {
										$AttemptCount = log_attempt_count @LogParams -LogHistory $LogHistory
										$EmailError = "Ninite is not installed on $($LogParams.Hostname). The Device Audit script has tried to install Ninite via RMM $AttemptCount times now but it has not succeeded."
										$LogParams.SC_Device_ID = $SCDeviceIDs
										$LogParams.Sophos_Device_ID = $SophosDeviceIDs
										$LogParams.Ninite_Device_ID = $NiniteDeviceIDs
										$LogParams.Reason = "Ninite not installed"
	
										$AutoFix = $true
										check_failed_attempts @LogParams -LogHistory $LogHistory -Company_Acronym $Company_Acronym -ErrorMessage $EmailError
										log_change @LogParams -Company_Acronym $Company_Acronym
									}
								} else {
									add_device_to_install_queue -RMM_ID $RMMDevice."Device UID" -ToInstall 'ninite'
								}
							}
						}
					}

					$RepairTickets_Subset = @()
					$MissingTypes | ForEach-Object {
						if ($_ -in @("rmm", "sc", "sophos", "ninite")) {
							$RepairTickets_Subset += repair_tickets -ServiceTarget $_ -Hostname $Hostnames
						}
					}					

					if (!$AutoFix -and $Device.id -notin $MoveDevices.ID -and $Timespan.Days -le 7 -and ($RepairTickets_Subset | Measure-Object).Count -eq 0) {
						$SendEmail = $true
					}

					$MissingConnections += [PsCustomObject]@{
						Hostnames = $Hostnames -join ', '
						DeviceType = $DeviceType
						LastActive = $NewestDate
						InSC = if ($SCDeviceIDs) { "Yes" } elseif (ignore_install -Device $Device -System 'sc') { "Ignore" } else { "No" }
						InRMM = if ($RMMDeviceIDs) { "Yes" }  elseif (ignore_install -Device $Device -System 'rmm') { "Ignore" } else { "No" }
						InSophos = if ($SophosDeviceIDs) { "Yes" } elseif ($RMMAntivirus -and $RMMAntivirus -like "Sophos*") { "Yes, missing from portal" } elseif (ignore_install -Device $Device -System 'sophos') { "Ignore" } else { "No" }
						InNinite = if ($NiniteDeviceIDs) { "Yes" } elseif (ignore_install -Device $Device -System 'ninite') { "Ignore" } else { "No" }
						AutoFix_Attempted = $AutoFix
						RepairTicket = if (($RepairTickets_Subset | Measure-Object).Count -gt 0) { $RepairTickets_Subset.ticketNumber -join ", " } else { "NA" }
						SC_Link = $SCLink
						RMM_Link = $RMMLink
						Sophos_Link = $SophosLink
					}
				}
			}
		}

		if ($SendEmail) {
			Write-Host "Warning! Devices were found that are missing in 1 or more systems (RMM, SC, Sophos, or Ninite)." -ForegroundColor Red
			
			# Try sending an email
			$TwoWeeksAgo = [int](New-TimeSpan -Start (Get-Date "01/01/1970") -End (Get-Date).AddDays(-14).ToUniversalTime()).TotalSeconds
			$EmailChangeType = "missing-connections-email"
			$Reason = "Email sent for devices found with a missing connection"

			$EmailQuery_Params = @{
				LogHistory = $LogHistory
				StartTime = $TwoWeeksAgo
				EndTime = 'now'
				ServiceTarget = 'email'
				ChangeType = $EmailChangeType
				Reason = $EmailReason
			}
			$History_Subset_Emails = log_query @EmailQuery_Params

			# no emails were already sent, continue
			if (($History_Subset_Emails | Measure-Object).count -eq 0) {
				# send an email
				$EmailSubject = "Device Audit on $Company_Acronym - Devices Found that are missing a connection"
				$EmailIntro = "Devices were found that are missing in 1 or more systems (RMM, SC, Sophos, or Ninite). Auto-fixes have been attempted where possible. Please review:"
				$DeviceTable = @($MissingConnections) | Where-Object { $_.LastActive -gt (Get-Date (Get-Date).AddDays(-7)) } | ConvertTo-HTML -Fragment -As Table | Out-String

				$HTMLEmail = $EmailTemplate -f `
								$EmailIntro, 
								"Devices Found with Missing Connections", 
								$DeviceTable, 
								"<br />Please review and fix these devices manually where necessary."

				$mailbody = @{
					"From" = $EmailFrom
					"To" = $EmailTo_FailedFixes
					"Subject" = $EmailSubject
					"HTMLContent" = $HTMLEmail
				} | ConvertTo-Json -Depth 6

				$headers = @{
					'x-api-key' = $Email_APIKey.Key
				}

				Invoke-RestMethod -Method Post -Uri $Email_APIKey.Url -Body $mailbody -Headers $headers -ContentType application/json
				Write-Host "Email Sent." -ForegroundColor Yellow

				# log the sent email
				log_change -Company_Acronym $Company_Acronym -ServiceTarget 'email' -RMM_Device_ID "" -SC_Device_ID "" -Sophos_Device_ID "" -ChangeType $EmailChangeType -Hostname "" -Reason $EmailReason
			}
		}

		Write-Host "Missing connections check complete."
		Write-Host "======================"
	}

	if (!(Test-Path variable:InactiveDeleteDaysRMM)) {
		$InactiveDeleteDaysRMM = $InactiveDeleteDays
	}

	$DeviceIssueCheckRan = $false
	$DeviceUsageUpdateRan = $false
	$DeviceLocationsUpdateRan = $false
	$MonthlyStatsUpdated = $false
	$DeviceBillingUpdateRan = $false
	$DeviceUsersUpdateRan = $false
	$ITGLocations = $false 

	# Check for devices that haven't been seen in a long time (in $InactiveDeleteDays) and suggest they be deleted
	if ($DOInactiveSearch) {
		Write-Host "Searching for old inactive devices..."
		$InactiveDevices = @()
		$Now = Get-Date

		foreach ($Device in $MatchedDevices) {
			$ActivityComparison = $Device.activity_comparison
			$Activity = $ActivityComparison.Values | Sort-Object last_active

			if (($Activity | Measure-Object).count -gt 0) {
				$NewestDate = [DateTime]($Activity.last_active | Sort-Object | Select-Object -Last 1)
				$Timespan = New-TimeSpan -Start $NewestDate -End $Now
				$DeviceIssueCheckRan = $true
				
				if ($Timespan.Days -gt $InactiveDeleteDays -or ($Activity.type -contains "rmm" -and $Timespan.Days -gt $InactiveDeleteDaysRMM)) {
					$RMMOnly = $false
					if ($Timespan.Days -lt $InactiveDeleteDays){
						$RMMOnly = $true
					}

					$Hostnames = @()
					$SCDeviceID = if ($ActivityComparison.sc) { $ActivityComparison.sc[0].id } else { $false }
					$RMMDeviceID = if ($ActivityComparison.rmm) { $ActivityComparison.rmm[0].id } else { $false }
					$SophosDeviceID = if ($ActivityComparison.sophos) { $ActivityComparison.sophos[0].id } else { $false }
					$JCDeviceID = $false
					if ($JCConnected) {
						$JCDeviceID = if ($ActivityComparison.jc) { $ActivityComparison.jc[0].id } else { $false }
					}
					$NiniteDeviceID = $false
					if ($Ninite_Machines) {
						$NiniteDeviceID = if ($ActivityComparison.ninite) { $ActivityComparison.ninite[0].id } else { $false }
					}
					$ITG_IDs = $Device.itg_matches

					$User = $false
					$OperatingSystem = $false
					$Model = $false
					$WarrantyExpiry = ''

					if ($SCDeviceID) {
						$SCDevice = $SC_DevicesHash[$SCDeviceID]
						$Hostnames += $SCDevice.Name
						$User = $SCDevice.GuestLoggedOnUserName
						$OperatingSystem = $SCDevice.GuestOperatingSystemName
						$Model = $SCDevice.GuestMachineModel
					}
					if ($RMMDeviceID) {
						$RMMDevice = $RMM_DevicesHash[$RMMDeviceID]
						$Hostnames += $RMMDevice."Device Hostname"
						if (!$User) {
							$User = ($RMMDevice."Last User" -split '\\')[1]
						}
						if (!$OperatingSystem) {
							$OperatingSystem = $RMMDevice."Operating System"
						}
						if (!$Model) {
							$Model = $RMMDevice."Device Model"
						}
						$WarrantyExpiry = $RMMDevice."Warranty Expiry"
					}
					if ($SophosDeviceID) {
						$SophosDevice = $Sophos_DevicesHash[$SophosDeviceID]
						$Hostnames += $SophosDevice.hostname
						if (!$User) {
							$User = $SophosDevice.LastUser
						}
						if (!$OperatingSystem) {
							$OperatingSystem = $SophosDevice.OS
						}
					}
					if ($JCDeviceID) {
						$JCDevice = $JC_DevicesHash[$JCDeviceID]
						$Hostnames += if ($JCDevice.hostname) { $JCDevice.hostname -replace ".local", "" } else { $JCDevice.displayName }
						if (!$User) {
							if ($JC_Users) {
								$User = $JC_Users | Where-Object { $_.SystemID -eq $JCDevice.id } | Select-Object -Property Username -ExpandProperty Username
							}
						}
						if (!$OperatingSystem) {
							$OperatingSystem = "$($JCDevice.os) $($JCDevice.version)"
						}
					}
					if ($NiniteDeviceID) {
						$NiniteDevice = $Ninite_DevicesHash[$NiniteDeviceID]
						$Hostnames += if ($NiniteDevice.name) { $NiniteDevice.name }
						$Hostnames += if ($NiniteDevice.machine_name) { $NiniteDevice.machine_name }
						if (!$User -and $NiniteDevice.last_user) {
							$User = $NiniteDevice.last_user
						}
						if (!$OperatingSystem -and $NiniteDevice.win_product_name) {
							$OperatingSystem = $NiniteDevice.win_product_name
						}
					}
					$Hostnames = $HostNames | Sort-Object -Unique

					$SCLink = ''
					$RMMLink = ''
					$SophosLink = ''
					$JCLink = ''
					if ($SCDeviceID) {
						$SCLink = "$($SCLogin.URL)/Host#Access/All%20Machines/$($SCDevice.Name)/$($SCDeviceID)"
					}
					if ($RMMDeviceID) {
						if ($RMMDevice.url) {
							$RMMLink = $RMMDevice.url
						} else {
							$RMMLink = "https://$($DattoAPIKey.Region).centrastage.net/csm/search?qs=uid%3A$($RMMDeviceID)"
						}
					}
					if ($SophosDeviceID) {
						$SophosLink = "https://cloud.sophos.com/manage/devices/computers/$($SophosDevice.webID)"
					}
					if ($JCDeviceID) {
						$JCLink = "https://console.jumpcloud.com/#/devices/$($JCDevice.id)/details"
					}
					$RMMAntivirus = $false
					if (!$SophosDeviceID -and $RMMDeviceID) {
						$RMMAntivirus = $RMMDevice.Antivirus
					} elseif (!$SophosDeviceID -and $NiniteDeviceID) {
						$NiniteAV = $NiniteDevice.anti_virus
						if ($NiniteAV.Count -gt 0) {
							$NiniteAV = $NiniteAV | Where-Object { ($([Convert]::ToString($($_.productState), 16)).PadLeft(6,"0")).Substring(2,1) -eq 1 }
						}
						if ($NiniteAV.Count -gt 0 -and ($NiniteAV.onAccessScanningEnabled -contains $true)) {
							$NiniteAV = $NiniteAV | Where-Object { $_.onAccessScanningEnabled -eq $true }
						}
						if ($NiniteAV.Count -gt 0 -and ($NiniteAV.displayName -like "*Sophos Intercept*")) {
							$NiniteAV = $NiniteAV | Where-Object { $_.displayName -like "*Sophos Intercept*" }
						}
						if ($NiniteAV.Count -gt 0 -and ($NiniteAV.displayName -like "*Sophos*")) {
							$NiniteAV = $NiniteAV | Where-Object { $_.displayName -like "*Sophos*" }
						}
						$NiniteAV = $NiniteAV | Select-Object -First 1
						$RMMAntivirus = $NiniteAV.displayName
					}

					$DeleteSC = "No"
					if ($SCDeviceID -and !$RMMOnly) {
						$DeleteSC = "Yes, manually delete"
						$AllowDeletion = $true
						if ($DontAutoDelete -and ($DontAutoDelete.Hostnames -contains $SCDevice.Hostname -or $DontAutoDelete.SC -contains $SCDevice.Hostname -or $DontAutoDelete.SC -contains $SCDeviceID)) {
							$AllowDeletion = $false
						}
						if (!$ReadOnly -and $AllowDeletion) {
							$Deleted = delete_from_sc -SC_ID $SCDeviceID  -SCWebSession $SCWebSession
							if ($Deleted) {
								$DeleteSC = "Yes, auto attempted"
								log_change -Company_Acronym $Company_Acronym -ServiceTarget "sc" -RMM_Device_ID $Device.rmm_matches -SC_Device_ID $SCDeviceID -Sophos_Device_ID $Device.sophos_matches -ChangeType "delete" -Hostname $SCDevice.Name -Reason "Inactive"
							}
						}
					}

					$DeleteRMM = "No"
					if ($RMMDeviceID) {
						$AllowDeletion = $true
						if ($DontAutoDelete -and ($DontAutoDelete.Hostnames -contains $RMMDevice."Device Hostname" -or $DontAutoDelete.RMM -contains $RMMDevice."Device Hostname" -or $DontAutoDelete.RMM -contains $RMMDeviceID)) {
							$AllowDeletion = $false
						}
						if (!$ReadOnly -and !$RMMDevice.ToDelete -and $AllowDeletion) {
							delete_from_rmm -RMM_Device_ID $RMMDeviceID						
							$DeleteRMM = "Yes, udf set for deletion"
							log_change -Company_Acronym $Company_Acronym -ServiceTarget "rmm" -RMM_Device_ID $RMMDeviceID -SC_Device_ID $Device.sc_matches -Sophos_Device_ID $Device.sophos_matches -ChangeType "delete" -Hostname $SCDevice.Name -Reason "Inactive"
						} elseif ($RMMDevice.ToDelete) {
							$DeleteRMM = "Pending deletion"
						} else {
							$DeleteRMM = "Yes, manually delete"
						}
					}

					$DeleteSophos = "No"
					if ($SophosDeviceID -and !$RMMOnly) {
						$DeleteSophos = "Yes, manually delete if decommed"
						$AllowDeletion = $true
						if ($DontAutoDelete -and ($DontAutoDelete.Hostnames -contains $SophosDevice.hostname -or $DontAutoDelete.Sophos -contains $SophosDevice.hostname -or $DontAutoDelete.Sophos -contains $SophosDeviceID)) {
							$AllowDeletion = $false
						}
						<# if ($InactiveAutoDeleteSophos -and !$ReadOnly -and $Timespan.Days -gt $InactiveAutoDeleteSophos -and $AllowDeletion) {
							$Deleted = delete_from_sophos -Sophos_Device_ID $SophosDeviceID -TenantApiHost $TenantApiHost -SophosHeader $SophosHeader
							if ($Deleted) {
								$DeleteSophos = "Yes, auto attempted"
								log_change -Company_Acronym $Company_Acronym -ServiceTarget "sophos" -Sophos_Device_ID $SophosDevice.webID -RMM_Device_ID $Device.rmm_matches -SC_Device_ID $Device.sc_matches -ChangeType "delete" -Hostname $SCDevice.Name -Reason "Inactive"
							}
						} #>
					}

					$DeleteJC = "No"
					if ($JCDeviceID -and !$RMMOnly) {
						$DeleteJC = "Yes, manually delete"
						$AllowDeletion = $true
						if ($DontAutoDelete -and (($JCDevice.hostname -and $DontAutoDelete.Hostnames -contains $JCDevice.hostname) -or $DontAutoDelete.Hostnames -contains $JCDevice.displayName -or ($JCDevice.hostname -and $DontAutoDelete.JC -contains $JCDevice.hostname) -or $DontAutoDelete.JC -contains $JCDevice.displayName -or $DontAutoDelete.JC -contains $OrderedDevice.id)) {
							$AllowDeletion = $false
						}
						if (!$ReadOnly -and $AllowDeletion) {
							$Deleted = delete_from_jc -JC_ID $JCDeviceID
							if ($Deleted) {
								$DeleteJC = "Yes, auto attempted"
								log_change -Company_Acronym $Company_Acronym -ServiceTarget "jc" -RMM_Device_ID $Device.rmm_matches -SC_Device_ID $Device.sc_matches -Sophos_Device_ID $Device.sophos_matches -JC_Device_ID $JCDeviceID -ChangeType "delete" -Hostname if ($JCDevice.hostname) { $JCDevice.hostname } else { $JCDevice.displayName } -Reason "Inactive"
							}
						}
					}

					$DeleteNinite = "No"
					if ($NiniteDeviceID -and !$RMMOnly) {
						$DeleteNinite = "Yes, manually delete"
						$AllowDeletion = $true
						if ($DontAutoDelete -and (
							($NiniteDevice.name -and $DontAutoDelete.Hostnames -contains $NiniteDevice.name) -or 
							($NiniteDevice.name2 -and $DontAutoDelete.Hostnames -contains $NiniteDevice.name2) -or
							($NiniteDevice.machine_name -and $DontAutoDelete.Hostnames -contains $NiniteDevice.machine_name) -or  
							($NiniteDevice.name -and $DontAutoDelete.Ninite -contains $NiniteDevice.name) -or 
							($NiniteDevice.name2 -and $DontAutoDelete.Ninite -contains $NiniteDevice.name2) -or
							($NiniteDevice.machine_name -and $DontAutoDelete.Ninite -contains $NiniteDevice.machine_name) -or  
							$DontAutoDelete.Ninite -contains $OrderedDevice.id
						)) {
							$AllowDeletion = $false
						}
						if (!$ReadOnly -and $AllowDeletion) {
							$Deleted = delete_from_ninite -Ninite_ID $NiniteDeviceID -NiniteWebSession $NiniteWebSession -NiniteHeader $NiniteHeader
							if ($Deleted) {
								$DeleteNinite = "Yes, auto attempted"
								$Hostname = if ($NiniteDevice.name) { $NiniteDevice.name } elseif ($NiniteDevice.name2) { $NiniteDevice.name } else { $NiniteDevice.machine_name }
								log_change -Company_Acronym $Company_Acronym -ServiceTarget "ninite" -RMM_Device_ID $Device.rmm_matches -SC_Device_ID $Device.sc_matches -Sophos_Device_ID $Device.sophos_matches -Ninite_Device_ID $NiniteDeviceID -ChangeType "delete" -Hostname $Hostname -Reason "Inactive"
							}
						}
					}

					$DeleteITG = "No"
					if ($ITGConnected -and $ITG_IDs -and !$RMMOnly) {
						if (!$ReadOnly) {
							foreach ($ID in $ITG_IDs) {
								$Deleted = archive_itg -ITG_Device_ID $ID
								if ($Deleted) {
									$DeleteITG = "Yes"
									$ITG_Device = $ITG_DevicesHash[$ID]
									log_change -Company_Acronym $Company_Acronym -ServiceTarget "itg" -RMM_Device_ID $Device.rmm_matches -SC_Device_ID $Device.sc_matches -Sophos_Device_ID $Device.sophos_matches -ChangeType "delete" -Hostname $ITG_Device.attributes.name -Reason "Inactive"
								}
							}
						}
					}


					$InactiveDeviceInfo = [PsCustomObject]@{
						Hostnames = $Hostnames -join ', '
						LastActive = $NewestDate
						User = $User
						OS = $OperatingSystem
						Model = $Model
						WarrantyExpiry = $WarrantyExpiry
						InSC = if ($SCDeviceID -and !$RMMOnly) { "Yes" } elseif ($SCDeviceID) { "Yes, but don't delete yet" } else { "No" }
						InRMM = if ($RMMDeviceID) { "Yes" } else { "No" }
						InSophos = if ($SophosDeviceID -and !$RMMOnly) { "Yes" } elseif ($SophosDeviceID) { "Yes, but don't delete yet" } elseif ($RMMAntivirus -and $RMMAntivirus -like "Sophos*") { "Yes, missing from portal" } else { "No" }
						InJC = if ($JCDeviceID -and !$RMMOnly) { "Yes" } elseif ($JCDeviceID) { "Yes, but don't delete yet" } else { "No" }
						InNinite = if ($NiniteDeviceID -and !$RMMOnly) { "Yes" } elseif ($NiniteDeviceID) { "Yes, but don't delete yet" } else { "No" }
						DeleteSC = $DeleteSC
						DeleteRMM = $DeleteRMM
						DeleteSophos = $DeleteSophos
						DeleteJC = $DeleteJC
						DeleteNinite = $DeleteNinite
						ArchiveITG = $DeleteITG
						SC_Time = if ($ActivityComparison.sc) { $ActivityComparison.sc[0].last_active } else { "NA" }
						RMM_Time = if ($ActivityComparison.rmm) { $ActivityComparison.rmm[0].last_active } else { "NA" }
						Sophos_Time = if ($ActivityComparison.sophos) { $ActivityComparison.sophos[0].last_active } else { "NA" }
						JC_Time = if ($JCConnected -and $ActivityComparison.jc) { $ActivityComparison.jc[0].last_active } else { "NA" }
						Ninite_Time = if ($Ninite_Machines -and $ActivityComparison.ninite) { $ActivityComparison.ninite[0].last_active } else { "NA" }
						SC_Link = $SCLink
						RMM_Link = $RMMLink
						Sophos_Link = $SophosLink
						JC_Link = $JCLink
					}

					if (!$JCConnected) {
						$InactiveDeviceInfo.PSObject.Properties.Remove('InJC');
						$InactiveDeviceInfo.PSObject.Properties.Remove('DeleteJC');
						$InactiveDeviceInfo.PSObject.Properties.Remove('JC_Time');
						$InactiveDeviceInfo.PSObject.Properties.Remove('JC_Link');
					}

					$InactiveDevices += $InactiveDeviceInfo
				}
			}
		}

		if (($InactiveDevices | Measure-Object).count -gt 0) {
			Write-Host "Warning! Old inactive devices were found!" -ForegroundColor Red
		}

		Write-Host "Inactive devices check complete."
		Write-Host "======================"
	}

	# Save each user and the computer(s) they are using into the Usage database (for user audits and documenting who uses each computer), then update users assigned to each computer
	if ($DOUsageDBSave) {
		# Connect to Account and DB
		$Account_Name = "stats-$($Company_Acronym.ToLower())"
		$Account = Get-CosmosDbAccount -Name $Account_Name -ResourceGroupName $Database_Connection.ResourceGroup
		if (!$Account) {
			try {
				New-CosmosDbAccount -Name $Account_Name -ResourceGroupName $Database_Connection.ResourceGroup -Location 'WestUS2' -Capability @('EnableServerless')
			} catch { 
				Write-Host "Account creation failed for $Company_Acronym. Exiting..." -ForegroundColor Red
				exit
			} 
			$Account = Get-CosmosDbAccount -Name $Account_Name -ResourceGroupName $Database_Connection.ResourceGroup
			
		}
		$PrimaryKey = Get-CosmosDbAccountMasterKey -Name $Account_Name -ResourceGroupName $Database_Connection.ResourceGroup

		$DB_Name = "DeviceUsage"
		$cosmosDbContext = New-CosmosDbContext -Account $Account_Name -Database $DB_Name -Key $PrimaryKey
	
		# Create new DB if one does not already exist
		try {
			Get-CosmosDbDatabase -Context $cosmosDbContext -Id $DB_Name | Out-Null
		} catch {
			if ($_.Exception.Response.StatusCode -eq "NotFound") {
				try {
					New-CosmosDbDatabase -Context $cosmosDbContext -Id $DB_Name | Out-Null
				} catch { 
					Write-Host "Database creation failed. Exiting..." -ForegroundColor Red
					exit
				}
			}
		}
	
		# Create collections for this customer if they don't already exist
		try {
			Get-CosmosDbCollection -Context $cosmosDbContext -Id "Users" | Out-Null
		} catch {
			try {
				New-CosmosDbCollection -Context $cosmosDbContext -Database $DB_Name -Id "Users" -PartitionKey "type" | Out-Null
			} catch {
				Write-Host "Table creation failed. Exiting..." -ForegroundColor Red
				exit
			}
			Write-Host "Created new table: Users"
		}
		try {
			Get-CosmosDbCollection -Context $cosmosDbContext -Id "Computers" | Out-Null
		} catch {
			try {
				New-CosmosDbCollection -Context $cosmosDbContext -Database $DB_Name -Id "Computers" -PartitionKey "type"| Out-Null
			} catch {
				Write-Host "Table creation failed. Exiting..." -ForegroundColor Red
				exit
			}
			Write-Host "Created new table: Computers"
		}
		try {
			Get-CosmosDbCollection -Context $cosmosDbContext -Id "Usage" | Out-Null
		} catch {
			try {
				New-CosmosDbCollection -Context $cosmosDbContext -Database $DB_Name -Id "Usage" -PartitionKey "yearmonth" | Out-Null
			} catch {
				Write-Host "Table creation failed. Exiting..." -ForegroundColor Red
				exit
			}
			Write-Host "Created new table: Usage"
		}
		
		Write-Host "Saving usage stats..."
	
		$Now = Get-Date
		$Now_UTC = Get-Date (Get-Date).ToUniversalTime() -UFormat '+%Y-%m-%dT%H:%M:%S.000Z'
	
		# Get all the computers and users first and query them in powershell to reduce db usage. This is MUCH cheaper than querying as we go!
		$Query = "SELECT * FROM Computers c"
		$ExistingComputers = Get-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "Computers" -Query $Query -PartitionKey 'computer'
		$Query = "SELECT * FROM Users u"
		$ExistingUsers = Get-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "Users" -Query $Query -PartitionKey 'user'

		# We will also only add a usage entry if one has not already been added today
		$Year_Month = Get-Date -Format 'yyyy-MM'
		$Query = "SELECT * FROM Usage u WHERE u.UseDateTime >= '$(Get-Date -UFormat '+%Y-%m-%dT00:00:00.000Z')'"
		$ExistingUsageToday = Get-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "Usage" -Query $Query -PartitionKey $Year_Month
	
		foreach ($Device in $MatchedDevices) {
			$ActivityComparison = $Device.activity_comparison
			$Activity = $ActivityComparison.Values | Sort-Object last_active
	
			if (($Activity | Measure-Object).count -gt 0) {
				$NewestDate = [DateTime]($Activity.last_active | Sort-Object | Select-Object -Last 1)
				$Timespan = New-TimeSpan -Start $NewestDate -End $Now
				$DeviceUsageUpdateRan = $true
	
				if ($Timespan.TotalHours -gt 6) {
					# The device has not been seen in the last 6 hours, lets just skip it
					continue;
				}
	
				$LastActive = $NewestDate;
				$SCDevices = @()
				foreach ($DeviceID in $Device.sc_matches) {
					$SCDevices += $SC_DevicesHash[$DeviceID]
				}
	
				# If this device exists in SC, lets make sure it was also recently logged into (not just on)
				$SCLastActive = ($SCDevices | Sort-Object -Property GuestLastActivityTime | Select-Object -Last 1).GuestLastActivityTime
				if ($SCLastActive -and (New-TimeSpan -Start $SCLastActive -End $Now).TotalHours -gt 6) { 
					# online but not logged in, skip it
					continue;
				} elseif ($SCLastActive) {
					# replace $LastActive with the last active time
					$LastActive = $SCLastActive
				}
	
				$RMMDevices = @()
				foreach ($DeviceID in $Device.rmm_matches) {
					$RMMDevices += $RMM_DevicesHash[$DeviceID]
				}
	
				if (!$SCDevices -and !$RMMDevices) {
					# Lets ignore anything that's only in sophos, we can't match those securely enough for this
					continue;
				}
	
				# The device has been recently seen and logged into (can only tell if it was recently logged into if the device is in SC)
				$Hostname = $false
				$Username = $false
				$Domain = $false
				$DeviceType = $false
				$OperatingSystem = $false
				$Manufacturer = $false
				$Model = $false
				$WarrantyExpiry = $false
	
				if ($RMMDevices) {
					$RMMDevice = $RMMDevices | Sort-Object -Property "Last Seen" | Select-Object -Last 1
					$Hostname = $RMMDevice."Device Hostname"
					$DeviceType = $RMMDevice."Device Type"
					$OperatingSystem = $RMMDevice."Operating System"
					$Manufacturer = $RMMDevice."Manufacturer"
					$Model = $RMMDevice."Device Model"
					$WarrantyExpiry = $RMMDevice."Warranty Expiry"
	
					if ($RMMDevice."Last User" -like "*\*") {
						$Username = ($RMMDevice."Last User" -split '\\')[1]
					} else {
						$Username = $RMMDevice."Last User"
					}
					if ($RMMDevice."Last User" -like "AzureAD\*") {
						$Domain = "AzureAD"
					} else {
						$Domain = $RMMDevice.domain
					}
					if (!$Domain -or $Domain -like $Hostname) {
						$Domain = $false
					}
				}
	
				if ($SCDevices) {
					$SCDevice = $SCDevices | Sort-Object -Property GuestLastSeen | Select-Object -Last 1
					if (!$Hostname) {
						$Hostname = $SCDevice.Name
					}
					if (!$DeviceType) {
						$DeviceType = $SCDevice.DeviceType
					}
					if (!$Username) {
						$Username = $SCDevice.GuestLoggedOnUserName
					}
					if (!$Domain -and $SCDevice.GuestLoggedOnUserDomain -and $SCDevice.GuestLoggedOnUserDomain -notlike $Hostname) {
						$Domain = $SCDevice.GuestLoggedOnUserDomain
					}
					$OperatingSystem = $SCDevice.GuestOperatingSystemName
					if (!$Manufacturer) {
						$Manufacturer = $SCDevice.GuestMachineManufacturerName
					}
					if (!$Model) {
						$Model = $SCDevice.GuestMachineModel
					}
				}
	
				if (!$Username -or $Username -in $UsernameBlacklist) {
					# skip this if it's in the username blacklist
					continue;
				}
	
				$SerialNumbers = @()
				$SerialNumbers += $SCDevices.GuestMachineSerialNumber
				$SerialNumbers += $RMMDevices."Serial Number"
				$SerialNumbers = $SerialNumbers | Where-Object { $_ -notin $IgnoreSerials }
				$SerialNumbers = $SerialNumbers | Sort-Object -Unique
	
				if (!$DeviceType) {
					if ($OperatingSystem -and $OperatingSystem -like "*Server*") {
						$DeviceType = "Server"
					} else {
						$DeviceType = "Workstation"
					}
				}
				
				if ($DeviceType -eq "Server") {
					# Skip servers
					continue;
				}
	
				# cleanup data to be more readable
				if ($Manufacturer) {
					$Manufacturer = manufacturer_cleanup -Manufacturer $Manufacturer
				}
	
				if ($OperatingSystem) {
					if ($OperatingSystem -like "Microsoft*") {
						$OperatingSystem = $OperatingSystem -replace " ?(((\d+)\.*)+)$", ""
					} elseif ($OperatingSystem -like "VMware*") {
						$OperatingSystem = $OperatingSystem -replace " ?(build\d*) (((\d+)\.*)+)$", ""
					}
				}
	
				if ($WarrantyExpiry) {
					$WarrantyExpiry = $WarrantyExpiry -replace " UTC$", ""
					$WarrantyExpiry = ([DateTime]$WarrantyExpiry).ToString("yyyy-MM-ddT00:00:00.000Z")
				}
	
				$LastActive = Get-Date $LastActive.ToUniversalTime() -UFormat '+%Y-%m-%dT%H:%M:%S.000Z'
				$Year_Month = Get-Date $LastActive -Format 'yyyy-MM'
	
				# Lets see if this computer is already in the database
				if ($SerialNumbers) {
					$Computers = $ExistingComputers | Where-Object { $_.SerialNumber -match "\|" + ($SerialNumbers -join "|") + "\|" }
				} else {
					$Computers = $ExistingComputers | Where-Object { $_.Hostname -like $Hostname }
				}
	
				# Narrow down to 1 computer
				if (($Computers | Measure-Object).Count -gt 1) {
					$Computers_Accuracy = $Computers;
					$Computers_Accuracy | Add-Member -NotePropertyName Accuracy -NotePropertyValue 0
					foreach ($Computer in $Computers_Accuracy) {
						$Accuracy = 0;
						if ($Hostname -like $Computer.Hostname) {
							$Accuracy++
						}
						$Device.sc_matches | ForEach-Object {
							if ("%|$($_)|%" -like $Computer.SC_ID) {
								$Accuracy++
							}
						}
						$Device.rmm_matches | ForEach-Object {
							if ("%|$($_)|%" -like $Computer.RMM_ID) {
								$Accuracy++
							}
						}
						$Device.sophos_matches | ForEach-Object {
							if ("%|$($_)|%" -like $Computer.Sophos_ID) {
								$Accuracy++
							}
						}
						$SerialNumbers | ForEach-Object {
							if ("%|$($_)|%" -like $Computer.SerialNumber) {
								$Accuracy++
							}
						}
						if ($Manufacturer -like $Computer.Manufacturer) {
							$Accuracy++
						}
						if ($Model -like $Computer.Model) {
							$Accuracy++
						}
						if ($OperatingSystem -like $Computer.OS) {
							$Accuracy++
						}
						$Computer.Accuracy = $Accuracy
					}
	
					$BestComputer = $Computers_Accuracy | Sort-Object -Property Accuracy, LastUpdated -Descending | Select-Object -First 1
					$Computers = $Computers | Where-Object { $_.id -eq $BestComputer[0].id }
				}
	
				$SC_String = "|$($Device.sc_matches -join '|')|"
				$RMM_String = "|$($Device.rmm_matches -join '|')|"
				$Sophos_String = "|$($Device.sophos_matches -join '|')|"
				$ITG_String = "|$($Device.itg_matches -join '|')|"
				$Autotask_String = "|$($Device.autotask_matches -join '|')|"
				$SerialNum_String = "|$($SerialNumbers  -join '|')|"
	
				if (!$Computers) {
					# No computer found, lets insert it
					$ComputerID = $([Guid]::NewGuid().ToString())
					$Computer = @{
						id = $ComputerID
						Hostname = $Hostname
						SC_ID = $SC_String
						RMM_ID = $RMM_String
						Sophos_ID = $Sophos_String
						Autotask_ID = $Autotask_String
						ITG_ID = $ITG_String
						DeviceType = $DeviceType
						SerialNumber = $SerialNum_String
						Manufacturer = $Manufacturer
						Model = $Model
						OS = $OperatingSystem
						WarrantyExpiry = $WarrantyExpiry
						LastUpdated = $Now_UTC
						type = "computer"
					} | ConvertTo-Json
					New-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "Computers" -DocumentBody $Computer -PartitionKey 'computer' | Out-Null
				} else {
					# Computer exists, see if we need to update the details
					$UpdateRequired = $false
					$UpdatedComputer = $Computers[0] | Select-Object Id, Hostname, SC_ID, RMM_ID, Sophos_ID, Autotask_ID, ITG_ID, DeviceType, SerialNumber, Manufacturer, Model, OS, WarrantyExpiry, LastUpdated, type
					if ($Hostname -ne $Computers.Hostname) {
						$UpdatedComputer.Hostname = $Hostname
						$UpdateRequired = $true
					}
					if ($DeviceType -ne $Computers.DeviceType) {
						$UpdatedComputer.DeviceType = $DeviceType
						$UpdateRequired = $true
					}
					if ($Manufacturer -ne $Computers.Manufacturer) {
						$UpdatedComputer.Manufacturer = $Manufacturer
						$UpdateRequired = $true
					}
					if ($Model -ne $Computers.Model) {
						$UpdatedComputer.Model = $Model
						$UpdateRequired = $true
					}
					if ($OperatingSystem -ne $Computers.OS) {
						$UpdatedComputer.OS = $OperatingSystem
						$UpdateRequired = $true
					}
					if ($WarrantyExpiry -ne $Computers.WarrantyExpiry) {
						$UpdatedComputer.WarrantyExpiry = $WarrantyExpiry
						$UpdateRequired = $true
					}
		
					if ($SC_String -ne $Computers.SC_ID) {
						$UpdatedComputer.SC_ID = $SC_String
						$UpdateRequired = $true
					}
					if ($RMM_String -ne $Computers.RMM_ID) {
						$UpdatedComputer.RMM_ID = $RMM_String
						$UpdateRequired = $true
					}
					if ($Sophos_String -ne $Computers.Sophos_ID) {
						$UpdatedComputer.Sophos_ID = $Sophos_String
						$UpdateRequired = $true
					}
					if (!$Computers.Autotask_ID -or $Autotask_String -ne $Computers.Autotask_ID) {
						if (!(Get-Member -inputobject $UpdatedComputer -name "Autotask_ID" -Membertype Properties)) {
							$UpdatedComputer | Add-Member -NotePropertyName Autotask_ID -NotePropertyValue $null
						}
						$UpdatedComputer.Autotask_ID = $Autotask_String
						$UpdateRequired = $true
					}
					if (!$Computers.ITG_ID -or $ITG_String -ne $Computers.ITG_ID) {
						if (!(Get-Member -inputobject $UpdatedComputer -name "ITG_ID" -Membertype Properties)) {
							$UpdatedComputer | Add-Member -NotePropertyName ITG_ID -NotePropertyValue $null
						}
						$UpdatedComputer.ITG_ID = $ITG_String
						$UpdateRequired = $true
					}
					if ($SerialNum_String -ne $Computers.SerialNumber) {
						$UpdatedComputer.SerialNumber = $SerialNum_String
						$UpdateRequired = $true
					}
		
					$ComputerID = $Computers[0].Id
					if ($UpdateRequired) {
						$UpdatedComputer.LastUpdated = $Now_UTC
						Set-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "Computers" -Id $ComputerID -DocumentBody ($UpdatedComputer | ConvertTo-Json) -PartitionKey 'computer' | Out-Null
					}
				}

				if ($Domain -and $Domain -eq "AzureAD") { 
					$DomainOrLocal = "AzureAD"
				} elseif ($Domain -and $Domain -ne "WORKGROUP") {
					$DomainOrLocal = "Domain"
				} else { 
					$DomainOrLocal = "Local"
				}
	
				# Get the User ID, if not already in DB, add a new user
				$User = $ExistingUsers | Where-Object { $_.Username -like $Username } | Sort-Object LastUpdated | Select-Object -First 1
	
				if (!$User) {
					# Add user
					$UserID = $([Guid]::NewGuid().ToString())
					$User = @{
						id = $UserID
						Username = $Username
						DomainOrLocal = $DomainOrLocal
						Domain = $Domain
						ADUsername = $null
						O365Email = $null
						ITG_ID = $null
						LastUpdated = $Now_UTC
						type = "user"
					} | ConvertTo-Json
					New-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "Users" -DocumentBody $User -PartitionKey 'user' | Out-Null
				} else {
					# If changing fields, update in user audit as well
					$User = $User | Select-Object Id, Domain, DomainOrLocal, Username, LastUpdated, type, O365Email, ITG_ID, ADUsername
					$UserID = $User[0].Id
					if (!$User.DomainOrLocal -or $User.Domain -ne $Domain -or $User.DomainOrLocal -ne $DomainOrLocal) {
						$User.DomainOrLocal = $DomainOrLocal
						$User.Domain = $Domain
						$User.LastUpdated = $Now_UTC
						Set-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "Users" -Id $UserID -DocumentBody ($User | ConvertTo-Json) -PartitionKey 'user' | Out-Null
					}
				}

				# If a usage entry already exists today, skip adding another
				if (($ExistingUsageToday | Where-Object { $_.ComputerID -eq $Computers.id -and $_.UserID -eq $User.id } | Measure-Object).Count -gt 1) {
					continue
				}
	
				# Add a usage entry
				$ID = $([Guid]::NewGuid().ToString())
				$Usage = @{
					id = $ID
					ComputerID = $ComputerID
					UserID = $UserID
					UseDateTime = $LastActive
					yearmonth = $Year_Month
				} | ConvertTo-Json
				New-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "Usage" -DocumentBody $Usage -PartitionKey $Year_Month | Out-Null
			}
		}
	
		# Create collections for monthly stats if necessary
		try {
			Get-CosmosDbCollection -Context $cosmosDbContext -Id "Variables" | Out-Null
		} catch {
			try {
				New-CosmosDbCollection -Context $cosmosDbContext -Database $DB_Name -Id "Variables" -PartitionKey "variable" | Out-Null
			} catch {
				Write-Host "Table creation failed. Exiting..." -ForegroundColor Red
				exit
			}
			Write-Host "Created new table: Variables"
		}
		try {
			Get-CosmosDbCollection -Context $cosmosDbContext -Id "ComputerUsage" | Out-Null
		} catch {
			try {
				New-CosmosDbCollection -Context $cosmosDbContext -Database $DB_Name -Id "ComputerUsage" -PartitionKey "id" | Out-Null
			} catch {
				Write-Host "Table creation failed. Exiting..." -ForegroundColor Red
				exit
			}
			Write-Host "Created new table: ComputerUsage"
		}
		try {
			Get-CosmosDbCollection -Context $cosmosDbContext -Id "UserUsage" | Out-Null
		} catch {
			try {
				New-CosmosDbCollection -Context $cosmosDbContext -Database $DB_Name -Id "UserUsage" -PartitionKey "id" | Out-Null
			} catch {
				Write-Host "Table creation failed. Exiting..." -ForegroundColor Red
				exit
			}
			Write-Host "Created new table: UserUsage"
		}
	
		# Get the last time we updated the monthly stats
		$StatsLastUpdated = Get-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId 'Variables' -Query "SELECT * FROM Variables AS v WHERE v.variable = 'StatsLastUpdated'" -PartitionKey 'StatsLastUpdated'
	
		# If we last updated the monthly stats sometime before the end of last month, lets update them now
		# (that means last month hasn't been updated yet), and then update the LastUpdated variable
		$LastMonth = (Get-Date).AddMonths(-1)
		$LastDay = [DateTime]::DaysInMonth($LastMonth.Year, $LastMonth.Month)
		$CheckDate = [DateTime]::new($LastMonth.Year, $LastMonth.Month, $LastDay, 23, 59, 59)
		$Updated_ComputerUsage = @()
		$Updated_UserUsage = @()
		if (!$StatsLastUpdated -or ($StatsLastUpdated -and (Get-Date $StatsLastUpdated.LastUpdated) -lt $CheckDate) -or $ForceMonthlyUsageRollup) {
			# Get all usage documents
			$Year_Month = Get-Date (Get-Date).AddMonths(-1) -Format 'yyyy-MM'
			$Usage = Get-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "Usage" -Query "SELECT * FROM Usage AS u WHERE u.yearmonth = '$Year_Month'" -PartitionKey $Year_Month
	
			# Calculate monthly stats
			if ($Usage) {
				# Get all existing monthly stats
				$ComputerIDs = $Usage.ComputerID | Select-Object -Unique
				$Query = "SELECT * FROM ComputerUsage AS cu"
				$Existing_ComputerUsage = Get-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "ComputerUsage" -Query $Query -QueryEnableCrossPartition $true
				$Existing_ComputerUsage = $Existing_ComputerUsage | Where-Object { $_.Id -in $ComputerIDs }

				$UserIDs = $Usage.UserID | Select-Object -Unique
				$Query = "SELECT * FROM UserUsage AS uu"
				$Existing_UserUsage = Get-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "UserUsage" -Query $Query -QueryEnableCrossPartition $true
				$Existing_UserUsage = $Existing_UserUsage | Where-Object { $_.Id -in $UserIDs }
	
				# Group all usage stats from this past month by computer, user, and computer/user
				$Monthly_UsageByComputer = $Usage | Select-Object ComputerID, UserID, UseDateTime, @{Name="Day"; E={ Get-Date $_.UseDateTime -Format 'dd' }} | Group-Object -Property ComputerID
				$Monthly_UsageByUser = $Usage | Select-Object UserID, ComputerID, UseDateTime, @{Name="Day"; E={ Get-Date $_.UseDateTime -Format 'dd' }} | Group-Object -Property UserID
				$Monthly_UsageByComputerUser = $Usage | Select-Object ComputerID, UserID, UseDateTime, @{Name="Day"; E={ Get-Date $_.UseDateTime -Format 'dd' }} | Group-Object -Property ComputerID, UserID
				$Monthly_OutOfDays = ($Usage | Select-Object @{Name="Day"; E={ Get-Date $_.UseDateTime -Format 'dd' }} | Select-Object -ExpandProperty Day | Sort-Object -Unique | Measure-Object).Count
	
				# Build the monthly stats for each computer
				foreach ($ComputerID in $ComputerIDs) {
					$ExistingEntry = $Existing_ComputerUsage | Where-Object { $_.id -eq $ComputerID }
	
					if ($ExistingEntry) {
						$New_UsageHistory = $ExistingEntry | Select-Object id, DaysActive, LastActive, UsersUsedBy
					} else {
						$New_UsageHistory = @{
							id = $ComputerID
							DaysActive = @{
								Total = 0
								LastMonth = 0
								LastMonthPercent = 0
								History = @{}
								HistoryPercent = @{}
							}
							LastActive = $null
							UsersUsedBy = @()
						}
					}
	
					$MonthsUsage = $Monthly_UsageByComputer | Where-Object { $_.Name -eq $ComputerID }
					$DaysActive = ($MonthsUsage.Group | Select-Object Day | Select-Object -ExpandProperty Day | Sort-Object -Unique | Measure-Object).Count
					$DaysActivePercent = [Math]::Round($DaysActive / $Monthly_OutOfDays * 100)
	
					$New_UsageHistory.DaysActive.LastMonth = $DaysActive
					$New_UsageHistory.DaysActive.LastMonthPercent = $DaysActivePercent
					if ($New_UsageHistory.DaysActive.History -is 'PSCustomObject') {
						if (!$New_UsageHistory.DaysActive.History.$Year_Month) {
							$New_UsageHistory.DaysActive.History | Add-Member -NotePropertyName $Year_Month -NotePropertyValue 0
						}
						if (!$New_UsageHistory.DaysActive.HistoryPercent.$Year_Month) {
							$New_UsageHistory.DaysActive.HistoryPercent | Add-Member -NotePropertyName $Year_Month -NotePropertyValue 0
						}
						$New_UsageHistory.DaysActive.History.$Year_Month = $DaysActive
						$New_UsageHistory.DaysActive.HistoryPercent.$Year_Month = $DaysActivePercent
					} else {
						$New_UsageHistory.DaysActive.History[$Year_Month] = $DaysActive
						$New_UsageHistory.DaysActive.HistoryPercent[$Year_Month] = $DaysActivePercent
					}
					$LastActive = ($MonthsUsage.Group | Sort-Object { $_.UseDateTime -as [DateTime] } -Descending | Select-Object -First 1).UseDateTime
					if (!$New_UsageHistory.LastActive -or $LastActive -gt $New_UsageHistory.LastActive) {
						$New_UsageHistory.LastActive = $LastActive
					}
					if ($ExistingEntry) {
						$New_UsageHistory.DaysActive.Total = (($ExistingEntry.DaysActive.History.PSObject.Properties.Value | Measure-Object -Sum).Sum)
					} else {
						$New_UsageHistory.DaysActive.Total += $DaysActive
					}
					$New_UsageHistory.UsersUsedBy | Foreach-Object {
						$_.DaysActive.LastMonth = 0
						$_.DaysActive.LastMonthPercent = 0
					}
	
					# Update the UsersUsedBy array with usage stats for this computer on a per-user basis
					$MonthsUsageByUser = $Monthly_UsageByComputerUser | Where-Object { $_.Name -like "*$ComputerID*" }
					$Existing_UsersUsedBy = [Collections.Generic.List[Object]]$New_UsageHistory.UsersUsedBy
					foreach ($User in $MonthsUsageByUser) {
						$UserID = $User.Group[0].UserID
						$DaysActive = ($User.Group | Select-Object Day | Select-Object -ExpandProperty Day | Sort-Object -Unique | Measure-Object).Count
						$DaysActivePercent = [Math]::Round($DaysActive / $Monthly_OutOfDays * 100)
	
						$ExistingIndex = $Existing_UsersUsedBy.FindIndex( {$args[0].id -eq $UserID } )
						if ($ExistingIndex -ge 0) {
							$New_UsageHistory.UsersUsedBy[$ExistingIndex].DaysActive.LastMonth = $DaysActive
							$New_UsageHistory.UsersUsedBy[$ExistingIndex].DaysActive.LastMonthPercent = $DaysActivePercent
							if ($New_UsageHistory.UsersUsedBy[$ExistingIndex].DaysActive.History -is 'PSCustomObject') {
								if (!$New_UsageHistory.UsersUsedBy[$ExistingIndex].DaysActive.History.$Year_Month) {
									$New_UsageHistory.UsersUsedBy[$ExistingIndex].DaysActive.History | Add-Member -NotePropertyName $Year_Month -NotePropertyValue 0
								}
								if (!$New_UsageHistory.UsersUsedBy[$ExistingIndex].DaysActive.HistoryPercent.$Year_Month) {
									$New_UsageHistory.UsersUsedBy[$ExistingIndex].DaysActive.HistoryPercent | Add-Member -NotePropertyName $Year_Month -NotePropertyValue 0
								}
								$New_UsageHistory.UsersUsedBy[$ExistingIndex].DaysActive.History.$Year_Month = $DaysActive
								$New_UsageHistory.UsersUsedBy[$ExistingIndex].DaysActive.HistoryPercent.$Year_Month = $DaysActivePercent
							} else {
								$New_UsageHistory.UsersUsedBy[$ExistingIndex].DaysActive.History[$Year_Month] = $DaysActive
								$New_UsageHistory.UsersUsedBy[$ExistingIndex].DaysActive.HistoryPercent[$Year_Month] = $DaysActivePercent
							}
							$LastActive = ($MonthsUsageByUser.Group | Sort-Object { $_.UseDateTime -as [DateTime] } -Descending | Select-Object -First 1).UseDateTime
							if (!$New_UsageHistory.UsersUsedBy[$ExistingIndex].LastActive -or $LastActive -gt $New_UsageHistory.UsersUsedBy[$ExistingIndex].LastActive) {
								$New_UsageHistory.UsersUsedBy[$ExistingIndex].LastActive = $LastActive
							}
							if ($New_UsageHistory.UsersUsedBy[$ExistingIndex].DaysActive.History) {
								$New_UsageHistory.UsersUsedBy[$ExistingIndex].DaysActive.Total = (($New_UsageHistory.UsersUsedBy[$ExistingIndex].DaysActive.History.PSObject.Properties.Value | Measure-Object -Sum).Sum)
							} else {
								$New_UsageHistory.UsersUsedBy[$ExistingIndex].DaysActive.Total += $DaysActive
							}
						} else {
							$New_UsageHistory.UsersUsedBy += @{
								id = $UserID
								DaysActive = @{
									Total = $DaysActive
									LastMonth = $DaysActive
									LastMonthPercent = $DaysActivePercent
									History = @{
										$Year_Month = $DaysActive
									}
									HistoryPercent = @{
										$Year_Month = $DaysActivePercent
									}
								}
								LastActive = ($MonthsUsageByUser.Group | Sort-Object { $_.UseDateTime -as [DateTime] } -Descending | Select-Object -First 1).UseDateTime
							}
						}
					}
	
					$Updated_ComputerUsage += $New_UsageHistory
				}
	
				# Update the DB with the new monthly computer usage stats
				foreach ($Updated_Usage in $Updated_ComputerUsage) {
					if ($Updated_Usage.id -in $Existing_ComputerUsage.id) {
						# update
						Set-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "ComputerUsage" -Id $Updated_Usage.id -DocumentBody ($Updated_Usage | ConvertTo-Json -Depth 10) -PartitionKey $Updated_Usage.id | Out-Null
					} else {
						# new
						New-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "ComputerUsage" -DocumentBody ($Updated_Usage | ConvertTo-Json -Depth 10) -PartitionKey $Updated_Usage.id | Out-Null
					}
				}
	
				# Build the monthly stats for each user
				foreach ($UserID in $UserIDs) {
					$ExistingEntry = $Existing_UserUsage | Where-Object { $_.id -eq $UserID }
	
					if ($ExistingEntry) {
						$New_UsageHistory = $ExistingEntry | Select-Object id, DaysActive, LastActive, ComputersUsed
					} else {
						$New_UsageHistory = @{
							id = $UserID
							DaysActive = @{
								Total = 0
								LastMonth = 0
								LastMonthPercent = 0
								History = @{}
								HistoryPercent = @{}
							}
							LastActive = $null
							ComputersUsed = @()
						}
					}
	
					$MonthsUsage = $Monthly_UsageByUser | Where-Object { $_.Name -eq $UserID }
					$DaysActive = ($MonthsUsage.Group | Select-Object Day | Select-Object -ExpandProperty Day | Sort-Object -Unique | Measure-Object).Count
					$DaysActivePercent = [Math]::Round($DaysActive / $Monthly_OutOfDays * 100)
	
					$New_UsageHistory.DaysActive.LastMonth = $DaysActive
					$New_UsageHistory.DaysActive.LastMonthPercent = $DaysActivePercent
					if ($New_UsageHistory.DaysActive.History -is 'PSCustomObject') {
						if (!$New_UsageHistory.DaysActive.History.$Year_Month) {
							$New_UsageHistory.DaysActive.History | Add-Member -NotePropertyName $Year_Month -NotePropertyValue 0
						}
						if (!$New_UsageHistory.DaysActive.HistoryPercent.$Year_Month) {
							$New_UsageHistory.DaysActive.HistoryPercent | Add-Member -NotePropertyName $Year_Month -NotePropertyValue 0
						}
						$New_UsageHistory.DaysActive.History.$Year_Month = $DaysActive
						$New_UsageHistory.DaysActive.HistoryPercent.$Year_Month = $DaysActivePercent
					} else {
						$New_UsageHistory.DaysActive.History[$Year_Month] = $DaysActive
						$New_UsageHistory.DaysActive.HistoryPercent[$Year_Month] = $DaysActivePercent
					}
					$LastActive = ($MonthsUsage.Group | Sort-Object { $_.UseDateTime -as [DateTime] } -Descending | Select-Object -First 1).UseDateTime
					if (!$New_UsageHistory.LastActive -or $LastActive -gt $New_UsageHistory.LastActive) {
						$New_UsageHistory.LastActive = $LastActive
					}
					if ($ExistingEntry) {
						$New_UsageHistory.DaysActive.Total = (($ExistingEntry.DaysActive.History.PSObject.Properties.Value | Measure-Object -Sum).Sum)
					} else {
						$New_UsageHistory.DaysActive.Total += $DaysActive
					}
					$New_UsageHistory.ComputersUsed | Foreach-Object {
						$_.DaysActive.LastMonth = 0
						$_.DaysActive.LastMonthPercent = 0
					}
	
					# Update the ComputersUsed array with usage stats for this user on a per-computer basis
					$MonthsUsageByComputer = $Monthly_UsageByComputerUser | Where-Object { $_.Name -like "*$UserID*" }
					$Existing_ComputersUsed = [Collections.Generic.List[Object]]$New_UsageHistory.ComputersUsed
					foreach ($Computer in $MonthsUsageByComputer) {
						$ComputerID = $Computer.Group[0].ComputerID
						$DaysActive = ($Computer.Group | Select-Object Day | Select-Object -ExpandProperty Day | Sort-Object -Unique | Measure-Object).Count
						$DaysActivePercent = [Math]::Round($DaysActive / $Monthly_OutOfDays * 100)
	
						$ExistingIndex = $Existing_ComputersUsed.FindIndex( {$args[0].id -eq $ComputerID } )
						if ($ExistingIndex -ge 0) {
							$New_UsageHistory.ComputersUsed[$ExistingIndex].DaysActive.LastMonth = $DaysActive
							$New_UsageHistory.ComputersUsed[$ExistingIndex].DaysActive.LastMonthPercent = $DaysActivePercent
							if ($New_UsageHistory.ComputersUsed[$ExistingIndex].DaysActive.History -is 'PSCustomObject') {
								if (!$New_UsageHistory.ComputersUsed[$ExistingIndex].DaysActive.History.$Year_Month) {
									$New_UsageHistory.ComputersUsed[$ExistingIndex].DaysActive.History | Add-Member -NotePropertyName $Year_Month -NotePropertyValue 0
								}
								if (!$New_UsageHistory.ComputersUsed[$ExistingIndex].DaysActive.HistoryPercent.$Year_Month) {
									$New_UsageHistory.ComputersUsed[$ExistingIndex].DaysActive.HistoryPercent | Add-Member -NotePropertyName $Year_Month -NotePropertyValue 0
								}
								$New_UsageHistory.ComputersUsed[$ExistingIndex].DaysActive.History.$Year_Month = $DaysActive
								$New_UsageHistory.ComputersUsed[$ExistingIndex].DaysActive.HistoryPercent.$Year_Month = $DaysActivePercent
							} else {
								$New_UsageHistory.ComputersUsed[$ExistingIndex].DaysActive.History[$Year_Month] = $DaysActive
								$New_UsageHistory.ComputersUsed[$ExistingIndex].DaysActive.HistoryPercent[$Year_Month] = $DaysActivePercent
							}
							$LastActive = ($MonthsUsageByComputer.Group | Sort-Object { $_.UseDateTime -as [DateTime] } -Descending | Select-Object -First 1).UseDateTime
							if (!$New_UsageHistory.ComputersUsed[$ExistingIndex].LastActive -or $LastActive -gt $New_UsageHistory.ComputersUsed[$ExistingIndex].LastActive) {
								$New_UsageHistory.ComputersUsed[$ExistingIndex].LastActive = $LastActive
							}
							if ($New_UsageHistory.ComputersUsed[$ExistingIndex].DaysActive.History) {
								$New_UsageHistory.ComputersUsed[$ExistingIndex].DaysActive.Total = (($New_UsageHistory.ComputersUsed[$ExistingIndex].DaysActive.History.PSObject.Properties.Value | Measure-Object -Sum).Sum)
							} else {
								$New_UsageHistory.ComputersUsed[$ExistingIndex].DaysActive.Total += $DaysActive
							}
						} else {
							$New_UsageHistory.ComputersUsed += @{
								id = $ComputerID
								DaysActive = @{
									Total = $DaysActive
									LastMonth = $DaysActive
									LastMonthPercent = $DaysActivePercent
									History = @{
										$Year_Month = $DaysActive
									}
									HistoryPercent = @{
										$Year_Month = $DaysActivePercent
									}
								}
								LastActive = ($MonthsUsageByComputer.Group | Sort-Object { $_.UseDateTime -as [DateTime] } -Descending | Select-Object -First 1).UseDateTime
							}
						}
					}
	
					$Updated_UserUsage += $New_UsageHistory
				}
	
				# Update the DB with the new monthly user usage stats
				foreach ($Updated_Usage in $Updated_UserUsage) {
					if ($Updated_Usage.id -in $Existing_UserUsage.id) {
						# update
						Set-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "UserUsage" -Id $Updated_Usage.id -DocumentBody ($Updated_Usage | ConvertTo-Json -Depth 10) -PartitionKey $Updated_Usage.id | Out-Null
					} else {
						# new
						New-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "UserUsage" -DocumentBody ($Updated_Usage | ConvertTo-Json -Depth 10) -PartitionKey $Updated_Usage.id | Out-Null
					}
				}
	
				# Update the LastUpdated variable
				$StatsUpdated = @{
					variable = 'StatsLastUpdated'
					LastUpdated = Get-Date (Get-Date).ToUniversalTime() -UFormat '+%Y-%m-%dT%H:%M:%S.000Z'
				}
				if ($StatsLastUpdated) {
					# update
					$StatsUpdated.id = $StatsLastUpdated.id
					Set-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "Variables" -Id $StatsLastUpdated.id -DocumentBody ($StatsUpdated | ConvertTo-Json) -PartitionKey 'StatsLastUpdated' | Out-Null
				} else {
					# new
					$StatsUpdated.id = $([Guid]::NewGuid().ToString())
					New-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "Variables" -DocumentBody ($StatsUpdated | ConvertTo-Json) -PartitionKey 'StatsLastUpdated' | Out-Null
				}

				$MonthlyStatsUpdated = $true
			}
		}

		#####
		## Update the documented users for each computer
		#####

		# Get the last time we updated the users
		$ComputerUsersLastUpdated = Get-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId 'Variables' -Query "SELECT * FROM Variables AS v WHERE v.variable = 'ComputerUsersLastUpdated'" -PartitionKey 'ComputerUsersLastUpdated'

		# Update the users every 7 days or after the monthly stats have just been updated and then update the LastUpdated variable
		# If we are within the first 7 days of the month, don't check the last weeks usage (as we are only grabbing usage from the current month for that purpose)
		$CurrentDate = Get-Date 
		$SevenDaysAgo = ($CurrentDate).AddDays(-7) 
		if ($ComputerUsersLastUpdated -and $ComputerUsersLastUpdated.LastUpdated) {
			$LastUpdated = (Get-Date $ComputerUsersLastUpdated.LastUpdated)
		} else {
			$LastUpdated = $null
		}

		if (!$LastUpdated -or $MonthlyStatsUpdated -or ($LastUpdated -and $LastUpdated -lt $SevenDaysAgo -and $CurrentDate.Day -gt 7)) {
			$UpdateWeekly = $false
			if ($CurrentDate.Day -gt 7) {
				$UpdateWeekly = $true
				$Year_Month = Get-Date -Format 'yyyy-MM'
				$SevenDaysAgoUTC = Get-Date ($SevenDaysAgo).ToUniversalTime() -UFormat '+%Y-%m-%dT00:00:00.000Z'
				$LastWeeksUsage = Get-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "Usage" -Query "SELECT * FROM Usage AS u WHERE u.UseDateTime >= '$($SevenDaysAgoUTC)' ORDER BY u.UseDateTime DESC" -PartitionKey $Year_Month
			}

			# Get existing device users from the logs (we have to query related items per-device so this saves us a LOT of api calls)
			$ExistingDeviceUsers = $false
			if ($DeviceUsersLocation) {
				$DeviceUsersPath = "$($DeviceUsersLocation)\$($Company_Acronym)_device_users.json"
				if (Test-Path $DeviceUsersPath) {
					$ExistingDeviceUsers = Get-Content -Path $DeviceUsersPath -Raw | ConvertFrom-Json
				}
			}

			# Update ITG_ID's for existing users (this mainly matters for customers that don't use the User Device Audit and local accounts)
			if (($ExistingUsers | Where-Object { !$_.ITG_ID } | Measure-Object).Count -gt 0) {
				$Now_UTC = Get-Date (Get-Date).ToUniversalTime() -UFormat '+%Y-%m-%dT%H:%M:%S.000Z'
				$ITG_Contacts = Get-ITGlueContacts -organization_id $ITG_ID -page_size 10000
				if ($ITG_Contacts.data) {
					$ITG_Contacts = $ITG_Contacts.data
				}

				$PossibleUsernames = @{}
				foreach ($ITGContact in $ITG_Contacts) {
					foreach ($Format in @($UsernameFormat)) {
						$PossibleUsername = $Format.replace("[first]", $ITGContact.attributes.'first-name').replace("[last]", $ITGContact.attributes.'last-name').replace("[firstInitial]", $ITGContact.attributes.'first-name'[0]).replace("[lastInitial]", $ITGContact.attributes.'last-name'[0])
						if (!$PossibleUsernames[$PossibleUsername]) {
							$PossibleUsernames[$PossibleUsername] = @()
						}
						$PossibleUsernames[$PossibleUsername] += $ITGContact.id
					}
				}

				for ($j = 0; $j -lt $ExistingUsers.Count; $j++) {
					$DBUser = $ExistingUsers[$j]

					if (!$DBUser.ITG_ID) {
						if (!$DBUser.Username) {
							continue
						}
						$UpdateDB = $false

						# Check first for a local username match in the ITG contact notes
						$ITGContact = $ITG_Contacts | Where-Object { $_.attributes.notes -match "(^|\s|>)(AD )?Username: ($([Regex]::Escape($DBUser.Username.Trim())))($|\s|<)" }
						if ($ITGContact) {
							$ExistingUsers[$j].ITG_ID = ($ITGContact | Select-Object -First 1).Id
							if (($ITGContact | Measure-Object).Count -eq 1) {
								$UpdateDB = $true
							}
						}

						# Check based on default username format
						if ($PossibleUsernames[$DBUser.Username] -and !$ExistingUsers[$j].ITG_ID) {
							$ExistingUsers[$j].ITG_ID = $PossibleUsernames[$DBUser.Username][0]
							if (($PossibleUsernames[$DBUser.Username] | Measure-Object).Count -eq 1) {
								$UpdateDB = $true
							}
						}

						if ($UpdateDB -and $ExistingUsers[$j].ITG_ID) {
							# Update database
							$UpdatedUser = $DBUser | Select-Object Id, Domain, DomainOrLocal, Username, LastUpdated, type, O365Email, ITG_ID, ADUsername
							$UpdatedUser.ITG_ID = $ExistingUsers[$j].ITG_ID
							$UpdatedUser.LastUpdated = $Now_UTC
							Set-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "Users" -Id $DBUser.Id -DocumentBody ($UpdatedUser | ConvertTo-Json) -PartitionKey 'user' | Out-Null
						}
					}
				}
			}

			# Update our data on all the users and computers (we need this to match id's to ITG)
			$Query = "SELECT * FROM Computers c"
			$ExistingComputers = Get-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "Computers" -Query $Query -PartitionKey 'computer'
			$Query = "SELECT * FROM Users u"
			$ExistingUsers = Get-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "Users" -Query $Query -PartitionKey 'user'

			if (!$LastUpdated -and (!$MonthlyStatsUpdated -or !$Updated_ComputerUsage -or !$Updated_UserUsage)) {
				# If we have not updated the users before, and we didn't just update the monthly stats, grab the most recent monthly stats
				# Otherwise, we'll only update based on these at the end of the month just after updating the monthly stats
				$Year_Month = Get-Date (Get-Date).AddMonths(-1) -Format 'yyyy-MM'
				$Usage = Get-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "Usage" -Query "SELECT * FROM Usage AS u WHERE u.yearmonth = '$Year_Month'" -PartitionKey $Year_Month
				if ($Usage) {
					# Get all existing monthly stats
					$ComputerIDs = $Usage.ComputerID | Select-Object -Unique
					$Query = "SELECT * FROM ComputerUsage AS cu WHERE cu.id IN ('$($ComputerIDs -join "', '")')"
					$ComputerUsage = Get-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "ComputerUsage" -Query $Query -QueryEnableCrossPartition $true
		
					$UserIDs = $Usage.UserID | Select-Object -Unique
					$Query = "SELECT * FROM UserUsage AS uu WHERE uu.id IN ('$($UserIDs -join "', '")')"
					$UserUsage = Get-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "UserUsage" -Query $Query -QueryEnableCrossPartition $true
				}
			} elseif ($Updated_ComputerUsage -and $Updated_UserUsage) {
				$ComputerUsage = $Updated_ComputerUsage
				$UserUsage = $Updated_UserUsage
			} else {
				$ComputerUsage = $false
				$UserUsage = $false
			}

			$DeviceUsers = @()
			$AssignedUsers = @()
			$FullUpdate = $false

			# Do a FULL update (based on last months monthly stats)
			if ($ComputerUsage -and $UserUsage) {
				$FullUpdate = $true
				$Year_Month = Get-Date (Get-Date).AddMonths(-1) -Format 'yyyy-MM'

				# Go through each device and find the primary user and any secondary users who've used the device > 25% of the time
				foreach ($Device in $ITG_Devices) {
					if ($Device.attributes.archived) {
						continue
					}
					if ($Device.attributes.'configuration-type-kind' -ne 'workstation' -and $Device.attributes.'configuration-type-kind' -ne 'laptop') {
						continue
					}

					$ExistingComputer = $ExistingComputers | Where-Object { $_.ITG_ID -like "*|$($Device.id)|*" }
					if (!$ExistingComputer) {
						$DeviceUsers += [pscustomobject]@{
							ITG_Computer = $Device.id
							PrimaryUser = $null
							SecondaryUsers = @()
							RecentUsers = @()
						}
						continue
					}

					$UsageStats = $ComputerUsage | Where-Object { $_.id -eq $ExistingComputer.id }
					$UsersUsedBy = $UsageStats.UsersUsedBy | Where-Object { $_.DaysActive.History.$Year_Month } | Sort-Object -Property {$_.DaysActive.LastMonthPercent} -Descending
					$PrimaryUser = $UsersUsedBy | Select-Object -First 1
					$RemainingUsers = $UsersUsedBy | Select-Object -Skip 1
					$SecondaryUsers = @($RemainingUsers | Where-Object { $_.DaysActive.LastMonthPercent -ge 25 -and $_.DaysActive.LastMonth -ge 5 })

					$PrimaryUser_ITG = $null
					$SecondaryUsers_ITG = @()

					if ($PrimaryUser) {
						$AssignedUsers += $PrimaryUser.id
						$DBUser = $ExistingUsers | Where-Object { $_.id -eq $PrimaryUser.id }
						if ($DBUser -and $DBUser.ITG_ID) {
							$PrimaryUser_ITG = $DBUser.ITG_ID
						}
					}
					if ($SecondaryUsers) {
						foreach ($User in $SecondaryUsers) {
							$AssignedUsers += $User.id
							$DBUser = $ExistingUsers | Where-Object { $_.id -eq $User.id }
							if ($DBUser -and $DBUser.ITG_ID) {
								$SecondaryUsers_ITG += $DBUser.ITG_ID
							}
						}
					}

					$DeviceUsers += [pscustomobject]@{
						ITG_Computer = $Device.id
						PrimaryUser = $PrimaryUser_ITG
						SecondaryUsers = $SecondaryUsers_ITG
						RecentUsers = @()
					}
				}
				
				# Go through any users who have not been assigned to a computer, and assign them to whichever computer they have used the most in the past month
				foreach ($UserUse in $UserUsage) {
					if ($UserUse.id -in $AssignedUsers) {
						continue
					}
					if (!$UserUse.DaysActive.History.$Year_Month) {
						continue
					}

					$DBUser = $ExistingUsers | Where-Object { $_.id -eq $UserUse.id }
					if (!$DBUser.ITG_ID) {
						continue
					}

					$ComputersUsed = $UserUse.ComputersUsed | Where-Object { $_.DaysActive.History.$Year_Month } | Sort-Object -Property {$_.DaysActive.LastMonthPercent} -Descending
					$PrimaryComputer = $ComputersUsed | Select-Object -First 1

					$PrimaryComputer_ITG = $null
					if ($PrimaryComputer) {
						$AssignedUsers += $UserUse.id
						$DBComputer = $ExistingComputers | Where-Object { $_.id -eq $PrimaryComputer.id }
						if ($DBComputer -and $DBComputer.ITG_ID) {
							$Computer_ITG_IDs = @($DBComputer.ITG_ID.Split("|") | Where-Object { $_ })
							foreach ($ID in $Computer_ITG_IDs) {
								$DeviceUser = $DeviceUsers | Where-Object { $_.ITG_Computer -eq $ID }
								
								if ($DeviceUser) {
									# update
									if ($DeviceUser.PrimaryUser) {
										$DeviceUser.SecondaryUsers += $DBUser.ITG_ID
									} else {
										$DeviceUser.PrimaryUser = $DBUser.ITG_ID
									}
								} else {
									# new
									$DeviceUsers += [pscustomobject]@{
										ITG_Computer = $ID
										PrimaryUser = $DBUser.ITG_ID
										SecondaryUsers = @()
										RecentUsers = @()
									}
								}
							}
						}
					}
				}
			}

			# Do a WEEKLY update (based on usage from the last 7 days)
			# We will only add any heavy users from the last week, we won't remove any users
			if ($UpdateWeekly) {
				$ComputerIDs = $LastWeeksUsage.ComputerID | Select-Object -Unique
				$Monthly_UsageByComputerUser = $LastWeeksUsage | Select-Object ComputerID, UserID, UseDateTime, @{Name="Day"; E={ Get-Date $_.UseDateTime -Format 'dd' }} | Group-Object -Property ComputerID, UserID
				$Monthly_OutOfDays = ($LastWeeksUsage | Select-Object @{Name="Day"; E={ Get-Date $_.UseDateTime -Format 'dd' }} | Select-Object -ExpandProperty Day | Sort-Object -Unique | Measure-Object).Count

				foreach ($ComputerID in $ComputerIDs) {
					$MonthsUsageByUser = $Monthly_UsageByComputerUser | Where-Object { $_.Name -like "*$ComputerID*" }
					$DBComputer = $ExistingComputers | Where-Object { $_.id -eq $ComputerID }

					if ($DBComputer -and $DBComputer.ITG_ID) {
						$Computer_ITG_IDs = @($DBComputer.ITG_ID.Split("|") | Where-Object { $_ })
					} else {
						continue
					}

					foreach ($User in $MonthsUsageByUser) {
						$UserID = $User.Group[0].UserID
						$DBUser = $ExistingUsers | Where-Object { $_.id -eq $UserID }
						$DaysActive = ($User.Group | Select-Object Day | Select-Object -ExpandProperty Day | Sort-Object -Unique | Measure-Object).Count
						$DaysActivePercent = [Math]::Round($DaysActive / $Monthly_OutOfDays * 100)

						if ($DBUser.ITG_ID -and $DaysActivePercent -ge 25) {
							# Usage in last week is high, add to computer if necessary
							foreach ($Device_ITG_ID in $Computer_ITG_IDs) {
								$DeviceUser = $DeviceUsers | Where-Object { $_.ITG_Computer -eq $Device_ITG_ID }

								if ($DeviceUser) {
									if ($DeviceUser.PrimaryUser -eq $DBUser.ITG_ID -or $DeviceUser.SecondaryUsers -contains $DBUser.ITG_ID -or $DeviceUser.RecentUsers -contains $DBUser.ITG_ID) {
										# already assigned to that computer
										continue
									} else {
										# update
										$DeviceUser.RecentUsers += $DBUser.ITG_ID
									}
								} else {
									# new
									$DeviceUsers += [pscustomobject]@{
										ITG_Computer = $Device_ITG_ID
										PrimaryUser = $null
										SecondaryUsers = @()
										RecentUsers = @($DBUser.ITG_ID)
									}
								}
								$DeviceUsersUpdateRan = $true
							}
						}
					}
				}
			}

			# All devices / users mapped, update IT Glue (if it's a full update, delete existing mappings as well)
			if ($DeviceUsers) {
				if (!$ITG_Contacts) {
					$ITG_Contacts = Get-ITGlueContacts -organization_id $ITG_ID -page_size 10000
					if ($ITG_Contacts.data) {
						$ITG_Contacts = $ITG_Contacts.data
					}
				}
				$ITGLocations = Get-ITGlueLocations -org_id $ITG_ID
				if ($ITGLocations.data) {
					$ITGLocations = $ITGLocations.data
				}
				$AutotaskContacts = Get-AutotaskAPIResource -Resource Contacts -SimpleSearch "companyID eq $Autotask_ID"
				$AutotaskContacts = $AutotaskContacts | Where-Object { $_.isActive }

				foreach ($Device in $DeviceUsers) {
					$ITG_Device = $ITG_DevicesHash[$Device.ITG_Computer]
					$MatchedDevice = $MatchedDevices | Where-Object { $_.itg_matches -contains $Device.ITG_Computer }
					$Autotask_Device = $false
					if ($MatchedDevice.autotask_matches) {
						$Autotask_Device = @()
						foreach ($DeviceID in $MatchedDevice.autotask_matches) {
							$Autotask_Device += $Autotask_DevicesHash[$DeviceID]
						}
					}
					$Existing_RelatedItems = $false
					$Existing_DeviceUsersLogged = $ExistingDeviceUsers | Where-Object { $_.ITG_Computer -eq $Device.ITG_Computer }

					# If the contact is synced with autotask then we cannot update ITG directly, we need to find the autotask contact and update autotask instead
					if ($Device.PrimaryUser -and $ITG_Contacts) {
						$ITG_Contact = $ITG_Contacts | Where-Object { $_.id -eq $Device.PrimaryUser }
						if ($ITG_Contact -and $ITG_Contact.attributes.'psa-integration' -eq 'enabled') {
							$PrimaryITGEmail = $ITG_Contact.attributes.'contact-emails' | Where-Object { $_.primary -eq "True" }
							$Autotask_Contact = $AutotaskContacts | Where-Object { $_.firstName -eq $ITG_Contact.attributes.'first-name' -and $_.lastName -eq $ITG_Contact.attributes.'last-name' -and $_.emailAddress -eq $PrimaryITGEmail.value }

							if (($Autotask_Contact | Measure-Object).Count -gt 1) {
								$Autotask_Contact = $Autotask_Contact | Where-Object { $_.title.Trim() -eq ($ITG_Contact.attributes.title | Out-String).Trim() -and ((($_.mobilePhone -replace '\D', '') -in $ITG_Contact.attributes.'contact-phones'.value -and ($_.phone -replace '\D', '') -in $ITG_Contact.attributes.'contact-phones'.value) -or !$ITG_Contact.attributes.'contact-phones'.value ) }
							}

							if (($Autotask_Contact | Measure-Object).Count -gt 1 -and $ITGLocations -and $ITG_Contact.attributes.'location-id') {
								$Location = $ITGLocations | Where-Object { $_.id -eq $ITG_Contact.attributes.'location-id' }
								$Autotask_Contact = $Autotask_Contact | Where-Object { $_.city -like $Location.attributes.city -and $_.state -like $Location.attributes.'region-name' -and ($_.zipCode -replace '\W', '') -like ($Location.attributes.'postal-code' -replace '\W', '') }
								if (($Autotask_Contact | Measure-Object).Count -gt 1) {
									$Autotask_Contact = $Autotask_Contact | Where-Object { $_.addressLine -like $Location.attributes.'address-1' }
								}
							}

							if (($Autotask_Contact | Measure-Object).Count -gt 1) {
								$Autotask_Contact = $Autotask_Contact[0]
							}
						}
					}

					$PSAIntegration = $false
					if ($ITG_Device -and $ITG_Device.attributes.'psa-integration' -and $ITG_Device.attributes.'psa-integration' -ne 'disabled') {
						$PSAIntegration = $true
					}

					if ($FullUpdate) {
						$ITGDetails = Get-ITGlueConfigurations -id $Device.ITG_Computer -include 'related_items'
						if ($ITGDetails.included) {
							$Existing_RelatedItems = $ITGDetails.included
						}

						# Remove any existing related items that don't match the new data
						if ($Existing_RelatedItems) {
							$AutoAssigned = $Existing_RelatedItems | Where-Object { $_.attributes.'asset-type' -eq 'contact' -and $_.attributes.notes -like "*(Auto-Assigned)" }
							$RemoveRelated = @()
							foreach ($RelatedItem in $AutoAssigned) {
								if ($RelatedItem.attributes.notes -like "Primary User*" -and $RelatedItem.attributes.'resource-id' -ne $Device.PrimaryUser) {
									$RemoveRelated += @{
										'type' = 'related_items'
										'attributes' = @{
											'id' = $RelatedItem.id
										}
									}
									$Existing_RelatedItems = $Existing_RelatedItems | Where-Object { $_.id -ne $RelatedItem.id }
								}
								if ($RelatedItem.attributes.notes -like "Secondary User*" -and $RelatedItem.attributes.'resource-id' -notin $Device.SecondaryUsers) {
									$RemoveRelated += @{
										'type' = 'related_items'
										'attributes' = @{
											'id' = $RelatedItem.id
										}
									}
									$Existing_RelatedItems = $Existing_RelatedItems | Where-Object { $_.id -ne $RelatedItem.id }
								}
								if ($RelatedItem.attributes.notes -like "Recently Seen*" -and $RelatedItem.attributes.'resource-id' -notin $Device.RecentUsers) {
									$RemoveRelated += @{
										'type' = 'related_items'
										'attributes' = @{
											'id' = $RelatedItem.id
										}
									}
									$Existing_RelatedItems = $Existing_RelatedItems | Where-Object { $_.id -ne $RelatedItem.id }
								}
							}

							if ($RemoveRelated) {
								Remove-ITGlueRelatedItems -resource_type 'configurations' -resource_id $Device.ITG_Computer -data $RemoveRelated
							}
						}

						# If no primary contact anymore, remove from configuration
						if (!$Device.PrimaryUser -and $ITG_Device.attributes.'contact-id') {
							if (!$PSAIntegration) {
								$UpdatedConfig = @{
									'type' = 'configurations'
									'attributes' = @{
										'contact-id' = ""
										'contact-name' = ""
									}
								}
								Set-ITGlueConfigurations -id $Device.ITG_Computer -data $UpdatedConfig
							}
							if ($Autotask_Contact -and $Autotask_Device) {

								foreach ($AutoDevice in $Autotask_Device) {
									$ConfigurationUpdate = 
									[PSCustomObject]@{
										contactID = ""
									}

									Set-AutotaskAPIResource -Resource ConfigurationItems -ID $AutoDevice.id -body $ConfigurationUpdate
								}
							}
						}
					}

					# Set primary contact
					if ($Device.PrimaryUser -and (!$ITG_Device -or $ITG_Device.attributes.'contact-id' -ne $Device.PrimaryUser)) {
						if (!$PSAIntegration) {
							$UpdatedConfig = @{
								'type' = 'configurations'
								'attributes' = @{
									'contact-id' = $Device.PrimaryUser
								}
							}
							Set-ITGlueConfigurations -id $Device.ITG_Computer -data $UpdatedConfig
						}
						if ($Autotask_Contact -and $Autotask_Device) {
							foreach ($AutoDevice in $Autotask_Device) {
								$ConfigurationUpdate = 
								[PSCustomObject]@{
									contactID = $Autotask_Contact.id
								}

								Set-AutotaskAPIResource -Resource ConfigurationItems -ID $AutoDevice.id -body $ConfigurationUpdate
							}
						}
					}

					# Add new related items, checking first if they already exist in $Existing_RelatedItems
					$RelatedItems = @()
					if ($Device.PrimaryUser) {
						if (!$Existing_RelatedItems -or ($Existing_RelatedItems | Where-Object { $_.attributes.'resource-id' -eq $Device.PrimaryUser -and $_.attributes.notes -like "*(Auto-Assigned)" } | Measure-Object).Count -eq 0) {
							$RelatedItems += @{
								type = 'related_items'
								attributes = @{
									destination_id = $Device.PrimaryUser
									destination_type = "Contact"
									notes = "Primary User (Auto-Assigned)"
								}
							}
						}
					}

					if ($Device.SecondaryUsers) {
						foreach ($User in $Device.SecondaryUsers) {
							if (!$Existing_RelatedItems -or ($Existing_RelatedItems | Where-Object { $_.attributes.'resource-id' -eq $User -and $_.attributes.notes -like "*(Auto-Assigned)" } | Measure-Object).Count -eq 0) {
								$RelatedItems += @{
									type = 'related_items'
									attributes = @{
										destination_id = $User
										destination_type = "Contact"
										notes = "Secondary User (Auto-Assigned)"
									}
								}
							}
						}
					}

					if ($Device.RecentUsers) {
						foreach ($User in $Device.RecentUsers) {
							if ((!$Existing_RelatedItems -or ($Existing_RelatedItems | Where-Object { $_.attributes.'resource-id' -eq $User -and $_.attributes.notes -like "*(Auto-Assigned)" } | Measure-Object).Count -eq 0) -and (!$Existing_DeviceUsersLogged -or ($Existing_DeviceUsersLogged.PrimaryUser -ne $User -and $Existing_DeviceUsersLogged.RecentUsers -notcontains $User -and $Existing_DeviceUsersLogged.SecondaryUsers -notcontains $User))) {
								$RelatedItems += @{
									type = 'related_items'
									attributes = @{
										destination_id = $User
										destination_type = "Contact"
										notes = "Recently Seen User (Auto-Assigned)"
									}
								}
							}
						}
					}

					if ($RelatedItems) {
						New-ITGlueRelatedItems -resource_type configurations -resource_id $Device.ITG_Computer -data $RelatedItems
					}
				}

				# Update "Computer Users Last Updated" variable to current datetime
				$StatsUpdated = @{
					variable = 'ComputerUsersLastUpdated'
					LastUpdated = Get-Date (Get-Date).ToUniversalTime() -UFormat '+%Y-%m-%dT%H:%M:%S.000Z'
				}
				if ($ComputerUsersLastUpdated) {
					# update
					$StatsUpdated.id = $ComputerUsersLastUpdated.id
					Set-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "Variables" -Id $ComputerUsersLastUpdated.id -DocumentBody ($StatsUpdated | ConvertTo-Json) -PartitionKey 'ComputerUsersLastUpdated' | Out-Null
				} else {
					# new
					$StatsUpdated.id = $([Guid]::NewGuid().ToString())
					New-CosmosDbDocument -Context $cosmosDbContext -Database $DB_Name -CollectionId "Variables" -DocumentBody ($StatsUpdated | ConvertTo-Json) -PartitionKey 'ComputerUsersLastUpdated' | Out-Null
				}
				$LastUpdated = Get-Date
				$DeviceUsersUpdateRan = $true
			}

			# Export an updated json file of device users
			if ($DeviceUsers -and $DeviceUsersPath) {
				if ($ExistingDeviceUsers -and !$FullUpdate) {
					$DeviceUsersExport = $ExistingDeviceUsers
					foreach ($Device in $DeviceUsers) {
						$DeviceUserExport = $DeviceUsersExport | Where-Object { $_.ITG_Computer -eq $Device.ITG_Computer }
						if (!$DeviceUserExport) {
							$DeviceUsersExport += $Device
						} else {
							if ($Device.PrimaryUser -and $Device.PrimaryUser -ne $DeviceUserExport.PrimaryUser) {
								$DeviceUserExport.PrimaryUser = $Device.PrimaryUser
							}
							if ($Device.SecondaryUsers) {
								foreach ($User in $Device.SecondaryUsers) {
									if ($User -notin $DeviceUserExport.SecondaryUsers) {
										$DeviceUserExport.SecondaryUsers += $User
									}
								}
							}
							if ($Device.RecentUsers) {
								foreach ($User in $Device.RecentUsers) {
									if ($User -notin $DeviceUserExport.RecentUsers -and $User -notin $DeviceUserExport.SecondaryUsers -and $User -ne $DeviceUserExport.PrimaryUser) {
										$DeviceUserExport.RecentUsers += $User
									}
								}
							}
						}
					}
				} else {
					$DeviceUsersExport = $DeviceUsers
				}
				$DeviceUsersExport | ConvertTo-Json | Out-File -FilePath $DeviceUsersPath
			}
		}

	
		Write-Host "Usage Stats Saved!"
		Write-Host "===================="
	}

	# Save Sophos Tamper Protection keys (once a week)
	$SophosTamperKeysJson = $SophosTamperKeys = @()
	if ($Sophos_Company -and $Sophos_Devices -and $SophosTenantID -and $TenantApiHost) {
		$SophosTamperKeysJsonPath = "$($SophosTamperKeysLocation)\$($Company_Acronym)_keys.json"
		if ($SophosTamperKeysLocation -and (Test-Path -Path $SophosTamperKeysJsonPath)) {
			$SophosTamperKeysJson = Get-Content -Path $SophosTamperKeysJsonPath -Raw | ConvertFrom-Json
		}
		$AllowTamperProtectionDisabled = $false
		if ($Allow_Tamper_Protection_Disabled.count -gt 0 -and $Allow_Tamper_Protection_Disabled[0] -eq "*") {
			$AllowTamperProtectionDisabled = $true
		}

		if (!$SophosTamperKeysJson -or (Get-Date $SophosTamperKeysJson.lastUpdated.DateTime).AddDays(7) -lt (Get-Date)) {
			$SophosTamperKeys = [System.Collections.ArrayList]@()

			$SophosDeviceCount = ($Sophos_Devices | Measure-Object).Count
			$i = 0
			$SophosFailedSleepTime = 0
			$MaxFailTime = 180000 # 3 minutes
			$FailsInARow = 0
			:foreachSophosDevice foreach ($Device in $Sophos_Devices) {
				$i++
				[int]$PercentComplete = ($i / $SophosDeviceCount * 100)
				Write-Progress -Activity "Retrieving Sophos Tamper Protection Keys" -PercentComplete $PercentComplete -Status ("Working - " + $PercentComplete + "%")

				# Refresh token if it has expired
				if ($SophosToken.expiry -lt (Get-Date)) {
					try {
						$SophosToken = Invoke-RestMethod -Method POST -Body $SophosGetTokenBody -ContentType "application/x-www-form-urlencoded" -uri "https://id.sophos.com/api/v2/oauth2/token"
						$SophosJWT = $SophosToken.access_token
						$SophosToken | Add-Member -NotePropertyName expiry -NotePropertyValue $null
						$SophosToken.expiry = (Get-Date).AddSeconds($SophosToken.expires_in)
					} catch {
						$SophosToken = $false
					}
				}

				if (!$SophosToken) {
					$FailsInARow++
					if ($FailsInARow -gt 10) {
						break
					}
					continue;
				}
				$FailsInARow = 0

				$SophosHeader = @{
					Authorization = "Bearer $SophosJWT"
					"X-Tenant-ID" = $SophosTenantID
				}

				$SophosTamperInfo = $false
				$attempt = 0
				while (!$SophosTamperInfo -and $SophosFailedSleepTime -lt $MaxFailTime) {
					try {
						$SophosTamperInfo = Invoke-RestMethod -Method GET -Headers $SophosHeader -uri ($TenantApiHost + "/endpoint/v1/endpoints/$($Device.id)/tamper-protection")
					} catch {
						if ($_.Exception.Response.StatusCode.value__ -eq 429 -or $_.Exception.Response.StatusCode.value__ -match "5\d{2}") {
							Write-Host "Retry Sophos API call."
							Write-Host "StatusCode:" $_.Exception.Response.StatusCode.value__ 
							Write-Host "StatusDescription:" $_.Exception.Response.StatusDescription
							$SophosTamperInfo = $false

							$backoff = Get-Random -Minimum 0 -Maximum (@(30000, (1000 * [Math]::Pow(2, $attempt)))| Measure-Object -Minimum).Minimum
							$attempt++
							$SophosFailedSleepTime += $backoff
							Write-Host "Sleep for: $([int]$backoff)"
							Start-Sleep -Milliseconds ([int]$backoff)
						}
					}
				}

				if ($SophosFailedSleepTime -ge $MaxFailTime) {
					break foreachSophosDevice
				}

				if ($SophosTamperInfo -and $SophosTamperInfo.password) {
					$SophosTamperKeys.Add([PsCustomObject]@{
						id = $Device.id
						password = $SophosTamperInfo.password
						enabled = $SophosTamperInfo.enabled
					}) | Out-Null;
				}

				if (!$SophosTamperInfo.enabled) {
					# Sophos tamper protection is not enabled, has it been disabled for more than a week?
					$OneMonthAgo = [int](New-TimeSpan -Start (Get-Date "01/01/1970") -End (Get-Date).AddDays(-30).ToUniversalTime()).TotalSeconds
					$OneWeek = [int](New-TimeSpan -Start (Get-Date).AddDays(-7).ToUniversalTime() -End (Get-Date).ToUniversalTime()).TotalSeconds
	
					$FilterQuery_Params = @{
						LogHistory = $LogHistory
						StartTime = $OneMonthAgo
						EndTime = 'now'
						ServiceTarget = 'sophos'
						Sophos_Device_ID = $Device.id
						ChangeType = 'sophos_tamper_disabled'
						Hostname = $Device.hostname
						Reason = "Sophos Tamper Protection is Disabled"
					}
					$TamperProtectionDisabled = log_query @FilterQuery_Params
					log_change -Company_Acronym $Company_Acronym -ServiceTarget "sophos" -RMM_Device_ID $false -SC_Device_ID $false -Sophos_Device_ID $Device.id -ChangeType "sophos_tamper_disabled" -Hostname $Device.hostname -Reason "Sophos Tamper Protection is Disabled"
	
					if (($TamperProtectionDisabled | Measure-Object).count -ge 2 -and (log_time_diff($TamperProtectionDisabled)) -ge $OneWeek -and 
						$Device.hostname -notin $Allow_Tamper_Protection_Disabled -and $Device.id -notin $Allow_Tamper_Protection_Disabled -and !$AllowTamperProtectionDisabled
					) {
						$MatchedDevice = $MatchedDevices | Where-Object { $_.sophos_matches -contains $Device.id }
						$LastSeen = Get-Date $Device.lastSeenAt
						
						if ((($MatchedDevice.sc_matches | Measure-Object).count -ge 0 -or ($MatchedDevice.rmm_matches | Measure-Object).count -ge 0) -and $LastSeen -gt (Get-Date).AddDays(-3)) {
							# Disabled for over 1 week, turn tamper protection back on (only if in rmm or sc and active in sophos, otherwise this device may have been decommissioned)
							$PostBody = @{
								enabled = $true
								regeneratePassword = $false
							}
							$TamperProtectionResponse = Invoke-RestMethod -Method POST -Headers $SophosHeader -uri ($TenantApiHost + "/endpoint/v1/endpoints/$($Device.id)/tamper-protection") -Body ($PostBody | ConvertTo-Json) -ContentType "application/json"
	
							if ($TamperProtectionResponse.enabled -and !$TamperProtectionResponse.error) {
								Write-Host "Re-enabled Sophos Tamper Protection on: $($Device.hostname)"
							} else {
								# Failed to re-enabled tamper protection, create a ticket
							}
						}
					}
				}
			}

			if ($SophosTamperKeys.Count -gt 0 -and $SophosFailedSleepTime -lt $MaxFailTime) {
				@{
					keys = $SophosTamperKeys
					lastUpdated = (Get-Date)
				} | ConvertTo-Json | Out-File -FilePath $SophosTamperKeysJsonPath
				Write-Host "Exported Sophos Tamper Protection keys."
			}
			Write-Progress -Activity "Retrieving Sophos Tamper Protection Keys" -Status "Ready" -Completed
		} elseif ($SophosTamperKeysJson -and $SophosTamperKeysJson.keys) {
			$SophosTamperKeys = $SophosTamperKeysJson.keys;
		}
	}

	# Get a count and full list of devices that have been used in the last $InactiveBillingDays for billing
	if ($DOBillingExport) {
		Write-Host "Building a device list for billing..."
		$BillingDevices = @()
		$AllDevices = @()
		$AssetReport = @()
		$Now = Get-Date

		foreach ($Device in $MatchedDevices) {
			$ActivityComparison = $Device.activity_comparison
			$Activity = $ActivityComparison.Values | Sort-Object last_active

			if (($Activity | Measure-Object).count -gt 0) {
				$NewestDate = [DateTime]($Activity.last_active | Sort-Object | Select-Object -Last 1)

				$Timespan = New-TimeSpan -Start $NewestDate -End $Now
				
				$SCDeviceID = if ($ActivityComparison.sc) { $ActivityComparison.sc[0].id } else { $false }
				$RMMDeviceID = if ($ActivityComparison.rmm) { $ActivityComparison.rmm[0].id } else { $false }
				$SophosDeviceID = if ($ActivityComparison.sophos) { $ActivityComparison.sophos[0].id } else { $false }
				$ITGDeviceID = if (($Device.itg_matches | Measure-Object).Count -gt 0) { $Device.itg_matches[0] } else { $false }
				$AutotaskDeviceID = if (($Device.autotask_matches | Measure-Object).Count -gt 0) { $Device.autotask_matches[0] } else { $false }
				$JumpCloudDeviceID = if (($Device.jc_matches | Measure-Object).Count -gt 0) { $Device.jc_matches[0] } else { $false }
				$AzureDeviceID = if ($ActivityComparison.azure) { $ActivityComparison.azure[0].id } else { $false }
				$IntuneDeviceID = if ($ActivityComparison.intune) { $ActivityComparison.intune[0].id } else { $false }
				$NiniteDeviceID = if ($ActivityComparison.ninite) { $ActivityComparison.ninite[0].id } else { $false }

				$Hostname = $false
				$SerialNumber = $false
				$Location = $false
				$AssignedUser = $false
				$DeviceType = $false
				$LastUser = $false
				$OperatingSystem = $false
				$Manufacturer = $false
				$Model = $false
				$CPUs = $false
				$CPUCores = $false
				$CPUName = $false
				$CPUReleaseDate = $false
				$CPUScore = $false
				$RAM = $false
				$WarrantyStart = $false
				$WarrantyExpiry = $false
				$ReplacementYear = $false
				$SophosTamperKey = $false
				$SophosTamperStatus = $false
				$AzureLastSignIn = $false
				$AzureTrustType = $false
				$IntuneLastSync = $false
				$IntuneCompliance = $false
				$IntuneDeviceOwnerType = $false
				$IntuneIsEncrypted = $null
				$RMMAntivirus = $false
				$JumpCloudDevice = @()
				$JCLastContact = @()
				$JCUser = @()

				if ($RMMDeviceID) {
					$RMMDevice = $RMM_DevicesHash[$RMMDeviceID]
					$Hostname = $RMMDevice."Device Hostname"
					$SerialNumber = $RMMDevice."Serial Number"
					$LastUser = ($RMMDevice."Last User" -split '\\')[1]
					$OperatingSystem = $RMMDevice."Operating System"
					$Manufacturer = $RMMDevice."Manufacturer"
					$Model = $RMMDevice."Device Model"
					$WarrantyExpiry = $RMMDevice."Warranty Expiry"
					$DeviceType = $RMMDevice."Device Type"
					$CPUs = @($RMMDevice.cpus.name)
					$CPUCores = $RMMDevice.cpuCores
					$RAM = [math]::Round($RMMDevice.memory / 1024 / 1024 / 1024) # bytes to GB

					if ($LastUser -and $RMMDevice."Last User" -like "$($Hostname)\*") {
						$LastUser = "$($LastUser) (Local)"
					}
				}
				if ($ITGDeviceID) {
					$ITGDevice = $ITG_DevicesHash[$ITGDeviceID]
					if (!$Location) {
						$Location = $ITGDevice.attributes."location-name"
					}
					if (!$AssignedUser) {
						$AssignedUser = $ITGDevice.attributes."contact-name"
					}
					if (!$SerialNumber) {
						$SerialNumber = $ITGDevice.attributes.'serial-number'
					}
					if (!$DeviceType) {
						$DeviceType = $ITGDevice.attributes."configuration-type-name"
					}
					if (!$WarrantyExpiry) {
						$WarrantyExpiry = $ITGDevice.attributes.'warranty-expires-at'
					}
					if (!$WarrantyStart) {
						$WarrantyStart = $ITGDevice.attributes.'purchased-at'
					}
				}
				if ($AutotaskDeviceID) {
					$AutotaskDevice = $Autotask_DevicesHash[$AutotaskDeviceID]
					if ($AutotaskDevice) {
						$AutotaskLocation = $Autotask_Locations | Where-Object { $_.id -eq $AutotaskDevice.companyLocationID }
						$AutotaskContact = $Autotask_Contacts | Where-Object { $_.id -eq $AutotaskDevice.contactID }

						if (!$Location -and $AutotaskLocation) {
							$Location = $AutotaskLocation.name
						}
						if (!$AssignedUser -and $AutotaskContact) {
							$AssignedUser = $AutotaskContact.firstName + " " + $AutotaskContact.lastName
						}
						if (!$Hostname) {
							$Hostname = $AutotaskDevice.rmmDeviceAuditHostname
						}
						if (!$Hostname) {
							$Hostname = $AutotaskDevice.referenceTitle
						}
						if (!$SerialNumber) {
							$SerialNumber = $AutotaskDevice.serialNumber
						}
						if (!$LastUser -and $AutotaskDevice.rmmDeviceAuditLastUser) {
							$LastUser = ($AutotaskDevice.rmmDeviceAuditLastUser -split '\\')[1]
							if ($LastUser -and $AutotaskDevice.rmmDeviceAuditLastUser -like "$($Hostname)\*") {
								$LastUser = "$($LastUser) (Local)"
							}
						}
						if (!$OperatingSystem) {
							$OperatingSystem = $AutotaskDevice.rmmDeviceAuditOperatingSystem
						}
						if ($AutotaskDevice.warrantyExpirationDate -and [string]$AutotaskDevice.warrantyExpirationDate -as [DateTime]) {
							$WarrantyExpiry = $AutotaskDevice.warrantyExpirationDate
						}
						$WarrantyStart = ($AutotaskDevice.userDefinedFields | Where-Object { $_.name -eq "Warranty Start Date" }).value
					}
				}
				if ($AzureDeviceID) {
					$TrustTypes = @{
						AzureAd = "Azure AD Joined"
						ServerAd = "Domain Joined"
						Workplace = "Workplace Joined"
					}
					$AzureDevice = $Azure_DevicesHash[$AzureDeviceID]
					$AzureLastSignIn = [DateTime]$AzureDevice.ApproximateLastSignInDateTime
					$AzureTrustType = "N/A"
					if ($AzureDevice.TrustType) {
						$AzureTrustType = $TrustTypes[$AzureDevice.TrustType]
					}
				}
				if ($IntuneDeviceID) {
					$IntuneDevice = $Intune_DevicesHash[$IntuneDeviceID]
					$IntuneLastSync = [DateTime]$IntuneDevice.LastSyncDateTime
					$IntuneCompliance = $IntuneDevice.ComplianceState
					$IntuneDeviceOwnerType = $IntuneDevice.ManagedDeviceOwnerType
					$IntuneIsEncrypted = $IntuneDevice.IsEncrypted
				}
				if ($SCDeviceID) {
					$SCDevice = $SC_DevicesHash[$SCDeviceID]
					if (!$Hostname) {
						$Hostname = $SCDevice.Name
					}
					if (!$SerialNumber) {
						$SerialNumber = $SCDevice.GuestMachineSerialNumber
					}
					if (!$DeviceType) {
						$DeviceType = $SCDevice.DeviceType
					}
					if (!$LastUser) {
						$LastUser = $SCDevice.GuestLoggedOnUserName
					}
					if ($SCDevice.GuestOperatingSystemName) {
						$OperatingSystem = $SCDevice.GuestOperatingSystemName
					}
					if (!$Manufacturer) {
						$Manufacturer = $SCDevice.GuestMachineManufacturerName
					}
					if (!$Model) {
						$Model = $SCDevice.GuestMachineModel
					}
					if (!$CPUs) {
						$CPUs = @($SCDevice.GuestProcessorName)
					}
					if (!$CPUCores) {
						$CPUCores = @($SCDevice.GuestProcessorVirtualCount)
					}
					if (!$RAM) {
						$RAM = [math]::Round($SCDevice.GuestSystemMemoryTotalMegabytes / 1024)
					}
				}
				if ($JumpCloudDeviceID) {
					foreach ($DeviceID in $Device.jc_matches) {
						$JumpCloudDevice += $JC_DevicesHash[$DeviceID]
					}
					$JumpCloudDevice.lastContact | ForEach-Object {
						if ($_) {
							$JCLastContact += [DateTime]$_
						}
					}
					$JCLastContact = $JCLastContact | Sort-Object -Descending | Select-Object -First 1
					if ($JC_Users) {
						foreach ($JCDevice in $JumpCloudDevice) {
							$JCUser += $JC_Users | Where-Object { $_.SystemID -eq $JCDevice.id }
						}
					}

					$JCDevice = $JC_DevicesHash[$JumpCloudDeviceID]
					if ($JCDevice) {
						if (!$Hostname) {
							$Hostname = $JCDevice.displayName
						}
						if (!$SerialNumber) {
							$SerialNumber = $JCDevice.serialNumber
						}
						if (!$DeviceType) {
							$DeviceType = if ($JCDevice.version -like "*Server*") {"Server"} else {"Workstation"}
						}
						if (!$OperatingSystem) {
							$OperatingSystem = ($JCDevice.os + " " + $JCDevice.version)
						}
					}
				}
				if ($NiniteDeviceID) {
					$NiniteDevice = $Ninite_DevicesHash[$NiniteDeviceID]

					if (!$Hostname -and $NiniteDevice.name) {
						$Hostname = $NiniteDevice.name
					} elseif (!$Hostname -and $NiniteDevice.machine_name) {
						$Hostname = $NiniteDevice.machine_name
					}
					if (!$LastUser -and $NiniteDevice.last_user) {
						$LastUser = $NiniteDevice.last_user
					}
					if (!$OperatingSystem -and $NiniteDevice.win_product_name) {
						$OperatingSystem = $NiniteDevice.win_product_name
					}
					if (!$DeviceType -and $NiniteDevice.win_type) {
						$DeviceType = if ($NiniteDevice.win_type -like "Server" -or $NiniteDevice.win_type -like "DomainController") {"Server"} else {"Workstation"}
					}
				}
				if ($SophosDeviceID) {
					$SophosDevice = $Sophos_DevicesHash[$SophosDeviceID]
					if (!$Hostname) {
						$Hostname = $SophosDevice.hostname
					}
					if (!$LastUser) {
						$LastUser = $SophosDevice.LastUser
					}
					if (!$DeviceType) {
						$DeviceType = $SophosDevice.Type
					}
					if (!$OperatingSystem) {
						$OperatingSystem = $SophosDevice.OS
					}

					if ($SophosTamperKeys -and $SophosTamperKeys.id -contains $SophosDeviceID) {
						$SophosTamperInfo = $SophosTamperKeys | Where-Object { $_.id -eq $SophosDeviceID }
						$SophosTamperKey = $SophosTamperInfo.password
						$SophosTamperStatus = $SophosTamperInfo.enabled
					}
				}
				if (!$SophosDeviceID -and $RMMDeviceID) {
					$RMMAntivirus = $RMMDevice.Antivirus
				} elseif (!$SophosDeviceID -and $NiniteDeviceID) {
					$NiniteAV = $NiniteDevice.anti_virus
					if ($NiniteAV.Count -gt 0) {
						$NiniteAV = $NiniteAV | Where-Object { ($([Convert]::ToString($($_.productState), 16)).PadLeft(6,"0")).Substring(2,1) -eq 1 }
					}
					if ($NiniteAV.Count -gt 0 -and ($NiniteAV.onAccessScanningEnabled -contains $true)) {
						$NiniteAV = $NiniteAV | Where-Object { $_.onAccessScanningEnabled -eq $true }
					}
					if ($NiniteAV.Count -gt 0 -and ($NiniteAV.displayName -like "*Sophos Intercept*")) {
						$NiniteAV = $NiniteAV | Where-Object { $_.displayName -like "*Sophos Intercept*" }
					}
					if ($NiniteAV.Count -gt 0 -and ($NiniteAV.displayName -like "*Sophos*")) {
						$NiniteAV = $NiniteAV | Where-Object { $_.displayName -like "*Sophos*" }
					}
					$NiniteAV = $NiniteAV | Select-Object -First 1
					$RMMAntivirus = $NiniteAV.displayName
				}

				# get cpu performance score
				if ($CPUs) {
					foreach ($CPU in $CPUs) {
						$CPUMatch = $false
						$JsonMatchSaved = $false
						$CPUMatchTemp = $CPUMatching | Where-Object { $_.CPU -eq $CPU }
						if ($CPUMatchTemp) {
							if ($CPUMatchTemp.ID -and $CPUDetailsHash[$CPUMatchTemp.ID]) {
								$CPUMatch = $CPUDetailsHash[$CPUMatchTemp.ID]
								$JsonMatchSaved = $true
							} else {
								$CPUMatching = $CPUMatching | Where-Object { $_.CPU -ne $CPU }
							}
						}

						if (!$CPUMatch) {
							$CleanName = $CPU -replace [regex]::escape("(R)"), "" -replace [regex]::escape("(C)"), "" -replace [regex]::escape("(TM)"), "" -replace "CPU", "" -replace '\s+', ' '
							$CPUMatch = $CPUDetails | Where-Object { $_.Name -like $CleanName }
						}
						if (!$CPUMatch) {
							$CPUMatch = $CPUDetails | Where-Object { ($_.Name -replace "-", " ") -like ($CleanName -replace "-", " ") }
						}
						if (!$CPUMatch) {
							$CPUMatch = $CPUDetails | Where-Object { $CleanName -like ($_.Name + "*") -or $CleanName -like ("*" + $_.Name) }
						}
						if (!$CPUMatch) {
							$CPUMatch = $CPUDetails | Where-Object { $CleanName -like ("*" + $_.Name + "*") }
						}
						if (!$CPUMatch) {
							$CPUMatch = $CPUDetails | Where-Object { $_.Name -like ("*" + $CleanName + "*") }
						}
	
						if (($CPUMatch | Measure-Object).Count -gt 1) {
							if ($CPUMatch.Cores -contains $CPUCores) {
								$CPUMatch = $CPUMatch | Where-Object { $_.Cores -eq $CPUCores }
							}
						}

						if (($CPUMatch | Measure-Object).Count -gt 1) {
							$BestMatch = $false
							$BestScore = 999
							foreach ($Match in $CPUMatch) {
								$Distance = Measure-StringDistance -Source $Match.Name -Compare $CleanName
								if ($Distance -lt $BestScore) {
									$BestMatch = $Match
									$BestScore = $Distance
								}
							}
							if ($BestMatch) {
								$CPUMatch = $BestMatch
							} else {
								$CPUMatch = $CPUMatch | Select-Object -First 1
							}
						}

						if ($CPUMatch -and (!$CPUScore -or $CPUMatch.CPUMark -gt $CPUScore)) {
							$CPUName = $CPUMatch.Name
							$CPUScore = $CPUMatch.CPUMark
							$CPUReleaseDate = $CPUMatch.Release

							if (!$JsonMatchSaved) {
								$CPUMatching += [PSCustomObject]@{
									CPU = $CPU
									ID = $CPUMatch.ID
								
								}
							}
						} elseif (!$CPUName) {
							$CPUName = $CleanName
						}
					}
				}

				# calculate device age and replacement date
				if ($WarrantyStart -and [string]$WarrantyStart -as [DateTime]) {
					$ReplacementYear = (([DateTime]$WarrantyStart).AddYears(5)).Year
					$AgeDiff = NEW-TIMESPAN -Start $WarrantyStart -End (Get-Date)
					$DeviceAge = [math]::Round($AgeDiff.Days / 360)
				} elseif ($WarrantyExpiry -and [string]$WarrantyExpiry -as [DateTime]) {
					$ReplacementYear = (([DateTime]$WarrantyExpiry).AddYears(2)).Year
					$AgeDiff = NEW-TIMESPAN -Start (([DateTime]$WarrantyExpiry).AddYears(-2)) -End (Get-Date)
					$DeviceAge = [math]::Round($AgeDiff.Days / 360)
				} elseif ($CPUReleaseDate) {
					$MatchFound = $CPUReleaseDate -match "Q(\d) (\d{4})"
					if ($MatchFound) {
						[int]$ReleaseQuarter = $Matches[1]
						[int]$ReleaseYear = $Matches[2]
						if ($ReleaseQuarter -gt 0 -and $ReleaseYear -gt 0) {
							$ReleaseDate = Get-Date -Year $ReleaseYear -Month ((($ReleaseQuarter - 1) * 3) + 1)
							$ReplacementYear = (($ReleaseDate).AddYears(5)).Year
							$AgeDiff = NEW-TIMESPAN -Start $ReleaseDate -End (Get-Date)
							$DeviceAge = [math]::Round($AgeDiff.Days / 360)
						}
					}
				}

				# cleanup data to be more readable
				if ($Manufacturer) {
					if ($Manufacturer -like "*/*") {
						$Manufacturer = ($Manufacturer -split '/')[0]
					}
					$Manufacturer = $Manufacturer.Trim()
					$ManufacturerCleanup | Foreach-Object { 
						if ($Manufacturer -like $_.name -or $Manufacturer -match $_.name) {
							if ($_.caseSensitive) {
								$Manufacturer = $Manufacturer -creplace $_.name, $_.replacement
							} else {
								$Manufacturer = $Manufacturer -replace $_.name, $_.replacement
							}
						}
					}
					$Manufacturer = $Manufacturer.Trim()
				}

				if (!$Manufacturer) {
					$Manufacturer = "Custom Build"
				}
				
				if ($Model) {
					$Model = $Model -replace "System Product Name", "Custom Build"
					$Model = $Model -replace "To be filled by O.E.M.", "Custom Build"
					$Model = $Model -replace $Manufacturer, ""
					$Model = $Model.Trim();
				}
				if (!$Model) {
					$Model = "Custom Build"
				}

				if ($SerialNumber) {
					if ($SerialNumber -in $IgnoreSerials) {
						$SerialNumber = ''
					}
				}

				if ($RAM) {
					$RAM = [string]$RAM + " GB"
				}

				if ($OperatingSystem) {
					if ($OperatingSystem -like "Microsoft*" -or $OperatingSystem -like "Windows*") {
						$OperatingSystem = $OperatingSystem -replace " ?(((\d+)\.*)+)$", ""
						$OperatingSystem = $OperatingSystem -replace " Service Pack ?\d?\d?$", ""
						$OperatingSystem = $OperatingSystem -replace "Microsoft ", ""
						$OperatingSystem = $OperatingSystem -replace "Professional", "Pro"
					} elseif ($OperatingSystem -like "VMware*") {
						$OperatingSystem = $OperatingSystem -replace " ?(build\d*) (((\d+)\.*)+)$", ""
					} elseif ($OperatingSystem -like "Linux*") {
						if ($OperatingSystem -match "(\w+\s\w+)[^0-9]*(\d\d?).*") {
							$OperatingSystem = $Matches[1] + " " + $Matches[2]
						}
					}
				}

				if ($WarrantyExpiry) {
					$WarrantyExpiry = $WarrantyExpiry -replace " UTC$", ""
					$WarrantyExpiry = ([DateTime]$WarrantyExpiry).ToString("yyyy-MM-dd")
				}
				if ($WarrantyStart) {
					$WarrantyStart = $WarrantyStart -replace " UTC$", ""
					$WarrantyStart = ([DateTime]$WarrantyStart).ToString("yyyy-MM-dd")
				}



				if (!$DeviceType) {
					if ($OperatingSystem -and $OperatingSystem -like "*Server*") {
						$DeviceType = "Server"
					} else {
						$DeviceType = "Workstation"
					}
				}

				if (!$Hostname) { $Hostname = "" }
				if (!$SerialNumber) { $SerialNumber = "" }
				if (!$Location) { $Location = "" }
				if (!$AssignedUser) { $AssignedUser = "" }
				if (!$DeviceType) { $DeviceType = "" }
				if (!$LastUser) { $LastUser = "" }
				if (!$OperatingSystem) { $OperatingSystem = "" }
				if (!$Manufacturer) { $Manufacturer = "" }
				if (!$Model) { $Model = "" }
				if (!$CPUName) { $CPUName = "" }
				if (!$CPUScore) { $CPUScore = "" }
				if (!$RAM) { $RAM = "" }
				if (!$DeviceAge -and $DeviceAge -isnot [int]) { $DeviceAge = "" }
				if (!$WarrantyStart) { $WarrantyStart = "" }
				if (!$WarrantyExpiry) { $WarrantyExpiry = "" }
				if (!$ReplacementYear) { $ReplacementYear = "" }
				if (!$SophosTamperKey) { $SophosTamperKey = "" }

				# Count as billed if not inactive, ignore devices only in sophos and not seen in the past week as they were likely decommissioned, and
				# ignore devices that appear to be under the wrong company
				$Billed = $true
				$DoAssetReport = $true
				$BilledStr = "Yes"
				if ($Timespan.Days -ge $InactiveBillingDays) {
					$Billed = $false
					$BilledStr = "No (Inactive)"
				} 
				if (!$RMMDeviceID -and !$SCDeviceID -and $Timespan.Days -gt 7) {
					$Billed = $false
					$DoAssetReport = $false
					$BilledStr = "No (Decommissioned)"
				}
				if ($MoveDevices -and $Device.id -in $MoveDevices.ID) {
					$Billed = $false
					$DoAssetReport = $false
					$BilledStr = "No (Wrong Company?)"
				}

				if ($Billed) {

					$BillingDevices += [PsCustomObject]@{
						Hostname = $Hostname
						DeviceType = $DeviceType
						Location = $Location
						"Assigned User" = $AssignedUser
						LastUser = $LastUser
						SerialNumber = $SerialNumber
						Manufacturer = $Manufacturer
						Model = $Model
						OS = $OperatingSystem
						LastActive = $NewestDate
						WarrantyExpiry = $WarrantyExpiry
					}
				}

				$DeviceInfo = [PsCustomObject]@{
					Hostname = $Hostname
					DeviceType = $DeviceType
					Location = $Location
					"Assigned User" = $AssignedUser
					LastUser = $LastUser
					"JumpCloud Users" = if (($JCUser | Measure-Object).Count -gt 0) { $JCUser.Username -join ", " } else { "None" }
					SerialNumber = $SerialNumber
					Manufacturer = $Manufacturer
					Model = $Model
					OS = $OperatingSystem
					LastActive = $NewestDate
					WarrantyExpiry = $WarrantyExpiry
					Billed = $BilledStr
					"Azure Trust Type" = if ($AzureTrustType) { $AzureTrustType } else { "NA" }
					"Intune Compliance" = if ($IntuneCompliance) { $IntuneCompliance } else { "NA" }
					"Itune Device Owner Type" = if ($IntuneDeviceOwnerType) { $IntuneDeviceOwnerType } else { "NA" }
					"Is Encrypted (Intune)" = if ($null -ne $IntuneIsEncrypted) { $IntuneIsEncrypted } else { "NA" }
					InSC = if ($SCDeviceID) { "Yes" } else { "No" }
					InRMM = if ($RMMDeviceID) { "Yes" } else { "No" }
					InSophos = if ($SophosDeviceID) { "Yes" } elseif ($RMMAntivirus -and $RMMAntivirus -like "Sophos*") { "Yes, missing from portal" } else { "No" }
					InNinite = if ($NiniteDeviceID) { "Yes" } else { "No" }
					InITG = if ($ITGDeviceID) { "Yes" } else { "No" }
					InAutotask = if ($AutotaskDeviceID) { "Yes" } else { "No" }
					InJumpCloud = if ($JumpCloudDeviceID) { if ($JumpCloudDevice.active) { "Yes (Active)" } else { "Yes (Inactive)" } } else { "No" }
					InAzure = if ($AzureDeviceID) { if ($Device.azure_match_warning) { "Yes (May be inaccurate)" } else { "Yes" } } else { "No" }
					InIntune = if ($IntuneDeviceID) { "Yes" } else { "No" }
					SC_Time = if ($ActivityComparison.sc) { $ActivityComparison.sc[0].last_active } else { "NA" }
					RMM_Time = if ($ActivityComparison.rmm) { $ActivityComparison.rmm[0].last_active } else { "NA" }
					Sophos_Time = if ($ActivityComparison.sophos) { $ActivityComparison.sophos[0].last_active } else { "NA" }
					Ninite_Time = if ($ActivityComparison.ninite) { $ActivityComparison.ninite[0].last_active } else { "NA" }
					JumpCloud_Time = if ($JCLastContact) { $JCLastContact } else { "NA" }
					Azure_Time = if ($AzureLastSignIn) { $AzureLastSignIn } else { "NA" }
					Intune_Time = if ($IntuneLastSync) { $IntuneLastSync } else { "NA" }
					SophosTamperProtectionKey = $SophosTamperKey
					SophosTamperStatus = if ($SophosTamperStatus) { "On" } else { "Off" }
				}
				if (!$JCConnected) {
					$DeviceInfo.PSObject.Properties.Remove('InJumpCloud')
					$DeviceInfo.PSObject.Properties.Remove('JumpCloud_Time')
					$DeviceInfo.PSObject.Properties.Remove('JumpCloud Users')
				}
				if (!$AzureConnected) {
					$DeviceInfo.PSObject.Properties.Remove('InAzure')
					$DeviceInfo.PSObject.Properties.Remove('InIntune')
					$DeviceInfo.PSObject.Properties.Remove('Azure_Time')
					$DeviceInfo.PSObject.Properties.Remove('Intune_Time')
					$DeviceInfo.PSObject.Properties.Remove('Azure Trust Type')
					$DeviceInfo.PSObject.Properties.Remove('Intune Compliance')
					$DeviceInfo.PSObject.Properties.Remove('Itune Device Owner Type')
				}
				$AllDevices += $DeviceInfo

				if ($DeviceType -eq "Server" -or $Model -like "*Virtual *" -or !$DoAssetReport) {
					continue
				}		

				$AssetReport += [PsCustomObject]@{
					Device = $Hostname
					Location = $Location
					"Assigned User" = $AssignedUser
					"Last Login" = $LastUser
					"Active?" = if ($BilledStr -eq "Yes") { "X" } else { "" }
					Make = $Manufacturer
					Model = $Model
					Serial = $SerialNumber
					"Operating System" = $OperatingSystem
					RAM = $RAM
					CPU = $CPUName
					"CPU Performance" = $CPUScore
					Purchased = $WarrantyStart
					"Warranty Expiry" = $WarrantyExpiry
					"Age (years)" = $DeviceAge
					"Replacement Year" = $ReplacementYear
					"Suggested Replacement" = ""
					"Replacement Budget" = ""
					Notes = if ($BilledStr -ne "Yes") { "Last Seen: " + $NewestDate.ToString("yyyy-MM-dd") } else { "" }
				}
			}
		}

		$CPUMatching | ConvertTo-Json | Out-File -FilePath ($CPUDataLocation + "\cpu_matching.json")

		if (($BillingDevices | Measure-Object).count -gt 0) {
			# Get device type counts
			$DeviceCounts = @()
			$DeviceCounts += [PSCustomObject]@{
				Type = "Servers"
				Count = @($BillingDevices | Where-Object { $_.DeviceType -like "Server" }).count
			}
			$DeviceCounts += [PSCustomObject]@{
				Type = "Workstations"
				Count = @($BillingDevices | Where-Object { $_.DeviceType -notlike "Server" }).count
			}

			$FullDeviceCounts = @()
			$FullDeviceCounts += [PSCustomObject]@{
				Type = "Servers"
				BilledCount = @($AllDevices | Where-Object { $_.DeviceType -like "Server" -and $_.Billed -like "Yes*" }).count
				UnBilledCount = @($AllDevices | Where-Object { $_.DeviceType -like "Server" -and $_.Billed -like "No*" }).count
			}
			$FullDeviceCounts += [PSCustomObject]@{
				Type = "Workstations"
				BilledCount = @($AllDevices | Where-Object { $_.DeviceType -notlike "Server" -and $_.Billed -like "Yes*" }).count
				UnBilledCount = @($AllDevices | Where-Object { $_.DeviceType -notlike "Server" -and $_.Billed -like "No*" }).count
			}

			# Get server breakdown counts
			$ServerCounts = @()
			$AllServers = @($AllDevices | Where-Object { $_.DeviceType -like "Server" -and $_.Billed -like "Yes*" })
			$ServerCounts += [PSCustomObject]@{
				Type = "Physical"
				Count = @($AllServers | Where-Object { $_.Hostname -notlike "*BDR*" -and $_.Model -and $_.Model -notlike "*Virtual*" }).count
			}
			$ServerCounts += [PSCustomObject]@{
				Type = "Virtual"
				Count = @($AllServers | Where-Object { $_.Hostname -notlike "*BDR*" -and ($_.Model -like "*Virtual*" -or !$_.Model) }).count
			}
			$ServerCounts += [PSCustomObject]@{
				Type = "BDR (Backup)"
				Count = @($AllServers | Where-Object { $_.Hostname -like "*BDR*" }).count
			}

			# Build an overview document
			if ($companies -contains "ALL") {
				$DeviceCount_Overview += [PSCustomObject]@{
					Company = $OrgFullName
					"Billed Servers" = @($AllDevices | Where-Object { $_.DeviceType -like "Server" -and $_.Billed -like "Yes*" }).count
					"Billed Workstations" = @($AllDevices | Where-Object { $_.DeviceType -notlike "Server" -and $_.Billed -like "Yes*" }).count
					"Unbilled Servers" = @($AllDevices | Where-Object { $_.DeviceType -like "Server" -and $_.Billed -like "No*" }).count
					"Unbilled Workstations" = @($AllDevices | Where-Object { $_.DeviceType -notlike "Server" -and $_.Billed -like "No*" }).count
					"Total Servers" = @($AllDevices | Where-Object { $_.DeviceType -like "Server" }).count
					"Total Workstations" = @($AllDevices | Where-Object { $_.DeviceType -notlike "Server" }).count
					"Servers - Physical" = @($AllServers | Where-Object { $_.Hostname -notlike "*BDR*" -and $_.Model -and $_.Model -notlike "*Virtual*" }).count
					"Servers - Virtual" = @($AllServers | Where-Object { $_.Hostname -notlike "*BDR*" -and ($_.Model -like "*Virtual*" -or !$_.Model) }).count
					"Servers - BDR" = @($AllServers | Where-Object { $_.Hostname -like "*BDR*" }).count
				}
			}

			# Export to json file so we can check for changes between months
			if ($HistoryLocation) {
				if (!(Test-Path -Path $HistoryLocation)) {
					New-Item -ItemType Directory -Force -Path $HistoryLocation | Out-Null
				}
				$Month = Get-Date -Format "MM"
				$Year = Get-Date -Format "yyyy"

				$DeviceHistory = @{
					DeviceCounts = $DeviceCounts
					ServerCounts = $ServerCounts
				}
				$DeviceHistoryPath = "$($HistoryLocation)\$($Company_Acronym)_device_counts_$($Month)_$($Year).json"
				$DeviceHistory | ConvertTo-Json | Out-File -FilePath $DeviceHistoryPath
				Write-Host "Exported the device count history files."
			}

			# Create an excel document (for customers)
			$MonthName = (Get-Culture).DateTimeFormat.GetMonthName([int](Get-Date -Format MM))
			$Year = Get-Date -Format yyyy
			$FileName = "$($Company_Acronym)--Device_List--$($MonthName)_$Year.xlsx"
			$Path = $PSScriptRoot + "\$FileName"
			$BillingDeviceFileName = $FileName
			$BillingDeviceList = $Path
			Remove-Item $Path -ErrorAction SilentlyContinue

			$BillingDevices | Sort-Object -Property DeviceType, Hostname | 
				Export-Excel $Path -WorksheetName "Device List" -AutoSize -AutoFilter -NoNumberConversion * -TableName "DeviceList" -Title "Device List" -TitleBold -TitleSize 18
			$excel = $DeviceCounts | Export-Excel $Path -WorksheetName "Device Counts" -AutoSize -PassThru -Title "Device Count" -TitleBold -TitleSize 18
			$ws_counts = $excel.Workbook.Worksheets['Device Counts']
			Add-ExcelTable -PassThru -Range $ws_counts.Cells["A2:B4"] -TableName DeviceCounts -TableStyle "Light21" -ShowFilter:$false -ShowTotal -ShowFirstColumn -TableTotalSettings @{"Count" = "Sum"} | Out-Null
			$xlParams = @{WorkSheet=$ws_counts; Bold=$true; FontSize=18; Merge=$true}
			Set-ExcelRange -Range "A7:B7" -Value "Server Breakdown" @xlParams
			$excel = $ServerCounts | Export-Excel -PassThru -ExcelPackage $excel -WorksheetName $ws_counts -AutoSize -StartRow 8 -TableName ServerBreakdown -TableStyle "Light21"
			Add-ExcelTable -PassThru -Range $ws_counts.Cells["A8:B10"] -TableName ServerBreakdown -TableStyle "Light21" -ShowFilter:$false -ShowTotal -ShowFirstColumn -TableTotalSettings @{"Count" = "Sum"} | Out-Null

			Close-ExcelPackage $excel

			# Create a second excel document (for techs with extra info)
			$FileName = "$($Company_Acronym)--Device_List--$($MonthName)_$Year--ForTechs.xlsx"
			$Path = $PSScriptRoot + "\$FileName"
			Remove-Item $Path -ErrorAction SilentlyContinue

			$AllDevices | Sort-Object -Property DeviceType, Hostname | Export-Excel $Path -WorksheetName "Device List" -AutoSize -AutoFilter -NoNumberConversion * -TableName "DeviceList" -Title "Full Device List" -TitleBold -TitleSize 18
			$excel = $FullDeviceCounts | Export-Excel $Path -WorksheetName "Device Counts" -AutoSize -PassThru -Title "Full Device Count" -TitleBold -TitleSize 18
			$ws_counts = $excel.Workbook.Worksheets['Device Counts']
			Add-ExcelTable -PassThru -Range $ws_counts.Cells["A2:C4"] -TableName DeviceCounts -TableStyle "Light21" -ShowFilter:$false -ShowTotal -ShowFirstColumn -TableTotalSettings @{"BilledCount" = "Sum"; "UnBilledCount" = "Sum"} | Out-Null
			$xlParams = @{WorkSheet=$ws_counts; Bold=$true; FontSize=18; Merge=$true}
			Set-ExcelRange -Range "A7:B7" -Value "Server Breakdown" @xlParams
			$excel = $ServerCounts | Export-Excel -PassThru -ExcelPackage $excel -WorksheetName $ws_counts -AutoSize -StartRow 8 -TableName ServerBreakdown -TableStyle "Light21"
			Add-ExcelTable -PassThru -Range $ws_counts.Cells["A8:B10"] -TableName ServerBreakdown -TableStyle "Light21" -ShowFilter:$false -ShowTotal -ShowFirstColumn -TableTotalSettings @{"Count" = "Sum"} | Out-Null

			Close-ExcelPackage $excel

			# Create/update a third excel document, the asset report
			$FileName = "$($Company_Acronym)--Asset_Report.xlsx"
			$Path = $PSScriptRoot + "\$FileName"
			Remove-Item $Path -ErrorAction SilentlyContinue

			$excel = $AssetReport | Sort-Object -Property Device | Export-Excel $Path -WorksheetName "Asset Report" -AutoSize -AutoFilter -NoNumberConversion * -TableName "AssetReport" -PassThru
			$rowCount = ($AssetReport | Measure-Object).Count
			$curYear = get-date -Format yyyy
			$ws_report = $excel.Workbook.Worksheets['Asset Report']
			$ws_report.Cells["P2:P$($rowCount+1)"].Style.HorizontalAlignment="Center"
			$OrangeColor = [System.Drawing.Color]::FromArgb(255,192,0)
			$GreenColor = [System.Drawing.Color]::FromArgb(146,208,80)
			Add-ConditionalFormatting -Worksheet $ws_report -Address "P2:P$($rowCount+1)" -RuleType ContainsBlanks -StopIfTrue
			Add-ConditionalFormatting -Worksheet $ws_report -Address "P2:P$($rowCount+1)" -RuleType LessThanOrEqual -ForegroundColor black -BackgroundColor red -ConditionValue ($curYear - 3)
			Add-ConditionalFormatting -Worksheet $ws_report -Address "P2:P$($rowCount+1)" -RuleType Equal -ForegroundColor black -BackgroundColor $OrangeColor -ConditionValue ($curYear - 2)
			Add-ConditionalFormatting -Worksheet $ws_report -Address "P2:P$($rowCount+1)" -RuleType Equal -ForegroundColor black -BackgroundColor yellow -ConditionValue ($curYear - 1)
			Add-ConditionalFormatting -Worksheet $ws_report -Address "P2:P$($rowCount+1)" -RuleType GreaterThanOrEqual -ForegroundColor black -BackgroundColor $GreenColor -ConditionValue ($curYear)

			Add-ConditionalFormatting -Worksheet $ws_report -Address "I2:I$($rowCount+1)" -RuleType ContainsText -ForegroundColor black -BackgroundColor red -ConditionValue "Windows XP"
			Add-ConditionalFormatting -Worksheet $ws_report -Address "I2:I$($rowCount+1)" -RuleType ContainsText -ForegroundColor black -BackgroundColor red -ConditionValue "Windows Vista"
			Add-ConditionalFormatting -Worksheet $ws_report -Address "I2:I$($rowCount+1)" -RuleType ContainsText -ForegroundColor black -BackgroundColor red -ConditionValue "Windows 7"
			Add-ConditionalFormatting -Worksheet $ws_report -Address "I2:I$($rowCount+1)" -RuleType ContainsText -ConditionValue "Windows 8.1" -StopIfTrue
			Add-ConditionalFormatting -Worksheet $ws_report -Address "I2:I$($rowCount+1)" -RuleType ContainsText -ForegroundColor black -BackgroundColor yellow -ConditionValue "Windows 8"

			Add-ConditionalFormatting -Worksheet $ws_report -Address "J2:J$($rowCount+1)" -RuleType Equal -ForegroundColor black -BackgroundColor red -ConditionValue "4 GB"
			Add-ConditionalFormatting -Worksheet $ws_report -Address "J2:J$($rowCount+1)" -RuleType Equal -ForegroundColor black -BackgroundColor red -ConditionValue "3 GB"
			Add-ConditionalFormatting -Worksheet $ws_report -Address "J2:J$($rowCount+1)" -RuleType Equal -ForegroundColor black -BackgroundColor red -ConditionValue "2 GB"
			Add-ConditionalFormatting -Worksheet $ws_report -Address "J2:J$($rowCount+1)" -RuleType Equal -ForegroundColor black -BackgroundColor red -ConditionValue "1 GB"
			Add-ConditionalFormatting -Worksheet $ws_report -Address "J2:J$($rowCount+1)" -RuleType Equal -ForegroundColor black -BackgroundColor red -ConditionValue "0 GB"
			
			Close-ExcelPackage $excel

			Write-Host "Device list exported. See: $($FileName)" -ForegroundColor Green
			$DeviceBillingUpdateRan = $true

			# Consider sending a billing update email
			$Now = get-date
			$LastDay = [DateTime]::DaysInMonth($Now.Year, $Now.Month)
			$LastWeek = $LastDay - 7

			$TenDaysAgo = [int](New-TimeSpan -Start (Get-Date "01/01/1970") -End (Get-Date).AddDays(-10).ToUniversalTime()).TotalSeconds
			$EmailChangeType = "billing-email"
			$Reason = "Email sent for billing updates"

			$EmailQuery_Params = @{
				LogHistory = $LogHistory
				StartTime = $TenDaysAgo
				EndTime = 'now'
				ServiceTarget = 'email'
				ChangeType = $EmailChangeType
				Reason = $EmailReason
			}
			$History_Subset_Emails = log_query @EmailQuery_Params

			# If the script is set to send billing update emails, check if the count changed and send an email if so 
			# (only send during last week of the month and if we haven't already sent an email in the last 10 days)
			# Also update the ITG Customer Billing page
			if ($SendBillingEmails -and $HistoryLocation -and $Now.Day -gt $LastWeek -and ($History_Subset_Emails | Measure-Object).count -eq 0) {
				# First get the history file if it exists to perform a diff
				$Month = Get-Date -Format "MM"
				$Year = Get-Date -Format "yyyy"
				$LastMonth = '{0:d2}' -f ([int]$Month - 1)
				$LastYear = $Year
				if ([int]$Month -eq 1) {
					$LastMonth = "12"
					$LastYear = $Year - 1
				}
				$CheckChanges = $false
				$DeviceHistoryPath = "$($HistoryLocation)\$($Company_Acronym)_device_counts_$($LastMonth)_$($LastYear).json"
				if (Test-Path $DeviceHistoryPath) {
					$CheckChanges = $true
					$DeviceHistory = Get-Content -Path $DeviceHistoryPath -Raw | ConvertFrom-Json
				}

				$ChangesFound = $false
				if ($CheckChanges) {
					$DeviceChanges = @{}
					$ServerChanges = @{}

					$Types = $DeviceCounts.Type
					foreach ($Type in $Types) {
						if ($DeviceHistory.DeviceCounts.Type -contains $Type) {
							$CurrentCount = ($DeviceCounts | Where-Object {$_.Type -eq $Type}).Count
							$PastCount = ($DeviceHistory.DeviceCounts | Where-Object {$_.Type -eq $Type}).Count

							if ($CurrentCount -ne $PastCount) {
								$ChangesFound = $true
								$DeviceChanges.$Type = ($CurrentCount - $PastCount).ToString("+0;-#")
							} else {
								$DeviceChanges.$Type = 0
							}
						} else {
							$DeviceChanges.$Type = "ERR"
						}
					}

					$Types = $ServerCounts.Type
					foreach ($Type in $Types) {
						if ($DeviceHistory.ServerCounts.Type -contains $Type) {
							$CurrentCount = ($ServerCounts | Where-Object {$_.Type -eq $Type}).Count
							$PastCount = ($DeviceHistory.ServerCounts | Where-Object {$_.Type -eq $Type}).Count

							if ($CurrentCount -ne $PastCount) {
								$ChangesFound = $true
								$ServerChanges.$Type = ($CurrentCount - $PastCount).ToString("+0;-#")
							} else {
								$ServerChanges.$Type = 0
							}
						} else {
							$ServerChanges.$Type = "ERR"
						}
					}
				}

				# Prepare email
				if ($ChangesFound -or !$CheckChanges) {
					# Check for duplicate serials in billing
					$AllBilledSerials = $BillingDevices | Where-Object { $_.SerialNumber -and $_.SerialNumber -notin $IgnoreSerials -and $_.SerialNumber -notlike "123456789*" } | Select-Object -ExpandProperty SerialNumber
					$DuplicateBilledSerials = $AllBilledSerials | Group-Object | Where-Object {$_.Count -gt 1}
					$DuplicateDeviceWarning = if (($DuplicateBilledSerials | Measure-Object).Count -gt 0) { $true } else { $false }

					if ($ChangesFound) {
						# Send changes
						$EmailSubject = "Bill Needs Updating for $OrgFullName"
						$EmailIntro = "The Device Audit for $OrgFullName was updated and changes were found. Please update this organizations contract."
						$EmailTitle = "Device Changes"
						$HTMLBody = '<p style="font-family: sans-serif; font-size: 14px; font-weight: normal; margin: 0; Margin-bottom: 15px;">'
						foreach ($Type in $DeviceChanges.Keys) {
							$HTMLBody += '<strong>' + $Type + ' Change:</strong> ' + $DeviceChanges[$Type] + '<br />'
						}
						$HTMLBody += '</p><br />'
						$HTMLBody += '<p style="font-family: sans-serif; font-size: 18px; font-weight: normal; margin: 0; Margin-bottom: 15px;"><strong>Server Breakdown Changes</strong></p>'
						$HTMLBody += '<p style="font-family: sans-serif; font-size: 14px; font-weight: normal; margin: 0; Margin-bottom: 15px;">'
						foreach ($Type in $ServerChanges.Keys) {
							$HTMLBody += '<strong>' + $Type + ' Change:</strong> ' + $ServerChanges[$Type] + '<br />'
						}
						$HTMLBody += '</p><br />'
						$HTMLBody += '<p style="font-family: sans-serif; font-size: 18px; font-weight: normal; margin: 0; Margin-bottom: 15px;"><strong>New Totals</strong></p>'
					} elseif (!$CheckChanges) {
						# No history found, send totals
						$EmailSubject = "Bill May Need Updating for $OrgFullName - No history found"
						$EmailIntro = "The Device Audit for $OrgFullName was updated but no billing history could be found. Please verify this organization's bill is correct. Next month an email will only be sent if changes were made."
						$EmailTitle = "New Totals"
						$HTMLBody = ""
					}

					if ($DuplicateDeviceWarning) {
						$EmailIntro += "<p><strong>Caution!</strong> At least 2 devices in the billed list share the same serial number. Please verify this is correct. The duplicate serial numbers are: $($DuplicateBilledSerials.Name -join ", ")</p>"
					}

					$HTMLBody += '<p style="font-family: sans-serif; font-size: 14px; font-weight: normal; margin: 0; Margin-bottom: 15px;">'
					foreach ($Type in $DeviceCounts.Type) {
						$CurrentCount = ($DeviceCounts | Where-Object {$_.Type -eq $Type}).Count
						$HTMLBody += '<strong>' + $Type + ':</strong> ' + $CurrentCount + '<br />'
					}
					$HTMLBody += '</p><br />'
					$HTMLBody += '<p style="font-family: sans-serif; font-size: 18px; font-weight: normal; margin: 0; Margin-bottom: 15px;"><strong>New Server Breakdown Totals</strong></p>'
					$HTMLBody += '<p style="font-family: sans-serif; font-size: 14px; font-weight: normal; margin: 0; Margin-bottom: 15px;">'
					foreach ($Type in $ServerCounts.Type) {
						$CurrentCount = ($ServerCounts | Where-Object {$_.Type -eq $Type}).Count
						$HTMLBody += '<strong>' + $Type + ':</strong> ' + $CurrentCount + '<br />'
					}
					$HTMLBody += '</p>'

					$HTMLEmail = $EmailTemplate -f `
								$EmailIntro, 
								$EmailTitle, 
								$HTMLBody, 
								"Attached is the full device audit for this organization."

					# Get the most recent device audit that was generated earlier in this script to attach to the email
					$MonthName = (Get-Culture).DateTimeFormat.GetMonthName([int](Get-Date -Format MM))
					$Year = Get-Date -Format yyyy
					$FileName = "$($Company_Acronym)--Device_List--$($MonthName)_$Year.xlsx"
					$Path = $PSScriptRoot + "\$FileName"
					$ReportEncoded = [System.Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))

					# Send email
					$mailbody = @{
						"From" = $EmailFrom
						"To" = $EmailTo_BillingUpdate
						"Subject" = $EmailSubject
						"HTMLContent" = $HTMLEmail
						"Attachments" = @(
							@{
								Base64Content = $ReportEncoded
								Filename = $FileName
								ContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
							}
						)
					} | ConvertTo-Json -Depth 6

					$headers = @{
						'x-api-key' = $Email_APIKey.Key
					}
					
					Invoke-RestMethod -Method Post -Uri $Email_APIKey.Url -Body $mailbody -Headers $headers -ContentType application/json
					Write-Host "Email Sent" -ForegroundColor Green

					# log the sent email
					log_change -Company_Acronym $Company_Acronym -ServiceTarget 'email' -RMM_Device_ID "" -SC_Device_ID "" -Sophos_Device_ID "" -ChangeType $EmailChangeType -Hostname "" -Reason $EmailReason
				}
				
				#######
				### Update ITG Customer Billing page
				#######

				# Get the info for the fields
				$TotalBilled = ($FullDeviceCounts.BilledCount | Measure-Object -Sum).Sum
				$TotalUnbilled = ($FullDeviceCounts.UnBilledCount | Measure-Object -Sum).Sum
				
				$DeviceBreakdownTable = "
					<h1>Device Counts</h1>
					<table class='table table-striped'>
						<thead>
							<tr>
							<th>Type</th>
							<th>Billed</th>
							<th>Unbilled</th>
							</tr>
						</thead>
						<tbody>"

				foreach ($DeviceType in $FullDeviceCounts) {
					$DeviceBreakdownTable += "
						<tr>
							<th>$($DeviceType.Type)</th>
							<td>$($DeviceType.BilledCount)</td>
							<td>$($DeviceType.UnBilledCount)</td>
						</tr>"
				}
				$DeviceBreakdownTable += "
						<tr style='background-color: #e9e9e9'>
							<th style='background-color: #e9e9e9'><u>Totals</u></th>
							<td><strong><u>$TotalBilled</u></strong></td>
							<td><strong><u>$TotalUnbilled</u><strong></td>
						</tr>"
				$DeviceBreakdownTable += "
						</tbody>
					</table>
					<br />
					<h1>Server Breakdown</h1>
					<table class='table table-striped'>
						<thead>
						<tr>
						<th>Type</th>
						<th>Count</th>
						</tr>
					</thead>
					<tbody>"
				
				foreach ($ServerType in $ServerCounts) {
					$DeviceBreakdownTable += "
						<tr>
							<th>$($ServerType.Type)</th>
							<td>$($ServerType.Count)</td>
						</tr>"
				}	
				$DeviceBreakdownTable += "
						</tbody>
					</table>"

				$ReportEncoded = [System.Convert]::ToBase64String([IO.File]::ReadAllBytes($BillingDeviceList))

				# Get the existing info if it exists (anything that isn't updated will just get deleted, not left alone)
				$BillingFilterID = (Get-ITGlueFlexibleAssetTypes -filter_name $BillingFlexAssetName).data
				if ($BillingFilterID) {
					$FlexAssetBody 	= 
					@{
						type 		= 'flexible-assets'
						attributes	= @{
							traits	= @{

							}
						}
					}
					
					$ExistingFlexAsset = Get-ITGlueFlexibleAssets -filter_flexible_asset_type_id $BillingFilterID.id -filter_organization_id $ITG_ID -include attachments

					if (!$ExistingFlexAsset -or $ExistingFlexAsset.Error) {
						Write-PSFMessage -Level Error -Message "An error occurred trying to get the existing billing flex asset from ITG. Skipping updating billing asset."
						Write-PSFMessage -Level Error -Message $ExistingFlexAsset.Error
					} else {
					
						$ExistingFlexAsset.data = $ExistingFlexAsset.data | Select-Object -First 1

						if ($ExistingFlexAsset -and $ExistingFlexAsset.data.attributes.traits) {
							$ExistingFlexAsset.data.attributes.traits.PSObject.Properties | ForEach-Object {
								if ($_.name -eq "billing-report-user-list" -or $_.name -eq "billing-report-device-list") {
									return
								}
								$property = $_.name
								$FlexAssetBody.attributes.traits.$property = $_.value
							}
						}

						# Add the new data to be uploaded
						$FlexAssetBody.attributes.traits."billed-by" = "Computer"
						$FlexAssetBody.attributes.traits."number-of-billed-computers" = ($FullDeviceCounts | Where-Object { $_.Type -eq "Workstations" }).UnBilledCount
						$FlexAssetBody.attributes.traits."number-of-billed-servers" = ($FullDeviceCounts | Where-Object { $_.Type -eq "Servers" }).BilledCount
						$FlexAssetBody.attributes.traits."device-breakdown" = $DeviceBreakdownTable
						$FlexAssetBody.attributes.traits.Remove("number-of-billed-users")
						$FlexAssetBody.attributes.traits.Remove("user-breakdown")
						$FlexAssetBody.attributes.traits."billing-report-device-list" = @{
							content 	= $ReportEncoded
							file_name 	= $BillingDeviceFileName
						}

						# If billing report is already an attachment, delete so we can replace it
						if ($ExistingFlexAsset -and $ExistingFlexAsset.data.id -and $ExistingFlexAsset.included) {
							$Attachments = $ExistingFlexAsset.included | Where-Object {$_.type -eq 'attachments'}
							if ($Attachments -and ($Attachments | Measure-Object).Count -gt 0 -and $Attachments.attributes) {
								$MonthsAttachment = $Attachments.attributes | Where-Object { $_.name -like $BillingDeviceFileName + '*' -or $_."attachment-file-name" -like $BillingDeviceFileName + '*' }
								if ($MonthsAttachment) {
									$data = @{ 
										'type' = 'attachments'
										'attributes' = @{
											'id' = $MonthsAttachment.id
										}
									}
									Remove-ITGlueAttachments -resource_type 'flexible_assets' -resource_id $ExistingFlexAsset.data.id -data $data | Out-Null
								}
							}
						}

						# Upload
						if ($ExistingFlexAsset -and $ExistingFlexAsset.data.id) {
							Set-ITGlueFlexibleAssets -id $ExistingFlexAsset.data.id -data $FlexAssetBody | Out-Null
							Write-Host "Updated existing $BillingFlexAssetName asset."
							Write-PSFMessage -Level Verbose -Message "Updated existing: $BillingFlexAssetName asset"
						} else {
							$FlexAssetBody.attributes."organization-id" = $ITG_ID
							$FlexAssetBody.attributes."flexible-asset-type-id" = $BillingFilterID.id
							$FlexAssetBody.attributes.traits."billed-by" = "Computer"
							$ExistingFlexAsset = New-ITGlueFlexibleAssets -data $FlexAssetBody
							Write-Host "Uploaded a new $BillingFlexAssetName asset."
							Write-PSFMessage -Level Verbose -Message "Uploaded new: $BillingFlexAssetName asset"
						}

						if ($ExistingFlexAsset -and $ExistingFlexAsset.data.id) {
							$data = @{ 
								'type' = 'attachments'
								'attributes' = @{
									'attachment' = @{
										'content' = $ReportEncoded
										'file_name'	= $BillingDeviceFileName
									}
								}
							}
							New-ITGlueAttachments -resource_type 'flexible_assets' -resource_id $ExistingFlexAsset.data.id -data $data | Out-Null
							Write-Host "Billing report uploaded and attached." -ForegroundColor Green
							Write-PSFMessage -Level Verbose -Message "Uploaded: Billing report"
						}
					}
				} else {
					Write-Host "Something went wrong when trying to find the $BillingFlexAssetName asset type. Could not update IT Glue." -ForegroundColor Red
					Write-PSFMessage -Level Warning -Message "Error. Could not get ID of asset type: $BillingFlexAssetName"
				}
			}

			# Move excel files (if applicable)
			if ($MoveCustomerList.Location -and (Test-Path -Path $MoveCustomerList.Location)) {
				$FileName = "$($Company_Acronym)--Device_List--$($MonthName)_$Year.xlsx"
				$Path = $PSScriptRoot + "\$FileName"
				if ($MoveCustomerList.Copy) {
					Copy-Item -Path $Path -Destination $MoveCustomerList.Location -Force
				} else {
					Move-Item -Path $Path -Destination $MoveCustomerList.Location -Force
				}
				$DeviceAuditSpreadsheetsUpdated = $true
			}
			if ($MoveTechList.Location -and (Test-Path -Path $MoveTechList.Location)) {
				$FileName = "$($Company_Acronym)--Device_List--$($MonthName)_$Year--ForTechs.xlsx"
				$Path = $PSScriptRoot + "\$FileName"
				if ($MoveTechList.Copy) {
					Copy-Item -Path $Path -Destination $MoveTechList.Location -Force
				} else {
					Move-Item -Path $Path -Destination $MoveTechList.Location -Force
				}
				$DeviceAuditSpreadsheetsUpdated = $true
			}
			if ($MoveAssetReport.Location -and (Test-Path -Path $MoveAssetReport.Location)) {
				$FileName = "$($Company_Acronym)--Asset_Report.xlsx"
				$Path = $PSScriptRoot + "\$FileName"
				if ($MoveAssetReport.Copy) {
					Copy-Item -Path $Path -Destination $MoveAssetReport.Location -Force
				} else {
					Move-Item -Path $Path -Destination $MoveAssetReport.Location -Force
				}
				$DeviceAuditSpreadsheetsUpdated = $true
			}
		} else {
			Write-Host "Something went wrong! No devices were found for the billing list." -ForegroundColor Red
		}

		Write-Host "Device list built."
		Write-Host "======================"
	}

	# Update device locations in Autotask/IT Glue
	if ($DOUpdateDeviceLocations -and $ITGConnected -and $ITG_ID) {
		Write-Host "Updating device locations..."
		$WANs = Get-ITGlueFlexibleAssets -page_size 1000 -filter_flexible_asset_type_id $WANFilterID.id -filter_organization_id $ITG_ID
		$LANs = Get-ITGlueFlexibleAssets -page_size 1000 -filter_flexible_asset_type_id $LANFilterID.id -filter_organization_id $ITG_ID
		if (!$WANs -or $WANs.Error) {
			Write-PSFMessage -Level Error -Message "An error occurred trying to get the existing WAN assets from ITG. Exiting..."
			Write-PSFMessage -Level Error -Message $WANs.Error
			$WANs = @()
		}
		if (!$LANs -or $LANs.Error) {
			Write-PSFMessage -Level Error -Message "An error occurred trying to get the existing LAN assets from ITG. Exiting..."
			Write-PSFMessage -Level Error -Message $LANs.Error
			$LANs = @()
		}
		if (!$ITGLocations) {
			$ITGLocations = Get-ITGlueLocations -org_id $ITG_ID
			if (!$ITGLocations -or $ITGLocations.Error) {
				Write-PSFMessage -Level Error -Message "An error occurred trying to get the existing location assets from ITG. Exiting..."
				Write-PSFMessage -Level Error -Message $ITGLocations.Error
				$ITGLocations = @()
			} else {
				$ITGLocations = $ITGLocations.data
			}
		}

		$UpdateOverview = $false
		if ($OverviewFilterID) {
			$UpdateOverview = $true
			$CustomOverviews = Get-ITGlueFlexibleAssets -page_size 1000 -filter_flexible_asset_type_id $OverviewFilterID.id -filter_organization_id $ITG_ID
			$i = 1
			while ($CustomOverviews.links.next) {
				$i++
				$CustomOverviews_Next = Get-ITGlueFlexibleAssets -page_size 1000 -page_number $i -filter_flexible_asset_type_id $OverviewFilterID.id -filter_organization_id $ITG_ID
				if (!$CustomOverviews_Next -or $CustomOverviews_Next.Error) {
					# We got an error querying configurations, wait and try again
					Start-Sleep -Seconds 2
					$CustomOverviews_Next = Get-ITGlueFlexibleAssets -page_size 1000 -page_number $i -filter_flexible_asset_type_id $OverviewFilterID.id -filter_organization_id $ITG_ID
			
					if (!$CustomOverviews_Next -or $CustomOverviews_Next.Error) {
						Write-PSFMessage -Level Error -Message "An error occurred trying to get the existing custom overviews from ITG. Exiting..."
						Write-PSFMessage -Level Error -Message $CustomOverviews_Next.Error
						$UpdateOverview = $false
						break
					}
				}
				$CustomOverviews.data += $CustomOverviews_Next.data
				$CustomOverviews.links = $CustomOverviews_Next.links
			}

			if ($CustomOverviews -and $CustomOverviews.data) {
				$WANCustomOverviews = $CustomOverviews.data | Where-Object { $_.attributes.name -like "WAN: *" }
				$LANCustomOverviews = $CustomOverviews.data | Where-Object { $_.attributes.name -like "LAN: *" }
			} else {
				$UpdateOverview = $false
			}
		}
		$IPRegex = "\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(-(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)?)?(\/[1-3][0-9])?\b"

		if ($LANs -and $LANs.data) {
			$LANs = $LANs.data
		}

		if ($WANs -and $WANs.data -and ($WANs.data | Measure-Object).Count -gt 0 -and $ITG_Devices -and $ITGLocations) {
			$WANs = $WANs.data

			$LocationIPs = @()
			$LANIPs = @{}

			foreach ($Location in $ITGLocations) {
				$LocationLANs = $LANs | Where-Object { $_.attributes.traits.'location-s'.values.id -contains $Location.id }
				$LocationWANs = @()
				$LocationWANs += $WANs | Where-Object { $_.attributes.traits.'location-s'.values.id -contains $Location.id }
				if ($LocationLANs) {
					$LocationWANs += $WANs | Where-Object { $_.id -in $LocationLANs.attributes.traits.'internet-wan'.values.id }	
				}
				$LocationWANs = $LocationWANs | Sort-Object | Get-Unique -AsString

				if (!$LocationWANs) {
					continue
				}

				$IPs_Parsed = @() # All of locations IPs
				$IPs_To_WAN = @{}
				foreach ($WAN in $LocationWANs) {
					$IPAddressInfo = $WAN.attributes.traits.'ip-address-es'
					$IPAddressInfo = $IPAddressInfo -replace [char]0x00a0,' '
					$IPHTML = ""
		
					# Parse the html on the WAN page
					if ($IPAddressInfo -like "*<table>*") {
						$HTML = New-Object -Com "HTMLFile"
						try {
							# This works in PowerShell with Office installed
							$HTML.IHTMLDocument2_write($IPAddressInfo)
						} catch {
							# This works when Office is not installed    
							$src = [System.Text.Encoding]::Unicode.GetBytes($IPAddressInfo)
							$HTML.write($src)
						}
		
						$TableData = $HTML.all | Where-Object { $_.tagname -eq 'td' }
						$TableHeaders = $TableData | Where-Object { $_.innerHtml -like "*<strong>*</strong>*" }
						$TableData = $TableData | Where-Object { $_.innerHtml -notlike "*<strong>*</strong>*" }
		
						$ColCount = $TableHeaders.Count
						if (!$ColCount) {
							$ColCount = $TableData.Count
						}
						for ($i = 0; $i -le $TableData.count; $i++) {
							$Column = $i % $ColCount
							if ($TableHeaders -and $TableHeaders[$Column]) {
								$Header = $TableHeaders[$Column].innerHTML
								if ($Header -like "*DNS*" -or $Header -like "*Subnet*") {
									continue
								}
							}
							$IPHTML += "`n$($TableData[$i].innerHTML)"
						}
					} elseif ($IPAddressInfo -like "*:*") {
						
						if ($IPAddressInfo -match "(^|>)(External )?IP(<.*>)?:?(<.*>)? *$IPRegex *?($|<)" -and $IPAddressInfo -match "Subnet ?(Mask)?(<.*>)?:?(<.*>)? *($IPRegex)") {
							$SubnetMask = $Matches[4]
							if ($SubnetMask) {
								$CidrRange = Convert-SubnetMaskToCidr $SubnetMask
								if ($CidrRange) {
									$IPAddressInfo -match "(^|>)(External )?IP(<.*>)?:?(<.*>)? *$IPRegex *?($|<)"
									if ($Matches[0] -notlike "*-*" -and $Matches[0] -notlike "*/*") { # Ignore if its already an IP range or cidr range
										$IPAddressInfo = $IPAddressInfo -replace "(?<start>(^|>)(External )?IP(<.*>)?:?(<.*>)? *)(?<ip>$IPRegex)(?<end> *?($|<))", ('${start}${ip}/' + $CidrRange + '${end}')
									}
								}
							}
						}
						$IPHTML = $IPAddressInfo -replace "Subnet ?(Mask)?(<.*>)?:?(<.*>)? *$IPRegex", '' -replace "DNS( IP)?(v4|v6)?( \d)?(<.*>)?:?(<.*>)? *$IPRegex", ''
					} else {
						$IPHTML = $IPAddressInfo
					}
		
					# Find all IP's in the html, parse ranges and masks if needed, then map them to their locations
					$Matches = [RegEx]::Matches($IPHTML, $IPRegex)

					if ($Matches -and $Matches.value) {
						$IPs = @($Matches.Value)
						foreach ($IP in $IPs) {
							$FoundIPs = @()
							if ($IP -like "*-*" -and $IP -like "*/*") {
								$IP = $IP -replace '(\/[1-3][0-9])$', ''
							}
							if ($IP -like "*-*") {
								$IPRange = $IP -split '-'
								$Octets = $IPRange[0] -split '\.'
								$RangeFrom = $Octets[3]
								$RangeTo = $IPRange[1]
								$AllEndingOctets = $RangeFrom..$RangeTo
		
								foreach ($EndingOctet in $AllEndingOctets) {
									$FoundIPs += "$($Octets[0]).$($Octets[1]).$($Octets[2]).$($EndingOctet)"
								}
							} elseif ($IP -like "*/*") {
								$IPRange = Get-Subnet $IP
								$FoundIPs += @($IPRange.IPAddress.IPAddressToString)
								$IPRange.HostAddresses | ForEach-Object {
									$FoundIPs += $_
								}
								$FoundIPs += $IPRange.BroadcastAddress.IPAddressToString
							} else {
								$FoundIPs += $IP
							}

							$IPs_Parsed += $FoundIPs
							
							foreach ($FoundIP in $FoundIPs) {
								if (!$IPs_To_WAN[$FoundIP]) {
									$IPs_To_WAN[$FoundIP] = @()
								}
								$IPs_To_WAN[$FoundIP] += $WAN.id
							}
						}
					}
				}

				$InternalIPs = @()
				$ValidLANs = @()
				if ($LocationLANs) {
					foreach ($LAN in $LocationLANs) {
						if (!$LANIPs[$LAN.id]) {
							$LANIPs[$LAN.id] = @()
							$Subnets = $LAN.attributes.traits.subnet
							$IPMatches = [RegEx]::Matches($Subnets, $IPRegex)

							if ($IPMatches -and $IPMatches.value) {
								$SubnetIPs = @($IPMatches.value)
								foreach ($SubnetIP in $SubnetIPs) {
									$IPSubnet = Get-Subnet $SubnetIP
									$ValidLANs += $LAN.id
									$IPSubnet.HostAddresses | ForEach-Object {
										$LANIPs[$LAN.id] += $_
										$InternalIPs += $_
									}
								}
							}
						} else {
							$InternalIPs += $LANIPs[$LAN.id]
						}
					}
				}
				$ValidLANs = $ValidLANs | Select-Object -Unique

				if (!$IPs_Parsed) {
					continue
				}
				
				$AutotaskLocation = $false
				if ($AutotaskConnected -and $Autotask_Locations) {
					$AutotaskLocation = $Autotask_Locations | Where-Object { $_.name -like $Location.attributes.name }
					if (!$AutotaskLocation) {
						$AutotaskLocation = $Autotask_Locations | Where-Object {
							$_.address1 -like $Location.attributes.'address-1' -and
							$_.address2 -like $Location.attributes.'address-2' -and
							$_.city -like $Location.attributes.city -and
							$_.postalCode -like $Location.attributes.'postal-code' -and
							$_.state -like $Location.attributes.'region-name' -and
							($_.phone -replace "[^0-9]") -like $Location.attributes.phone
						}
					}
				}

				$LocationIPs += [PSCustomObject]@{
					ExternalIPs = $IPs_Parsed | Sort-Object -Unique
					InternalIPs = $InternalIPs | Sort-Object -Unique
					ITGLocation = $Location.id
					AutotaskLocation = if ($AutotaskLocation) { $AutotaskLocation.id } else { $false }
					WANs = @($LocationWANs.id)
					LANs = @($ValidLANs)
					IPs_To_WAN = $($IPs_To_WAN)
				}
			}

			if ($LocationIPsLocation) {
				if (!(Test-Path -Path $LocationIPsLocation)) {
					New-Item -ItemType Directory -Force -Path $LocationIPsLocation | Out-Null
				}

				$LocationIPsPath = "$($LocationIPsLocation)\$($Company_Acronym)_location_ips.json"
				$LocationIPs | ConvertTo-Json | Out-File -FilePath $LocationIPsPath
			}

			# Prep overview lists
			$WANDevices = @{}
			$LANDevices = @{}
			foreach ($LocationInfo in $LocationIPs) {
				foreach ($WAN in $LocationInfo.WANs) {
					if (!$WANDevices[$WAN]) {
						$WANDevices[$WAN] = @()
					}
				}
				foreach ($LAN in $LocationInfo.LANs) {
					if (!$LANDevices[$LAN]) {
						$LANDevices[$LAN] = @()
					}
				}
			}

			# We have all the locations mapped to ip lists, lets go through the list of devices and determine each one's location
			if ($LocationIPs) {
				$i = 0
				$MatchedDeviceCount = ($MatchedDevices | Measure-Object).Count
				foreach ($MatchedDevice in $MatchedDevices) {
					$i++
					[int]$PercentComplete = ($i / $MatchedDeviceCount * 100)
					$Hostname = @($MatchedDevice.sc_hostname + $MatchedDevice.rmm_hostname + $MatchedDevice.sophos_hostname + $MatchedDevice.itg_hostname + $MatchedDevice.autotask_hostname) | Select-Object -First 1
					Write-Progress -Activity "Updating Device Locations" -PercentComplete $PercentComplete -Status ("Working - " + $PercentComplete + "% (Checking: $Hostname)")

					if (!$MatchedDevice.itg_matches -and (!$MatchedDevice.autotask_matches -or !$MatchedDevice.rmm_matches)) {
						continue
					}

					$RMMDevice = @()
					$ExternalIP = $false
					foreach ($DeviceID in $MatchedDevice.rmm_matches) {
						$RMMDevice += $RMM_DevicesHash[$DeviceID]
					}
					if ($RMMDevice) {
						$ExternalIP = @($RMMDevice.extIpAddress)
						$InternalIP = @($RMMDevice.intIpAddress)
					} else {
						$AutotaskDevice = @()
						foreach ($DeviceID in $MatchedDevice.autotask_matches) {
							$AutotaskDevice += $Autotask_DevicesHash[$DeviceID]
						}
						if ($AutotaskDevice) {
							$ExternalIP = @($AutotaskDevice.rmmDeviceAuditExternalIPAddress)
							$InternalIP = @($AutotaskDevice.rmmDeviceAuditIPAddress)
						}
					}

					if (!$ExternalIP) {
						continue
					}

					$PossibleLocations = @()
					$ExternalIP | ForEach-Object {
						$IP = $_;
						$PossibleLocations += $LocationIPs | Where-Object { $_.ExternalIPs -contains $IP }
					}

					if (($PossibleLocations.ITGLocation | Select-Object -Unique | Measure-Object).Count -gt 1) {
						# if more than 1 possible location, try narrowing down by internal ip
						$PossibleLocations_IntFiltered = @()
						$InternalIP | ForEach-Object {
							$IP = $_;
							$PossibleLocations_IntFiltered += $PossibleLocations | Where-Object { $_.InternalIPs -contains $IP }
						}
						if (($PossibleLocations_IntFiltered | Measure-Object).Count -gt 0) {
							$PossibleLocations = $PossibleLocations_IntFiltered
						}
					}

					$PossibleLocations = $PossibleLocations | Where-Object { $_.AutotaskLocation -or $_.ITGLocation }

					if (!$PossibleLocations) {
						continue
					}
					
					# Populate WAN and LAN device lists for custom overviews
					foreach ($ITG_DeviceID in $MatchedDevice.itg_matches) {
						$ITGMatch = $ITG_DevicesHash[$ITG_DeviceID]

						# If currently set location is in $PossibleLocations, use existing location
						if ($ITGMatch.attributes.'location-id' -and $ITGMatch.attributes.'location-id' -in $PossibleLocations.ITGLocation) {
							$ExistingLocation = $PossibleLocations | Where-Object { $ITGMatch.'location-id' -in $_.Location } | Select-Object -First 1
							if ($ExistingLocation.WANs) {
								$DeviceWANs = @()
								foreach ($Device_ExtIP in $ExternalIP) {
									$DeviceWANs += $ExistingLocation.IPs_To_WAN[$Device_ExtIP]
								}
								$DeviceWANs = $DeviceWANs | Sort-Object -Unique
								foreach ($WAN_ID in $DeviceWANs) {
									$WANDevices[$WAN_ID] += $MatchedDevice.id
								}
							}
						} else {
							# Otherwise use the newly chosen location
							$NewLocation = $PossibleLocations | Select-Object -First 1
							if ($NewLocation.WANs) {
								$DeviceWANs = @()
								foreach ($Device_ExtIP in $ExternalIP) {
									$DeviceWANs += $NewLocation.IPs_To_WAN[$Device_ExtIP]
								}
								$DeviceWANs = $DeviceWANs | Sort-Object -Unique
								foreach ($WAN_ID in $DeviceWANs) {
									$WANDevices[$WAN_ID] += $MatchedDevice.id
								}
							}
						}

						# Populate LAN info if applicable
						if ($InternalIP -in $PossibleLocations.InternalIPs) {
							foreach ($LAN_ID in $PossibleLocations.LANs) {
								$AllowedIPs = $LANIPs[$LAN_ID]
								if ($InternalIP -in $AllowedIPs) {
									$LANDevices[$LAN_ID] += $MatchedDevice.id
									break
								}
							}
						}
					}

					# Update locations in Autotask
					if ($AutotaskConnected -and $Autotask_Locations -and $PossibleLocations.AutotaskLocation) {
						foreach ($Autotask_DeviceID in $MatchedDevice.autotask_matches) {
							$AutotaskMatch = $Autotask_DevicesHash[$Autotask_DeviceID]
							# If currently set location is in $PossibleLocations, dont update
							if ($AutotaskMatch.companyLocationID -in $PossibleLocations.AutotaskLocation) {
								continue
							}

							# Update location
							Write-Progress -Activity "Updating Device Locations" -PercentComplete $PercentComplete -Status ("Working - " + $PercentComplete + "% (Updating in Autotask: $Hostname)")
							$NewLocation = $PossibleLocations | Select-Object -First 1 # if multiple, just use the first

							$ConfigurationUpdate = 
							[PSCustomObject]@{
								companyLocationID = $NewLocation.AutotaskLocation
							}

							Set-AutotaskAPIResource -Resource ConfigurationItems -ID $Autotask_DeviceID -body $ConfigurationUpdate | Out-Null
						}
					}

					# Update Locations in ITG
					if ($PossibleLocations.ITGLocation) {
						foreach ($ITG_DeviceID in $MatchedDevice.itg_matches) {
							$ITGMatch = $ITG_DevicesHash[$ITG_DeviceID]
							$DeviceLocationsUpdateRan = $true
							# If currently set location is in $PossibleLocations, dont update
							if ($ITGMatch.attributes.'location-id' -in $PossibleLocations.ITGLocation) {
								continue
							}
							# If the device is synced with autotask then we cannot update ITG directly, instead this will sync down from Autotask which we updated above
							if ($ITGMatch.attributes.'psa-integration' -and $ITGMatch.attributes.'psa-integration' -ne 'disabled') {
								continue
							}

							# Update location
							Write-Progress -Activity "Updating Device Locations" -PercentComplete $PercentComplete -Status ("Working - " + $PercentComplete + "% (Updating in ITG: $Hostname)")
							$NewLocation = $PossibleLocations | Select-Object -First 1 # if multiple, just use the first

							$ConfigurationUpdate = @{
								'type' = 'configurations'
								'attributes' = @{
									'location-id' = $NewLocation.ITGLocation
								}
							}

							Set-ITGlueConfigurations -id $ITG_DeviceID -data $ConfigurationUpdate | Out-Null
						}
					}
				}
				Write-Progress -Activity "Updating Device Locations" -Status "Ready" -Completed
			}

			if ($WAN_LAN_HistoryLocation) {
				if (!(Test-Path -Path $WAN_LAN_HistoryLocation)) {
					New-Item -ItemType Directory -Force -Path $WAN_LAN_HistoryLocation | Out-Null
				}
			}

			# Create custom WAN & LAN overviews
			if ($WANDevices -and $UpdateOverview) {
				foreach ($WAN_ID in $WANDevices.keys) {
					$WAN = $WANs | Where-Object { $_.id -eq $WAN_ID }
					$Title = "WAN: Seen Devices - $($WAN.attributes.traits.label)"
					$ExistingOverview = $WANCustomOverviews | Where-Object { $_.attributes.traits.label -like $Title -or $_.attributes.traits.overview -like "*WAN ID: '$WAN_ID'*" } | Sort-Object -Property {$_.attributes.'updated-at'} -Descending | Select-Object -First 1

					$DeviceTable = @()
					$DeviceHistory = @()

					# Get previously seen devices first
					$HistoryPath = "$($WAN_LAN_HistoryLocation)\$($Company_Acronym)_wan_$($WAN_ID)_history.json"
					if (Test-Path $HistoryPath) {
						$PreviousWANHistory = $true
						$DevicePreviousHistory = Get-Content -Path $HistoryPath -Raw | ConvertFrom-Json
					}

					# get list of recently seen devices
					foreach ($MatchID in $WANDevices.Item($WAN_ID)) {
						$MatchedDevice = $MatchedDevicesHash[$MatchID]
						$Hostname = @($MatchedDevice.sc_hostname + $MatchedDevice.rmm_hostname + $MatchedDevice.sophos_hostname + $MatchedDevice.itg_hostname + $MatchedDevice.autotask_hostname) | Select-Object -First 1
						$ITG_DeviceID = $null
						if (($MatchedDevice.itg_matches | Measure-Object).Count -gt 0) {
							$ITG_Device = $ITG_DevicesHash[($MatchedDevice.itg_matches | Select-Object -First 1)]
							$HostnameAndURL = "<a href='$($ITG_Device.attributes.'resource-url')'>$Hostname</a>"
							$ITG_DeviceID = $ITG_Device.id
						}

						if ($PreviousWANHistory -and ($Hostname -in $DevicePreviousHistory -or ($ITG_DeviceID -and $ITG_DeviceID -in $DevicePreviousHistory.DeviceID))) {
							# Remove devices from previously seen if in current list
							$DevicePreviousHistory = $DevicePreviousHistory | Where-Object { $_.DeviceName -ne $Hostname }
							if ($ITG_DeviceID) {
								$DevicePreviousHistory = $DevicePreviousHistory | Where-Object { $_.DeviceID -ne $ITG_DeviceID }
							}
						}

						if ($Hostname -in $DeviceHistory.DeviceName) {
							continue
						}

						$ActivityComparison = $MatchedDevice.activity_comparison
						$Activity = $ActivityComparison.Values | Sort-Object last_active
						$LastSeen = ''
						$LastSeenUTC = $null
						if (($Activity | Measure-Object).count -gt 1) {
							$LastIndex = ($Activity | Measure-Object).count-1
							$LastSeen = [DateTime]($Activity.last_active | Sort-Object | Select-Object -Last 1)
							$LastSeenUTC = $LastSeen.ToUniversalTime()
						}

						$Row = [PSCustomObject]@{
							'DeviceName' = $Hostname
							'Device' = $HostnameAndURL
							'Last Seen' = $LastSeen
						}
						$DeviceTable += $Row

						$DeviceHistory += [PSCustomObject]@{
							'DeviceID' = $ITG_DeviceID
							'DeviceName' = $Hostname
							'LastSeen' = $LastSeenUTC
							'Type' = 'Current'
						}
					}

					if (!$DeviceTable) {
						$DeviceTable = "None seen yet."
						$Overview = "<p>None seen yet.</p>"
					} else {
						$DeviceTable = ($DeviceTable | Sort-Object -Property  @{expression = 'Last Seen'; descending = $true}, @{expression = 'DeviceName'; descending = $false})
						$Overview = $DeviceTable | Select-Object 'Device', 'Last Seen' | ConvertTo-Html -Fragment
					}

					# Create previous device history table
					if ($PreviousWANHistory -and ($DevicePreviousHistory | Measure-Object).Count -gt 0) {
						$DeviceHistoryTable = @()
						foreach ($Device in $DevicePreviousHistory) {
							if ($Device.DeviceID) {
								$MatchedDevice = $MatchedDevices | Where-Object { $_.itg_matches -contains $Device.DeviceID } | Select-Object -First 1
							} else {
								$MatchedDevice = $MatchedDevices | Where-Object { $_.itg_hostname -contains $Device.DeviceName } | Select-Object -First 1
							}

							if (!$MatchedDevice) {
								continue
							}

							$Hostname = @($MatchedDevice.sc_hostname + $MatchedDevice.rmm_hostname + $MatchedDevice.sophos_hostname + $MatchedDevice.itg_hostname + $MatchedDevice.autotask_hostname) | Select-Object -First 1
							$ITG_Device = $ITG_DevicesHash[($MatchedDevice.itg_matches | Select-Object -First 1)]
							$HostnameAndURL = "<a href='$($ITG_Device.attributes.'resource-url')'>$Hostname</a>"

							if ($Hostname -in $DeviceHistory.DeviceName -or ($Device.DeviceID -and $Device.DeviceID -in $DeviceHistory.DeviceID)) {
								continue
							}

							$Device.LastSeen = $Device.LastSeen -as [DateTime];

							$Row = [PSCustomObject]@{
								'DeviceName' = $Hostname
								'Device' = $HostnameAndURL
								'Last Seen' = if ($Device.LastSeen) { $Device.LastSeen.ToLocalTime() } else { $false }
							}
							$DeviceHistoryTable += $Row

							$DeviceHistory += [PSCustomObject]@{
								'DeviceID' = $ITG_Device.id
								'DeviceName' = $Hostname
								'LastSeen' = $Device.LastSeen
								'Type' = 'Previous'
							}
						}
						$DeviceHistoryTable = ($DeviceHistoryTable | Sort-Object -Property  @{expression = 'Last Seen'; descending = $true}, @{expression = 'DeviceName'; descending = $false})

						if ($DeviceHistoryTable) {
							$Overview += "`n`n<h3>Previously Seen Devices</h3> `n"
							$Overview += $DeviceHistoryTable | Select-Object 'Device', 'Last Seen' | ConvertTo-Html -Fragment
						}
					}

					$Overview += "`n<p>WAN ID: '$WAN_ID'</p>"

					# Export devices to json file so we can track devices seen previously in this WAN
					if ($WAN_LAN_HistoryLocation) {
						$HistoryPath = "$($WAN_LAN_HistoryLocation)\$($Company_Acronym)_wan_$($WAN_ID)_history.json"
						$DeviceHistory | ConvertTo-Json | Out-File -FilePath $HistoryPath
						Write-Host "Exported the wan device history: $($WAN.attributes.traits.label)."
					}

					if ($ExistingOverview) {
						# Update existing in ITG
						$FlexAssetBody = 
						@{
							type = 'flexible-assets'
							attributes = @{
								traits = @{
									"name" = $Title
									"overview" = [System.Web.HttpUtility]::HtmlDecode($Overview)
								}
							}
						}
						Set-ITGlueFlexibleAssets -id $ExistingOverview.id -data $FlexAssetBody
						$OverviewID = $ExistingOverview.id
						$ExistingOverview = Get-ITGlueFlexibleAssets -id $OverviewID -include related_items
					} else {
						# Upload new to ITG
						$FlexAssetBody = 
						@{
							type = 'flexible-assets'
							attributes = @{
								'organization-id' = $ITG_ID
								'flexible-asset-type-id' = $OverviewFilterID.id
								traits = @{
									"name" = $Title
									"overview" = [System.Web.HttpUtility]::HtmlDecode($Overview)
								}
							}
						}
						$New_WANOverview = New-ITGlueFlexibleAssets -data $FlexAssetBody
						$OverviewID = $New_WANOverview.data.id
					}

					# Add related items
					$RelatedItemsBody = @()
					$RelatedItemsBody +=
					@{
						type = 'related_items'
						attributes = @{
							'destination_id' = $WAN_ID
							'destination_type' = "Flexible Asset"
						}
					}
					foreach ($Device in $DeviceHistory) {
						$ITG_Device = $ITG_DevicesHash[$Device.DeviceID]

						$Note = ''
						if ($Device.Type -eq 'Current') {
							$Note = 'Current WAN'
						} else {
							$Note = 'Previously seen on WAN'
						}

						if ($ExistingOverview.included -and $ITG_Device.id -in $ExistingOverview.included.attributes.'resource-id') {
							$RelatedItem = $ExistingOverview.included | Where-Object { $_.attributes.'resource-id' -contains $ITG_Device.id }
							if ($RelatedItem.attributes.notes -like $Note) {
								continue
							} else {
								# Update related item
								$Delete_RelatedItemsBody = @()
								$RelatedItem.id | ForEach-Object {
									$Delete_RelatedItemsBody +=
									@{
										type = 'related_items'
										attributes = @{
											'id' = $_
										}
									}
								}
								Remove-ITGlueRelatedItems -resource_type 'flexible_assets' -resource_id $OverviewID -data $Delete_RelatedItemsBody
							}
						}

						if ($ITG_Device -and $ITG_Device.id) {
							$RelatedItemsBody +=
							@{
								type = 'related_items'
								attributes = @{
									'destination_id' = $ITG_Device.id
									'destination_type' = "Configuration"
									'notes' = $Note
								}
							}
						}
					}

					New-ITGlueRelatedItems -resource_type 'flexible_assets' -resource_id $OverviewID -data $RelatedItemsBody
				}
			}

			if ($LANDevices -and $UpdateOverview) {
				foreach ($LAN_ID in $LANDevices.keys) {
					$LAN = $LANs | Where-Object { $_.id -eq $LAN_ID }
					$Title = "LAN: Seen Devices - $($LAN.attributes.traits.name)"
					$ExistingOverview = $LANCustomOverviews | Where-Object { $_.attributes.traits.name -like $Title -or $_.attributes.traits.overview -like "*LAN ID: '$LAN_ID'*" } | Sort-Object -Property {$_.attributes.'updated-at'} -Descending | Select-Object -First 1
					$DeviceTable = @()
					$DeviceHistory = @()

					# Get previously seen devices first
					$HistoryPath = "$($WAN_LAN_HistoryLocation)\$($Company_Acronym)_lan_$($LAN_ID)_history.json"
					if (Test-Path $HistoryPath) {
						$PreviousLANHistory = $true
						$DevicePreviousHistory = Get-Content -Path $HistoryPath -Raw | ConvertFrom-Json
					}

					# get list of recently seen devices
					foreach ($MatchID in $LANDevices.Item($LAN_ID)) {
						$MatchedDevice = $MatchedDevicesHash[$MatchID]
						$Hostname = @($MatchedDevice.sc_hostname + $MatchedDevice.rmm_hostname + $MatchedDevice.sophos_hostname + $MatchedDevice.itg_hostname + $MatchedDevice.autotask_hostname) | Select-Object -First 1
						$ITG_DeviceID = $null
						if (($MatchedDevice.itg_matches | Measure-Object).Count -gt 0) {
							$ITG_Device = $ITG_DevicesHash[($MatchedDevice.itg_matches | Select-Object -First 1)]
							$HostnameAndURL = "<a href='$($ITG_Device.attributes.'resource-url')'>$Hostname</a>"
							$ITG_DeviceID = $ITG_Device.id
						}

						if ($PreviousLANHistory -and ($Hostname -in $DevicePreviousHistory -or ($ITG_DeviceID -and $ITG_DeviceID -in $DevicePreviousHistory.DeviceID))) {
							# Remove devices from previously seen if in current list
							$DevicePreviousHistory = $DevicePreviousHistory | Where-Object { $_.DeviceName -ne $Hostname }
							if ($ITG_DeviceID) {
								$DevicePreviousHistory = $DevicePreviousHistory | Where-Object { $_.DeviceID -ne $ITG_DeviceID }
							}
						}

						if ($Hostname -in $DeviceHistory.DeviceName) {
							continue
						}

						$ActivityComparison = $MatchedDevice.activity_comparison
						$Activity = $ActivityComparison.Values | Sort-Object last_active
						$LastSeen = ''
						if (($Activity | Measure-Object).count -gt 1) {
							$LastIndex = ($Activity | Measure-Object).count-1
							$LastSeen = [DateTime]($Activity.last_active | Sort-Object | Select-Object -Last 1)
						}

						$Row = [PSCustomObject]@{
							'DeviceName' = $Hostname
							'Device' = $HostnameAndURL
							'Last Seen' = $LastSeen
						}
						$DeviceTable += $Row

						$DeviceHistory += [PSCustomObject]@{
							'DeviceID' = $ITG_DeviceID
							'DeviceName' = $Hostname
							'LastSeen' = $LastSeen.ToUniversalTime()
							'Type' = 'Current'
						}
					}

					if (!$DeviceTable) {
						$DeviceTable = "None seen yet."
						$Overview = "<p>None seen yet.</p>"
					} else {
						$DeviceTable = ($DeviceTable | Sort-Object -Property  @{expression = 'Last Seen'; descending = $true}, @{expression = 'DeviceName'; descending = $false})
						$Overview = $DeviceTable | Select-Object 'Device', 'Last Seen' | ConvertTo-Html -Fragment
					}

					# Create previous device history table
					if ($PreviousLANHistory -and ($DevicePreviousHistory | Measure-Object).Count -gt 0) {
						$DeviceHistoryTable = @()
						foreach ($Device in $DevicePreviousHistory) {
							if ($Device.DeviceID) {
								$MatchedDevice = $MatchedDevices | Where-Object { $_.itg_matches -contains $Device.DeviceID } | Select-Object -First 1
							} else {
								$MatchedDevice = $MatchedDevices | Where-Object { $_.itg_hostname -contains $Device.DeviceName } | Select-Object -First 1
							}

							if (!$MatchedDevice) {
								continue
							}

							$Hostname = @($MatchedDevice.sc_hostname + $MatchedDevice.rmm_hostname + $MatchedDevice.sophos_hostname + $MatchedDevice.itg_hostname + $MatchedDevice.autotask_hostname) | Select-Object -First 1
							$ITG_Device = $ITG_DevicesHash[($MatchedDevice.itg_matches | Select-Object -First 1)]
							$HostnameAndURL = "<a href='$($ITG_Device.attributes.'resource-url')'>$Hostname</a>"

							if ($Hostname -in $DeviceHistory.DeviceName -or ($Device.DeviceID -and $Device.DeviceID -in $DeviceHistory.DeviceID)) {
								continue
							}

							$Device.LastSeen = $Device.LastSeen -as [DateTime];

							$Row = [PSCustomObject]@{
								'DeviceName' = $Hostname
								'Device' = $HostnameAndURL
								'Last Seen' = if ($Device.LastSeen) { $Device.LastSeen.ToLocalTime() } else { $false }
							}
							$DeviceHistoryTable += $Row

							$DeviceHistory += [PSCustomObject]@{
								'DeviceID' = $ITG_Device.id
								'DeviceName' = $Hostname
								'LastSeen' = $Device.LastSeen
								'Type' = 'Previous'
							}
						}
						$DeviceHistoryTable = ($DeviceHistoryTable | Sort-Object -Property  @{expression = 'Last Seen'; descending = $true}, @{expression = 'DeviceName'; descending = $false})

						if ($DeviceHistoryTable) {
							$Overview += "`n`n<h3>Previously Seen Devices</h3> `n"
							$Overview += $DeviceHistoryTable | Select-Object 'Device', 'Last Seen' | ConvertTo-Html -Fragment
						}
					}

					$Overview += "`n<p>LAN ID: '$LAN_ID'</p>"

					# Export devices to json file so we can track devices seen previously in this WAN
					if ($WAN_LAN_HistoryLocation) {
						$HistoryPath = "$($WAN_LAN_HistoryLocation)\$($Company_Acronym)_lan_$($LAN_ID)_history.json"
						$DeviceHistory | ConvertTo-Json | Out-File -FilePath $HistoryPath
						Write-Host "Exported the lan device history: $($LAN.attributes.traits.name)."
					}

					if ($ExistingOverview) {
						# Update existing in ITG
						$FlexAssetBody = 
						@{
							type = 'flexible-assets'
							attributes = @{
								traits = @{
									"name" = $Title
									"overview" = [System.Web.HttpUtility]::HtmlDecode($Overview)
								}
							}
						}
						Set-ITGlueFlexibleAssets -id $ExistingOverview.id -data $FlexAssetBody
						$OverviewID = $ExistingOverview.id
						$ExistingOverview = Get-ITGlueFlexibleAssets -id $OverviewID -include related_items
					} else {
						# Upload new to ITG
						$FlexAssetBody = 
						@{
							type = 'flexible-assets'
							attributes = @{
								'organization-id' = $ITG_ID
								'flexible-asset-type-id' = $OverviewFilterID.id
								traits = @{
									"name" = $Title
									"overview" = [System.Web.HttpUtility]::HtmlDecode($Overview)
								}
							}
						}
						$New_LANOverview = New-ITGlueFlexibleAssets -data $FlexAssetBody
						$OverviewID = $New_LANOverview.data.id
					}
			
					# Add related items
					$RelatedItemsBody = @()
					$RelatedItemsBody +=
					@{
						type = 'related_items'
						attributes = @{
							'destination_id' = $LAN_ID
							'destination_type' = "Flexible Asset"
						}
					}
					foreach ($Device in $DeviceHistory) {
						$ITG_Device = $ITG_DevicesHash[$Device.DeviceID]

						$Note = ''
						if ($Device.Type -eq 'Current') {
							$Note = 'Current LAN'
						} else {
							$Note = 'Previously seen on LAN'
						}

						if ($ExistingOverview.included -and $ITG_Device.id -in $ExistingOverview.included.attributes.'resource-id') {
							$RelatedItem = $ExistingOverview.included | Where-Object { $_.attributes.'resource-id' -contains $ITG_Device.id }
							if ($RelatedItem.attributes.notes -like $Note) {
								continue
							}
						}

						if ($ITG_Device -and $ITG_Device.id) {
							$RelatedItemsBody +=
							@{
								type = 'related_items'
								attributes = @{
									'destination_id' = $ITG_Device.id
									'destination_type' = "Configuration"
									'notes' = $Note
								}
							}
						}
					}

					New-ITGlueRelatedItems -resource_type 'flexible_assets' -resource_id $OverviewID -data $RelatedItemsBody
				}
			}
		}

		Write-Host "Device locations updated."
		Write-Host "======================"
	}

	# Update / Create the "Scripts - Last Run" ITG page which shows when the device audit (and other scripts) last ran
	if ($LastUpdatedUpdater_APIURL -and $ITG_ID) {
		if ($ScriptsLastRunFilterID) {
			$LastUpdatedPage = Get-ITGlueFlexibleAssets -filter_flexible_asset_type_id $ScriptsLastRunFilterID.id -filter_organization_id $ITG_ID
		
			if (!$LastUpdatedPage -or !$LastUpdatedPage.data) {
				# Upload new to ITG
				$FlexAssetBody = 
				@{
					type = 'flexible-assets'
					attributes = @{
						'organization-id' = $ITG_ID
						'flexible-asset-type-id' = $ScriptsLastRunFilterID.id
						traits = @{
							"name" = "Scripts - Last Run"
							"current-version" = "N/A"
						}
					}
				}
				$LastUpdatedPage = New-ITGlueFlexibleAssets -data $FlexAssetBody
				Write-Host "Created a new 'Scripts - Last Run' page."
			}
		}

		$Headers = @{
			"x-api-key" = $ITGAPIKey.Key
		}
		$Body = @{
			"apiurl" = $ITGAPIKey.Url
			"itgOrgID" = $ITG_ID
			"HostDevice" = $env:computername
		}

		# Update asset with last run times for the device audit
		if ($DeviceIssueCheckRan) {
			$Body.Add("device-cleanup", (Get-Date).ToString("yyyy-MM-dd"))
		}
		if ($DeviceBillingUpdateRan) {
			$Body.Add("billing-update-da", (Get-Date).ToString("yyyy-MM-dd"))
		}
		if ($DeviceUsageUpdateRan) {
			$Body.Add("device-usage", (Get-Date).ToString("yyyy-MM-dd"))
		}
		if ($DeviceLocationsUpdateRan) {
			$Body.Add("device-locations", (Get-Date).ToString("yyyy-MM-dd"))
		}
		if ($MonthlyStatsUpdated) {
			$Body.Add("monthly-stats-rollup", (Get-Date).ToString("yyyy-MM-dd"))
		}
		if ($DeviceUsersUpdateRan) {
			$Body.Add("device-users", (Get-Date).ToString("yyyy-MM-dd"))
		}

		$Params = @{
			Method = "Post"
			Uri = $LastUpdatedUpdater_APIURL
			Headers = $Headers
			Body = ($Body | ConvertTo-Json)
			ContentType = "application/json"
		}			
		Invoke-RestMethod @Params
	}

}

# If auditing all companies we have created an overview document, lets export an excel doc of it
if ($companies -contains "ALL" -and ($DeviceCount_Overview | Measure-Object).Count -gt 0) {
	$MonthName = (Get-Culture).DateTimeFormat.GetMonthName([int](Get-Date -Format MM))
	$Year = Get-Date -Format yyyy
	$FileName = "Device_Overview--$($MonthName)_$Year.xlsx"
	$Path = $PSScriptRoot + "\$FileName"
	Remove-Item $Path -ErrorAction SilentlyContinue

	$DeviceCount_Overview | Sort-Object -Property Company | 
		Export-Excel $Path -WorksheetName "Device Count Overview" -AutoSize -AutoFilter -NoNumberConversion * -TableName "DeviceOverview" -Title "Device Count Overview" -TitleBold -TitleSize 18 -Now

	if ($MoveOverview.Location -and (Test-Path -Path $MoveOverview.Location)) {
		if ($MoveOverview.Copy) {
			Copy-Item -Path $Path -Destination $MoveOverview.Location -Force
		} else {
			Move-Item -Path $Path -Destination $MoveOverview.Location -Force
		}
		$DeviceAuditSpreadsheetsUpdated = $true
	}
}

# Update the last updated file
if ($DeviceAuditSpreadsheetsUpdated) {
	(Get-Date).ToString() | Out-File -FilePath ($MoveOverview.Location + "\lastUpdated.txt")
}

# Cleanup
Disconnect-MgGraph