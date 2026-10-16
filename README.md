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
- Checks PowerShell Gallery for the latest Microsoft Graph PowerShell version and installs/updates the required Graph modules when necessary.
- Uses interactive browser authentication for Microsoft Graph sign-in.

> **Warning:** This script performs destructive device-deletion operations. Test it in your environment and make sure the users running it have only the permissions and roles they actually require.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+ on Windows.
- Access to PowerShell Gallery (`PSGallery`) so the script can check and install/update the required Microsoft Graph modules.
- An account with the appropriate Intune / Entra administrative rights.
- A single-tenant Microsoft Entra app registration configured for delegated Microsoft Graph access.
- An administrator who can grant tenant-wide consent to the required delegated permissions.

## 1. Microsoft Graph PowerShell

The script automatically checks PowerShell Gallery for the latest `Microsoft.Graph` release and verifies that the Graph modules it uses are installed at that version.

The required modules are:

```text
Microsoft.Graph.Authentication
Microsoft.Graph.DeviceManagement
Microsoft.Graph.DeviceManagement.Enrollment
Microsoft.Graph.Identity.DirectoryManagement
```

If they are missing or outdated, the script installs/updates them for the **current user**.

If Microsoft Graph modules were already loaded in the current PowerShell session when an update was required, the script will ask you to close PowerShell, reopen it, and run the script again so the updated modules can load cleanly.

If you want to install Microsoft Graph manually before running the script:

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser -Force -AllowClobber
```

If your execution policy prevents the downloaded script from running, unblock the trusted script file:

```powershell
Unblock-File -Path ".\Remove-IntuneDevices.ps1"
```

Do not weaken your organization's execution policy globally just to run this script.

## 2. Create the Entra app registration

In the **Microsoft Entra admin center**:

1. Go to **Identity > Applications > App registrations > New registration**.
2. Give the application a name such as `Endpoint Device Removal Tool`.
3. For **Supported account types**, choose **Accounts in this organizational directory only**.
4. For **Redirect URI**, choose **Public client/native** and enter:

   ```text
   http://localhost
   ```

   `http://localhost` must be registered as a **Mobile and desktop application / public client** redirect URI, **not** as a Web redirect URI.

5. Select **Register**.
6. From the app's **Overview** page, copy:
   - **Application (client) ID**
   - **Directory (tenant) ID**
7. Under **Authentication**, enable **Allow public client flows** if it is not already enabled.

### Optional WAM redirect

This script intentionally uses `InteractiveBrowserCredential` instead of Windows Web Account Manager (WAM), so the WAM broker redirect is not required for the script itself.

If you also want the app registration to support WAM in other tools or future versions, add this under **Authentication > Add a platform > Mobile and desktop applications**:

```text
ms-appx-web://Microsoft.AAD.BrokerPlugin/<APPLICATION-CLIENT-ID>
```

Replace `<APPLICATION-CLIENT-ID>` with the Application (client) ID from the app's Overview page.

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
- Sign in with your organizational Microsoft account in the browser when prompted.

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

This script uses delegated authentication with the organization's public-client app registration and explicitly disables WAM so Microsoft Graph uses interactive browser authentication:

```powershell
Set-MgGraphOption -DisableLoginByWAM $true

Connect-MgGraph `
    -ClientId $GraphClientId `
    -TenantId $GraphTenantId `
    -Scopes $GraphScopes `
    -ContextScope Process
```

For an **Intune-only** run, the script requests:

```text
DeviceManagementManagedDevices.ReadWrite.All
```

When `-AutopilotAAD` is used, it additionally requests:

```text
DeviceManagementServiceConfig.ReadWrite.All
Directory.AccessAsUser.All
```

The signed-in user's own Intune / Entra permissions still apply. The app registration identifies the OAuth client and defines which Microsoft Graph delegated permissions the organization has approved for the tool.

No application secret or certificate is required.

## Troubleshooting

### `AADSTS7000218` / asks for a client secret

If interactive browser authentication returns an error similar to:

```text
AADSTS7000218: The request body must contain the following parameter:
'client_assertion' or 'client_secret'
```

check the app registration's **Authentication** page.

`http://localhost` must be configured under **Mobile and desktop applications / public client**, not under **Web**.

### "Need admin approval" or `AADSTS90094`

Verify that:

- The script contains the correct client ID and tenant ID.
- The required delegated Microsoft Graph permissions were added to the app registration.
- Tenant-wide admin consent was granted.
- If **Assignment required?** is enabled, the signed-in user or one of their groups is assigned to the Enterprise application.

### Microsoft Graph modules are outdated

The script normally updates its required modules automatically. If automatic installation fails, run:

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser -Force -AllowClobber
```

Then close PowerShell completely, reopen it, and run the script again.

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
