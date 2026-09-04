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

[CmdletBinding(DefaultParameterSetName = "All")]
Param (
    [Parameter(HelpMessage = "Path to CSV file with column named SerialNumber", Position = 0)]
    [string] $CSVPath,

    [Parameter(HelpMessage = "Also remove devices from Autopilot and Azure AD (True or False)")]
    [switch] $AutopilotAAD,

    [Parameter(HelpMessage = "Interactive mode (True or False)")]
    [switch] $Interactive
)

# --- Determine script directory ---
# $PSScriptRoot points to the folder containing this .ps1 file.
# Fall back to the current directory if the code is being run interactively.
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
if (-not $ImportedData -or "SerialNumber" -notin ($ImportedData[0].psobject.Properties).Name) {
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
    -ErrorAction Stop

# --- Process devices ---
$Total = $ImportedData.Count
$Count = 0

foreach ($CurrentComputer in $ImportedData) {
    $Count++
    $Percent = [int](($Count / $Total) * 100)

    Write-Progress `
        -Activity "Removing Devices from Intune" `
        -Status "$Count of $Total ($Percent%)" `
        -PercentComplete $Percent

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

    Write-Host "Processing $CleanSerial..." -ForegroundColor Cyan

    # --- Intune Removal ---
    try {
        $DeviceLog.Intune = "Not found"

        $IntuneDevices = Get-MgDeviceManagementManagedDevice `
            -Filter "SerialNumber eq '$CleanSerial'" `
            -ErrorAction SilentlyContinue

        foreach ($IntuneDevice in $IntuneDevices) {
            $DeviceLog.Intune = "Found"

            try {
                Remove-MgDeviceManagementManagedDevice `
                    -ManagedDeviceId $IntuneDevice.Id `
                    -ErrorAction SilentlyContinue

                $DeviceLog.Intune = "Deleted"

                Write-Host "Deleted $($IntuneDevice.deviceName) from Intune" -ForegroundColor Green
            }
            catch {
                $DeviceLog.Intune = "Error deleting"

                Write-Host "Error deleting $($IntuneDevice.deviceName) from Intune" -ForegroundColor Red
            }
        }

        if (-not $IntuneDevices) {
            Write-Host "No Intune devices found for $CleanSerial" -ForegroundColor DarkGray
        }
    }
    catch {
        $DeviceLog.Intune = "Error finding"

        Write-Host "Error finding $CleanSerial in Intune" -ForegroundColor Red
    }

    # --- Autopilot + AAD Removal ---
    if ($AutopilotAAD) {
        try {
            Write-Host "Searching Autopilot for $CleanSerial..." -ForegroundColor Gray

            $DeviceLog.Autopilot = "Not found"
            $AutopilotDevices = @()

            try {
                $AutopilotDevices = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity `
                    -Filter "SerialNumber eq '$CleanSerial'" `
                    -ErrorAction Stop
            }
            catch {
                Write-Host "Exact match failed, retrying partial search..." -ForegroundColor DarkYellow
            }

            if (-not $AutopilotDevices) {
                try {
                    $AutopilotDevices = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity `
                        -Filter "contains(serialNumber,'$CleanSerial')" `
                        -ErrorAction Stop
                }
                catch {
                    Write-Host "Error searching for $CleanSerial in Autopilot" -ForegroundColor Red
                    throw
                }
            }

            foreach ($AutopilotDevice in $AutopilotDevices) {
                $DeviceLog.Autopilot = "Found"

                try {
                    Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity `
                        -WindowsAutopilotDeviceIdentityId $AutopilotDevice.Id `
                        -ErrorAction SilentlyContinue

                    $DeviceLog.Autopilot = "Deleted"

                    Write-Host "Deleted Autopilot record ID $($AutopilotDevice.Id)" -ForegroundColor Green
                }
                catch {
                    $DeviceLog.Autopilot = "Error deleting"

                    Write-Host "Error deleting Autopilot record ID $($AutopilotDevice.Id)" -ForegroundColor Red
                }

                # --- Linked Azure AD removal ---
                $DeviceLog.AzureAD = "Not found"

                if ($AutopilotDevice.AzureActiveDirectoryDeviceId) {
                    try {
                        $AADDevice = Get-MgDevice `
                            -Filter "DeviceId eq '$($AutopilotDevice.AzureActiveDirectoryDeviceId)'" `
                            -ErrorAction Stop

                        if ($AADDevice) {
                            $DeviceLog.AzureAD = "Found"

                            Remove-MgDevice `
                                -DeviceId $AADDevice.Id `
                                -ErrorAction SilentlyContinue

                            $DeviceLog.AzureAD = "Deleted"

                            Write-Host "Deleted Azure AD device $($AADDevice.Id)" -ForegroundColor Green
                        }
                    }
                    catch {
                        $DeviceLog.AzureAD = "Error deleting"

                        Write-Host "Error deleting Azure AD device for $CleanSerial" -ForegroundColor Red
                    }
                }
            }

            if (-not $AutopilotDevices) {
                Write-Host "No Autopilot records found for $CleanSerial" -ForegroundColor DarkGray
            }
        }
        catch {
            $DeviceLog.Autopilot = "Error finding"

            Write-Host "Error processing $CleanSerial in Autopilot/AAD" -ForegroundColor Red
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
