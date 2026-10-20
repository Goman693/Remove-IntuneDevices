<#
.SYNOPSIS
    Removes devices from Intune, optionally including Autopilot and Azure AD.

.DESCRIPTION
    - Accepts a CSV file with a "SerialNumber" column, or allows interactive input.
    - Sanitizes serial numbers to prevent Graph query errors.
    - Optionally removes devices from Intune, Autopilot, and Azure AD.
    - Interactive mode prompts for Intune-only or full Intune/Autopilot/Entra removal.
    - Logs all results with automatic log rotation (keeps 5 newest logs).
    - CSV picker automatically opens to the directory containing this script.

.PARAMETER CSVPath
    Path to a CSV file containing a column named SerialNumber.

.PARAMETER AutopilotAAD
    If specified, also removes matching devices from Autopilot and Azure AD.

.PARAMETER Interactive
    Prompts for manual serial number entry instead of reading from a CSV.
    If -AutopilotAAD is not explicitly supplied, prompts for the removal scope.

.NOTES
    Requires the current Microsoft Graph PowerShell SDK and access to the tenant-specific Endpoint Device Removal Tool app registration.
#>

param (
    [Parameter(HelpMessage = "Path to CSV file with column named SerialNumber", Position = 0)]
    [string] $CSVPath,

    [Parameter(HelpMessage = "Also remove devices from Autopilot and Azure AD (True or False)")]
    [switch] $AutopilotAAD,

    [Parameter(HelpMessage = "Interactive mode (True or False)")]
    [switch] $Interactive
)

# --- Determine script directory ---
$ScriptDirectory = if ($PSScriptRoot) {
    $PSScriptRoot
}
else {
    (Get-Location).Path
}

# --- Function: Graphical CSV picker ---
function Get-CsvPath {
    param (
        [string]$Title = "Choose .CSV file with SerialNumber column"
    )

    $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog -Property @{
        InitialDirectory = $ScriptDirectory
        Filter           = "CSV files (*.csv)|*.csv"
        Multiselect      = $False
        Title            = $Title
    }

    $null = $FileBrowser.ShowDialog()
    return $FileBrowser.FileName
}

# --- Load Windows Forms for file picker ---
Add-Type -AssemblyName System.Windows.Forms

# --- Determine mode and get CSV path ---
if (-Not $CSVPath -and -Not $Interactive) {
    $AutopilotAAD = $false

    $CSVPath = Get-CsvPath -Title "CSV to remove from Intune (Cancel for Autopilot/AAD removal). Must have SerialNumber column."

    if (-Not $CSVPath) {
        $AutopilotAAD = $true

        $CSVPath = Get-CsvPath -Title "CSV to remove from Intune, Autopilot, and AzureAD. Must have SerialNumber column."
    }

    # User cancelled both file pickers
    if (-Not $CSVPath) {
        Write-Host "No CSV selected. Nothing to process." -ForegroundColor Yellow
        exit
    }
}

# --- Import CSV or enter serials manually ---
if (-Not $Interactive) {
    try {
        $CSVFile = Get-Item -Path $CSVPath -ErrorAction Stop

        if ($CSVFile.Length -eq 0) {
            Write-Host "CSV is empty. Nothing to process." -ForegroundColor Yellow
            exit
        }

        $ImportedData = Import-Csv -Path $CSVPath -Encoding UTF8 -ErrorAction Stop

        Write-Host "Import successful. Devices will be removed from " -NoNewline

        if ($AutopilotAAD) {
            Write-Host "Intune, Autopilot, and Azure AD" -ForegroundColor Cyan
        }
        else {
            Write-Host "Intune" -ForegroundColor Cyan
        }
    }
    catch {
        Write-Host "Error importing CSV:" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 1
    }
}

if ($Interactive) {
    # If -AutopilotAAD was not explicitly supplied, ask which removal scope to use.
    if (-not $PSBoundParameters.ContainsKey("AutopilotAAD")) {
        Write-Host ""
        Write-Host "Choose removal scope:" -ForegroundColor Cyan
        Write-Host "  [1] Intune only"
        Write-Host "  [2] Intune, Autopilot, and Azure AD"

        do {
            $RemovalChoice = Read-Host "Enter 1 or 2"

            if ($RemovalChoice -notin @("1", "2")) {
                Write-Host "Please enter 1 or 2." -ForegroundColor Yellow
            }
        }
        until ($RemovalChoice -in @("1", "2"))

        $AutopilotAAD = ($RemovalChoice -eq "2")
    }

    Write-Host ""
    Write-Host "Interactive mode enabled. Devices will be removed from " -NoNewline

    if ($AutopilotAAD) {
        Write-Host "Intune, Autopilot, and Azure AD" -ForegroundColor Cyan
    }
    else {
        Write-Host "Intune" -ForegroundColor Cyan
    }

    Write-Host "Enter serial numbers to remove. Press Enter on a blank line to finish."

    $ImportedData = @()

    while ($true) {
        $SerialNumber = Read-Host "Enter serial number"

        if ([string]::IsNullOrWhiteSpace($SerialNumber)) {
            break
        }

        $ImportedData += [PSCustomObject]@{
            SerialNumber = $SerialNumber
        }
    }
}

# --- Validate CSV structure ---
if (-not $Interactive) {
    $HeaderLine = Get-Content -Path $CSVPath -First 1

    if ([string]::IsNullOrWhiteSpace($HeaderLine)) {
        Write-Host "CSV is empty. Nothing to process." -ForegroundColor Yellow
        exit
    }

    $Headers = $HeaderLine.Split(',').Trim('"', ' ')

    if ("SerialNumber" -notin $Headers) {
        Write-Host "CSV must contain a 'SerialNumber' column." -ForegroundColor Red
        exit
    }
}

if (-not $ImportedData) {
    if ($Interactive) {
        Write-Host "No serial numbers entered. Nothing to process." -ForegroundColor Yellow
    }
    else {
        Write-Host "CSV contains no device rows. Nothing to process." -ForegroundColor Yellow
    }
    exit
}

if ("SerialNumber" -notin ($ImportedData[0].psobject.Properties).Name) {
    Write-Host "CSV must contain a 'SerialNumber' column." -ForegroundColor Red
    exit
}

# --- Log setup and rotation ---
try {
    $LogDirectory = Split-Path (Resolve-Path $CSVPath)
}
catch {
    $LogDirectory = $ScriptDirectory
}

$ExistingLogs = Get-ChildItem `
    -Path $LogDirectory `
    -Filter "Log_*.csv" `
    -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime

if ($ExistingLogs.Count -ge 5) {
    $OldestLog = $ExistingLogs[0]

    try {
        Remove-Item -Path $OldestLog.FullName -Force
        Write-Host "Deleted oldest log file: $($OldestLog.Name)" -ForegroundColor Yellow
    }
    catch {
        Write-Host "Failed to delete oldest log file: $($OldestLog.Name)" -ForegroundColor Red
    }
}

$LogPath = Join-Path $LogDirectory (
    "Log_" + (Get-Date -Format "yyyy-MM-dd_HH-mm-ss") + ".csv"
)

Write-Host "Results will be logged to " -NoNewline
Write-Host $LogPath -ForegroundColor Cyan

# --- Graph setup ---
# Create a single-tenant public-client app registration in Microsoft Entra ID,
# then paste its Application (client) ID and Directory (tenant) ID below.
$GraphClientId = ""
$GraphTenantId = ""

if ([string]::IsNullOrWhiteSpace($GraphClientId) -or
    [string]::IsNullOrWhiteSpace($GraphTenantId)) {

    Write-Host "Microsoft Graph configuration is incomplete." -ForegroundColor Red
    Write-Host "Set `$GraphClientId and `$GraphTenantId in the Graph setup section, then run the script again." -ForegroundColor Yellow
    exit 1
}

$RequiredGraphModules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.DeviceManagement",
    "Microsoft.Graph.DeviceManagement.Enrollment",
    "Microsoft.Graph.Identity.DirectoryManagement"
)

# --- Check Microsoft Graph PowerShell version ---
Write-Host "Checking Microsoft Graph PowerShell version..."

try {
    $LatestGraphPackage = Find-Module Microsoft.Graph `
        -Repository PSGallery `
        -ErrorAction Stop

    $LatestGraphVersion = [version]$LatestGraphPackage.Version
}
catch {
    Write-Host "Unable to check the latest Microsoft Graph PowerShell version from PowerShell Gallery." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

$GraphUpdateRequired = $false

foreach ($ModuleName in $RequiredGraphModules) {
    $InstalledModule = Get-Module $ModuleName -ListAvailable |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $InstalledModule) {
        Write-Host "$ModuleName is not installed." -ForegroundColor Yellow
        $GraphUpdateRequired = $true
        continue
    }

    if ([version]$InstalledModule.Version -lt $LatestGraphVersion) {
        Write-Host "$ModuleName is outdated: $($InstalledModule.Version) -> $LatestGraphVersion" -ForegroundColor Yellow
        $GraphUpdateRequired = $true
    }
}

if ($GraphUpdateRequired) {
    $LoadedGraphModules = @(Get-Module Microsoft.Graph.*)

    Write-Host "Installing Microsoft Graph PowerShell $LatestGraphVersion for the current user..." -ForegroundColor Cyan

    try {
        foreach ($ModuleName in $RequiredGraphModules) {
            Install-Module $ModuleName `
                -RequiredVersion $LatestGraphVersion `
                -Repository PSGallery `
                -Scope CurrentUser `
                -Force `
                -AllowClobber `
                -ErrorAction Stop
        }
    }
    catch {
        Write-Host "Failed to install/update Microsoft Graph PowerShell." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 1
    }

    if ($LoadedGraphModules.Count -gt 0) {
        Write-Host "Microsoft Graph was updated, but Graph modules were already loaded in this PowerShell session." -ForegroundColor Yellow
        Write-Host "Close PowerShell, reopen it, and run the script again so the new version can load cleanly." -ForegroundColor Yellow
        exit
    }

    Write-Host "Microsoft Graph PowerShell updated successfully to $LatestGraphVersion." -ForegroundColor Green
}
else {
    Write-Host "Microsoft Graph PowerShell is up to date ($LatestGraphVersion)." -ForegroundColor Green
}

# --- Import current Microsoft Graph modules ---
Write-Host "Importing Microsoft Graph modules..."

foreach ($ModuleName in $RequiredGraphModules) {
    Import-Module $ModuleName `
        -RequiredVersion $LatestGraphVersion `
        -ErrorAction Stop
}

# --- Select delegated scopes needed for this run ---
$GraphScopes = @(
    "DeviceManagementManagedDevices.ReadWrite.All"
)

if ($AutopilotAAD) {
    $GraphScopes += @(
        "DeviceManagementServiceConfig.ReadWrite.All"
        "Directory.AccessAsUser.All"
    )
}

Write-Host "Authenticating with Endpoint Device Removal Tool..."

# Force the custom public-client app to use InteractiveBrowserCredential
# instead of Windows Web Account Manager (WAM).
Set-MgGraphOption -DisableLoginByWAM $true

Connect-MgGraph `
    -ClientId $GraphClientId `
    -TenantId $GraphTenantId `
    -Scopes $GraphScopes `
    -ContextScope Process `
    -NoWelcome `
    -Verbose `
    -ErrorAction Stop

# --- Process devices ---
$Total = $ImportedData.Count
$Count = 0

foreach ($CurrentComputer in $ImportedData) {
    $Count++

    $SerialNumber = $CurrentComputer.SerialNumber.ToUpper()
    $CleanSerial = ($SerialNumber -replace '[^0-9A-Za-z-]', '').Trim()

    if ($CleanSerial -ne $SerialNumber) {
        Write-Host "Sanitized serial from '$SerialNumber' to '$CleanSerial'" -ForegroundColor Yellow
    }

    $DeviceLog = [PSCustomObject]@{
        SerialNumber = $CleanSerial
        Intune       = "Not attempted"
        Autopilot    = "Not attempted"
        AzureAD      = "Not attempted"
    }

    Write-Host "`nProcessing device $Count of ${Total}: $CleanSerial" -ForegroundColor Cyan

    # --- Intune Removal ---
    try {
        $DeviceLog.Intune = "Not found"

        $IntuneDevices = Get-MgDeviceManagementManagedDevice `
            -Filter "SerialNumber eq '$CleanSerial'" `
            -ErrorAction Stop

        foreach ($IntuneDevice in $IntuneDevices) {
            $DeviceLog.Intune = "Found"

            try {
                Remove-MgDeviceManagementManagedDevice `
                    -ManagedDeviceId $IntuneDevice.Id `
                    -ErrorAction Stop

                $DeviceLog.Intune = "Deleted"

                Write-Host "Deleted $($IntuneDevice.DeviceName) from Intune" -ForegroundColor Green
            }
            catch {
                $DeviceLog.Intune = "Error deleting"

                Write-Host "Error deleting $($IntuneDevice.DeviceName) from Intune" -ForegroundColor Red
            }
        }

        if (-not $IntuneDevices) {
            Write-Host "No Intune device found" -ForegroundColor DarkGray
        }
    }
    catch {
        $DeviceLog.Intune = "Error finding"

        Write-Host "Error finding Intune device" -ForegroundColor Red
    }

    # --- Autopilot + Azure AD Removal ---
    if ($AutopilotAAD) {
        try {
            $DeviceLog.Autopilot = "Not found"
            $AutopilotDevices = @()

            try {
                # The Autopilot Graph endpoint supports contains() for serial number
                # searches, but not eq. Use contains() server-side, then enforce an
                # exact serial number match locally.
                $AutopilotDevices = @(
                    Get-MgDeviceManagementWindowsAutopilotDeviceIdentity `
                        -Filter "contains(serialNumber,'$CleanSerial')" `
                        -ErrorAction Stop |
                    Where-Object {
                        $_.SerialNumber -eq $CleanSerial
                    }
                )
            }
            catch {
                $ErrorMessage = $_.Exception.Message

                if ($_.ErrorDetails.Message) {
                    $ErrorMessage = $_.ErrorDetails.Message
                }

                $DeviceLog.Autopilot = "Error finding: $ErrorMessage"

                Write-Host "Error finding Autopilot record:" -ForegroundColor Red
                Write-Host $ErrorMessage -ForegroundColor Red

                throw
            }

            foreach ($AutopilotDevice in $AutopilotDevices) {
                $DeviceLog.Autopilot = "Found"

                # Keep the Autopilot record until Azure AD cleanup succeeds.
                # This preserves the AzureActiveDirectoryDeviceId for retries.
                $CanDeleteAutopilot = $true

                # --- Linked Azure AD removal ---
                $DeviceLog.AzureAD = "Not found"

                if ($AutopilotDevice.AzureActiveDirectoryDeviceId) {

                    # --- Find Azure AD device ---
                    $AADDevice = $null

                    try {
                        $AADDevice = Get-MgDevice `
                            -Filter "DeviceId eq '$($AutopilotDevice.AzureActiveDirectoryDeviceId)'" `
                            -ErrorAction Stop
                    }
                    catch {
                        $ErrorMessage = $_.Exception.Message

                        if ($_.ErrorDetails.Message) {
                            $ErrorMessage = $_.ErrorDetails.Message
                        }

                        $DeviceLog.AzureAD = "Error finding: $ErrorMessage"
                        $CanDeleteAutopilot = $false

                        Write-Host "Error finding Azure AD device:" -ForegroundColor Red
                        Write-Host $ErrorMessage -ForegroundColor Red
                    }

                    # --- Delete Azure AD device ---
                    if ($AADDevice) {
                        $DeviceLog.AzureAD = "Found"

                        try {
                            Remove-MgDevice `
                                -DeviceId $AADDevice.Id `
                                -ErrorAction Stop

                            $DeviceLog.AzureAD = "Deleted"

                            Write-Host "Deleted Azure AD device $($AADDevice.Id)" -ForegroundColor Green
                        }
                        catch {
                            $ErrorMessage = $_.Exception.Message

                            if ($_.ErrorDetails.Message) {
                                $ErrorMessage = $_.ErrorDetails.Message
                            }

                            $DeviceLog.AzureAD = "Error deleting: $ErrorMessage"
                            $CanDeleteAutopilot = $false

                            Write-Host "Error deleting Azure AD device $($AADDevice.Id):" -ForegroundColor Red
                            Write-Host $ErrorMessage -ForegroundColor Red
                        }
                    }
                    elseif ($DeviceLog.AzureAD -notlike "Error finding*") {
                        $DeviceLog.AzureAD = "Not found"

                        Write-Host "No Azure AD device found" -ForegroundColor DarkGray
                    }
                }
                else {
                    $DeviceLog.AzureAD = "Not found"

                    Write-Host "No linked Azure AD device found" -ForegroundColor DarkGray
                }

                # --- Autopilot Removal ---
                if ($CanDeleteAutopilot) {
                    try {
                        Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity `
                            -WindowsAutopilotDeviceIdentityId $AutopilotDevice.Id `
                            -ErrorAction Stop

                        $DeviceLog.Autopilot = "Deleted"

                        Write-Host "Deleted Autopilot record ID $($AutopilotDevice.Id)" -ForegroundColor Green
                    }
                    catch {
                        $ErrorMessage = $_.Exception.Message

                        if ($_.ErrorDetails.Message) {
                            $ErrorMessage = $_.ErrorDetails.Message
                        }

                        $DeviceLog.Autopilot = "Error deleting: $ErrorMessage"

                        Write-Host "Error deleting Autopilot record ID $($AutopilotDevice.Id):" -ForegroundColor Red
                        Write-Host $ErrorMessage -ForegroundColor Red
                    }
                }
                else {
                    $DeviceLog.Autopilot = "Skipped - Azure AD error"

                    Write-Host "Skipped Autopilot deletion because Azure AD cleanup failed." -ForegroundColor Yellow
                    Write-Host "The Autopilot record was left intact so the operation can be retried." -ForegroundColor Yellow
                }
            }

            if (-not $AutopilotDevices) {
                $DeviceLog.AzureAD = "Not attempted - no Autopilot record"
                Write-Host "No Autopilot record found" -ForegroundColor DarkGray
            }
        }
        catch {
            # Preserve a detailed Autopilot lookup error if one was already captured.
            if ($DeviceLog.Autopilot -notlike "Error finding:*") {
                $ErrorMessage = $_.Exception.Message

                if ($_.ErrorDetails.Message) {
                    $ErrorMessage = $_.ErrorDetails.Message
                }

                $DeviceLog.Autopilot = "Error processing: $ErrorMessage"
            }

            Write-Host "Error processing Autopilot/Azure AD removal" -ForegroundColor Red
        }
    }

    # --- Log results ---
    Export-Csv `
        -Path $LogPath `
        -InputObject $DeviceLog `
        -Append `
        -NoTypeInformation
}

Write-Host "`nAll operations completed. Log saved to:" -ForegroundColor Cyan
Write-Host $LogPath -ForegroundColor Yellow
