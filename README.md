# Remove-IntuneDevices.ps1

Instructions for setup:
- Press Windows+X, then click "Terminal (Admin)"
- Authenticate as admin
- Paste in: `Set-ExecutionPolicy Unrestricted -Force ; Install-Module Microsoft.Graph -Scope AllUsers -Force ; Install-Module Microsoft.Graph.Intune -Scope AllUsers -Force`
- Press Enter
- Close the PowerShell window
- Download [Remove-IntuneDevices.ps1](https://github.com/AidanRB/Remove-IntuneDevices/blob/main/Remove-IntuneDevices.ps1) (make sure the "Window" -> "Windows" typo on lines 156 & 162 has been fixed)

Instructions for use:
- Prepare a CSV file with a column named `SerialNumber`
- Right click `Remove-IntuneDevices.ps1`
- Click `Copy as path`
- Press Windows+X, then click "Terminal"
- Type "." and then right click to paste the path copied earlier
- Press Enter
- Follow the prompts
  - To remove devices from Intune, choose the CSV file using the first file picker
  - To remove from Intune, Autopilot, and Azure AD, click Cancel on the first file picker, then choose the CSV file using the second file picker
  - If asked, log in with your Microsoft account and accept the permissions
- Logs are outputted as a CSV file with the date to the directory of the chosen CSV file
