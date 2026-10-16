# Remove-IntuneDevices.ps1

PowerShell script for bulk-removing Windows devices from Microsoft Intune, with optional removal from Windows Autopilot and Microsoft Entra ID.

The script uses **delegated Microsoft Graph authentication** through your organization's own Entra app registration. Each technician signs in with their own account; no client secret or certificate is stored in the script.

## What it does

- Reads serial numbers from a CSV containing a `SerialNumber` column, or accepts serial numbers interactively.
- Removes matching managed-device records from Intune.
- Optionally removes matching Windows Autopilot records and their linked Entra ID device objects.
- Sanitizes serial numbers before Graph queries.
- Writes results to a timestamped CSV log.
- Keeps the five newest log files.
- Uses Windows Authentication Manager (WAM) for interactive Microsoft Graph sign-in.

> **Warning:** This script performs destructive device-deletion operations. Test it in your environment and make sure the users running it have only the permissions and roles they actually require.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+ on Windows.
- Microsoft Graph PowerShell installed.
- An account with the appropriate Intune / Entra administrative rights.
- A single-tenant Microsoft Entra app registration configured for delegated Microsoft Graph access.
- An administrator who can grant tenant-wide consent to the required delegated permissions.

## 1. Install Microsoft Graph PowerShell

Open **Terminal (Admin)** or an elevated PowerShell window and run:

```powershell
Install-Module Microsoft.Graph -Scope AllUsers -Force
Install-Module Microsoft.Graph.Intune -Scope AllUsers -Force
```

If your execution policy prevents local scripts from running, configure an execution policy appropriate for your organization rather than disabling PowerShell security globally.

## 2. Create the Entra app registration

In the **Microsoft Entra admin center**:

1. Go to **Identity > Applications > App registrations > New registration**.
2. Give the application a name such as `Endpoint Device Removal Tool`.
3. For **Supported account types**, choose **Accounts in this organizational directory only**.
4. For **Redirect URI**, choose **Public client/native** and enter:

   ```text
   http://localhost
   ```

5. Select **Register**.
6. From the app's **Overview** page, copy:
   - **Application (client) ID**
   - **Directory (tenant) ID**
7. Go to **Authentication > Add a platform > Mobile and desktop applications** and add:

   ```text
   ms-appx-web://Microsoft.AAD.BrokerPlugin/<APPLICATION-CLIENT-ID>
   ```

   Replace `<APPLICATION-CLIENT-ID>` with the Application (client) ID from the Overview page.

8. Under **Authentication**, enable **Allow public client flows** if it is not already enabled.

## 3. Add Microsoft Graph delegated permissions

Under **API permissions > Add a permission > Microsoft Graph > Delegated permissions**, add:

```text
DeviceManagementManagedDevices.ReadWrite.All
DeviceManagementServiceConfig.ReadWrite.All
Directory.AccessAsUser.All
```

An administrator must then select **Grant admin consent** for the tenant.

For tighter access control, you can also open the corresponding **Enterprise application**, set **Assignment required?** to **Yes**, and assign only the users or groups that should be allowed to use the tool.

## 4. Configure the script

Download [Remove-IntuneDevices.ps1](./Remove-IntuneDevices.ps1), open it in a text editor, and find:

```powershell
$GraphClientId = ""
$GraphTenantId = ""
```

Paste in the values from your app registration:

```powershell
$GraphClientId = "YOUR-APPLICATION-CLIENT-ID"
$GraphTenantId = "YOUR-DIRECTORY-TENANT-ID"
```

The client ID and tenant ID are identifiers, not secrets. Do **not** create or embed a client secret for this delegated-authentication setup.

## 5. Prepare the CSV

Create a CSV with a column named exactly:

```text
SerialNumber
```

Example:

```csv
SerialNumber
ABC1234
DEF5678
GHI9012
```

## 6. Run the script

From PowerShell:

```powershell
.\Remove-IntuneDevices.ps1
```

The normal graphical workflow is:

- Choose a CSV in the first file picker to remove those devices from **Intune only**.
- Click **Cancel** in the first picker to open a second picker; choosing a CSV there removes matching devices from **Intune, Autopilot, and Entra ID**.
- Sign in with your organizational Microsoft account when prompted.

You can also specify a CSV directly:

```powershell
.\Remove-IntuneDevices.ps1 -CSVPath ".\devices.csv"
```

To include Autopilot and Entra ID removal:

```powershell
.\Remove-IntuneDevices.ps1 -CSVPath ".\devices.csv" -AutopilotAAD
```

Or enter serial numbers manually:

```powershell
.\Remove-IntuneDevices.ps1 -Interactive
```

## Logging

A timestamped log is written to the same directory as the selected CSV:

```text
Log_yyyy-MM-dd_HH-mm-ss.csv
```

The log records the result for each serial number in Intune, Autopilot, and Entra ID. The script keeps the five newest logs and deletes the oldest when necessary.

## Authentication model

This script uses delegated authentication:

```powershell
Set-MgGraphOption -DisableLoginByWAM $false

Connect-MgGraph `
    -ClientId $GraphClientId `
    -TenantId $GraphTenantId
```

The signed-in user's own Intune / Entra permissions still apply. The app registration identifies the OAuth client and defines the Microsoft Graph permissions that the organization has approved for the tool.

No application secret or certificate is required.

## Troubleshooting

### "Need admin approval" or `AADSTS90094`

Verify that:

- The script contains the correct client ID and tenant ID.
- The three delegated Microsoft Graph permissions were added to the app registration.
- Tenant-wide admin consent was granted.
- If **Assignment required?** is enabled, the signed-in user or one of their groups is assigned to the Enterprise application.

### `Set-MgGraphOption` is not recognized

Update or reinstall Microsoft Graph PowerShell:

```powershell
Update-Module Microsoft.Graph
```

If the module was not already installed:

```powershell
Install-Module Microsoft.Graph -Scope AllUsers -Force
```

### Authentication uses the wrong account

Close the Graph session and rerun the script:

```powershell
Disconnect-MgGraph
```

You can inspect the current Graph session with:

```powershell
Get-MgContext
```

## License / responsibility

Review and test the script before using it in production. Device deletion is destructive, and Microsoft Graph / Intune behavior and permissions may change over time.
