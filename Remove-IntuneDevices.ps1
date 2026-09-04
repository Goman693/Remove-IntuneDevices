<#
.SYNOPSIS
    Removes devices from Intune, optionally including Autopilot and Azure AD.

.DESCRIPTION
    - Accepts a CSV file with a "SerialNumber" column, or allows interactive input.
    - Sanitizes serial numbers to prevent Graph query errors.
    - Optionally removes devices from Intune, Autopilot, and Azure AD.
    - Logs all results with automatic log rotation (keeps 5 newest logs).
    - CSV picker automatically opens to the directory containing this script.

.PARAMETER CSVPath
    Path to a CSV file containing a column named SerialNumber.

.PARAMETER AutopilotAAD
    If specified, also removes matching devices from Autopilot and Azure AD.

.PARAMETER Interactive
    Prompts for manual serial number entry instead of reading from a CSV.

.NOTES
    Requires Microsoft.Graph.Intune module and appropriate Graph permissions.
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
}

# --- Import CSV or enter serials manually ---
if (-Not $Interactive) {
    try {
        $ImportedData = Import-Csv -Path $CSVPath -Encoding UTF8

        Write-Host "Import successful. Devices will be removed from " -NoNewline

        if ($AutopilotAAD) {
            Write-Host "Intune, Autopilot, and Azure AD" -ForegroundColor Cyan
        }
        else {
            Write-Host "Intune" -ForegroundColor Cyan
        }
    }
    catch {
        Write-Host "Error importing CSV. Switching to interactive mode." -ForegroundColor Red
        $Interactive = $true
    }
}

if ($Interactive) {
    Write-Host "Interactive mode enabled. Enter serial numbers to remove. Press Enter on a blank line to finish."

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
    Write-Host "No devices found in the CSV. Nothing to process." -ForegroundColor Yellow
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
Write-Host "Importing Microsoft Graph Intune module..."
Import-Module Microsoft.Graph.Intune -ErrorAction Stop

Write-Host "Authenticating with Microsoft Graph..."
Connect-MgGraph `
    -Scopes "DeviceManagementServiceConfig.ReadWrite.All",
            "DeviceManagementManagedDevices.ReadWrite.All",
            "Directory.AccessAsUser.All" `
    -NoWelcome `
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
                Write-Host "Error finding Autopilot record" -ForegroundColor Red
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
            $DeviceLog.Autopilot = "Error finding"

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
