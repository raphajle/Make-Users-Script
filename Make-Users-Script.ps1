#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Interactive AD DS User Manager: Create (auto or CSV), List, Edit, and export CSV templates.
.DESCRIPTION
    Replaces legacy dsadd/dsmod/dsquery batch workflows with native ActiveDirectory
    cmdlets, safer error handling, OU auto-creation, netlogon helper, CSV template
    generation, and tools to list and edit existing users.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Pause-OnError {
    param(
        [string]$Message,
        [switch]$ExitAfterPause,
        [int]$ExitCode = 1
    )

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        Write-Warning $Message
    }

    if ($Host.Name -eq 'ConsoleHost') {
        Write-Host "Press any key to continue..." -ForegroundColor Yellow
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
    else {
        Read-Host "Press Enter to continue..." | Out-Null
    }

    if ($ExitAfterPause) {
        exit $ExitCode
    }
}

# 1. Verify Administrator privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Invoke-Pause-OnError -Message "Access denied. Please run PowerShell as Administrator." -ExitAfterPause -ExitCode 1
}

# 2. Load ActiveDirectory module
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Invoke-Pause-OnError -Message "The 'ActiveDirectory' PowerShell module is not installed (RSAT / AD DS tools required)." -ExitAfterPause -ExitCode 1
}
Import-Module ActiveDirectory

# 3. Resolve domain details (auto-detect with manual fallback)
function Get-TargetDomainContext {
    try {
        $dom = Get-ADDomain -Current LocalComputer
        Write-Host "Detected AD Domain: $($dom.DNSRoot) ($($dom.DistinguishedName))" -ForegroundColor Cyan
        $useDetected = Read-Host "Use this domain? [Y/n]"
        if ($useDetected -match '^(N|No)$') {
            throw "Manual domain requested."
        }
        return [PSCustomObject]@{
            DnsRoot           = $dom.DNSRoot
            DistinguishedName = $dom.DistinguishedName
        }
    }
    catch {
        $domainName = (Read-Host 'Enter domain name (e.g. "canado" or "example")').Trim()
        $ext        = (Read-Host 'Enter domain extension (e.g. "edu", "ht", "com")').Trim().TrimStart('.')
        $dnsRoot    = "$domainName.$ext"
        $dcParts    = ($dnsRoot -split '\.') | ForEach-Object { "DC=$_" }
        return [PSCustomObject]@{
            DnsRoot           = $dnsRoot
            DistinguishedName = ($dcParts -join ',')
        }
    }
}

function Invoke-Ensure-TargetOU {
    param(
        [Parameter(Mandatory)] [string]$OuName,
        [Parameter(Mandatory)] [string]$DomainDN
    )

    $directDN = "OU=$OuName,$DomainDN"
    $ouObj = Get-ADOrganizationalUnit -LDAPFilter "(distinguishedName=$directDN)" -ErrorAction SilentlyContinue
    if (-not $ouObj) {
        $ouObj = Get-ADOrganizationalUnit -Filter "Name -eq '$OuName'" -SearchBase $DomainDN -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if ($ouObj) {
        Write-Host "OU found: $($ouObj.DistinguishedName)" -ForegroundColor Green
        return $ouObj
    }

    Write-Host "OU '$OuName' not found. Creating '$directDN'..." -ForegroundColor Yellow
    $ouObj = New-ADOrganizationalUnit -Name $OuName -Path $DomainDN -PassThru
    Write-Host "Created OU: $($ouObj.DistinguishedName)" -ForegroundColor Green
    return $ouObj
}

function Get-LogonScriptChoice {
    $openNetlogon = Read-Host "Open \\$env:COMPUTERNAME\netlogon in Explorer? [y/N]"
    if ($openNetlogon -match '^(Y|Yes)$') {
        $netlogonPath = "\\$env:COMPUTERNAME\netlogon"
        if (Test-Path $netlogonPath) {
            Start-Process explorer.exe $netlogonPath
        }
        else {
            Invoke-Pause-OnError -Message "Path '$netlogonPath' is not accessible on this machine."
        }
    }

    while ($true) {
        $scriptName = (Read-Host 'Enter logon script filename (.bat/.cmd, or leave blank to skip)').Trim()
        if ([string]::IsNullOrWhiteSpace($scriptName)) {
            return $null
        }
        if ($scriptName -match '\.(bat|cmd)$') {
            return $scriptName
        }
        Invoke-Pause-OnError -Message "Logon script must end with .bat or .cmd (or be left blank)."
    }
}

function Invoke-Apply-UserOptions {
    param(
        [Parameter(Mandatory)] [string]$Identity,
        [string]$LogonScript,
        [bool]$ChangePasswordAtNextLogon,
        [bool]$PasswordNeverExpires
    )

    $splat = @{ Identity = $Identity }
    if (-not [string]::IsNullOrWhiteSpace($LogonScript)) {
        $splat['ScriptPath'] = $LogonScript
    }
    $splat['ChangePasswordAtLogon'] = $ChangePasswordAtNextLogon
    $splat['PasswordNeverExpires']    = $PasswordNeverExpires

    Set-ADUser @splat
}

function Invoke-ExportCsvTemplateWorkflow {
    Write-Host "`n--- Export CSV User Import Model ---" -ForegroundColor Cyan
    $defaultPath = Join-Path -Path (Get-Location).Path -ChildPath "newusers_template.csv"
    $outPathInput = (Read-Host "Enter output CSV file path [default: $defaultPath]").Trim('"').Trim()
    $outPath = if ([string]::IsNullOrWhiteSpace($outPathInput)) { $defaultPath } else { $outPathInput }

    if ($outPath -notmatch '\.csv$') {
        $outPath = "$outPath.csv"
    }

    $parentDir = Split-Path -Path $outPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($parentDir) -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $templateRows = @(
        [PSCustomObject]@{
            FirstName      = 'Jean'
            LastName       = 'Baptiste'
            SamAccountName = 'jbaptiste'
            Password       = 'ChangeMe@123!'
        },
        [PSCustomObject]@{
            FirstName      = 'Marie'
            LastName       = 'Pierre'
            SamAccountName = 'mpierre'
            Password       = 'ChangeMe@123!'
        }
    )

    try {
        $templateRows | Export-Csv -LiteralPath $outPath -NoTypeInformation -Encoding UTF8
        Write-Host "CSV model created at '$outPath'." -ForegroundColor Green
        Write-Host "Columns: FirstName, LastName, SamAccountName, Password" -ForegroundColor Yellow

        $openFile = Read-Host "Open the CSV template now? [y/N]"
        if ($openFile -match '^(Y|Yes)$') {
            Start-Process -FilePath $outPath
        }
    }
    catch {
        Invoke-Pause-OnError -Message "Failed to create CSV model: $($_.Exception.Message)"
    }
}

function Invoke-CreateUsersWorkflow {
    param([Parameter(Mandatory)] $DomainCtx)

    $ouName = (Read-Host 'Enter target OU name (e.g. "Students", "Sales")').Trim()
    if ([string]::IsNullOrWhiteSpace($ouName)) {
        Invoke-Pause-OnError -Message "OU name cannot be empty."
        return
    }

    try {
        $ouObj = Invoke-Ensure-TargetOU -OuName $ouName -DomainDN $DomainCtx.DistinguishedName
    }
    catch {
        Invoke-Pause-OnError -Message "Failed to verify or create OU '$ouName': $($_.Exception.Message)"
        return
    }

    $logonScript = Get-LogonScriptChoice

    $mustChangeInput = Read-Host "User must change password at next logon? [y/N]"
    $mustChange      = $mustChangeInput -match '^(Y|Yes)$'
    $neverExpires    = -not $mustChange

    $csvPathInput = (Read-Host 'Enter full CSV path (columns: FirstName,LastName,SamAccountName,Password) or leave blank for auto-generate').Trim('"').Trim()

    if (-not [string]::IsNullOrWhiteSpace($csvPathInput)) {
        if (-not (Test-Path -LiteralPath $csvPathInput -PathType Leaf)) {
            Invoke-Pause-OnError -Message "CSV file not found: $csvPathInput"
            return
        }

        $rawLines = Get-Content -LiteralPath $csvPathInput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $firstLine = $rawLines[0].ToLower()
        if ($firstLine -match 'firstname' -and $firstLine -match 'password') {
            $rows = Import-Csv -LiteralPath $csvPathInput
        }
        else {
            $rows = Import-Csv -LiteralPath $csvPathInput -Header 'FirstName','LastName','SamAccountName','Password'
        }

        foreach ($row in $rows) {
            $fn   = $row.FirstName.Trim()
            $ln   = $row.LastName.Trim()
            $sam  = $row.SamAccountName.Trim()
            $rowpwd  = $row.Password

            if (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
                Write-Warning "User '$sam' already exists. Skipping."
                continue
            }

            try {
                $securePwd = ConvertTo-SecureString $rowpwd -AsPlainText -Force
                $upn = "$sam@$($DomainCtx.DnsRoot)"
                $display = "$fn $ln".Trim()

                New-ADUser `
                    -Name $sam `
                    -GivenName $fn `
                    -Surname $ln `
                    -DisplayName $display `
                    -SamAccountName $sam `
                    -UserPrincipalName $upn `
                    -Path $ouObj.DistinguishedName `
                    -AccountPassword $securePwd `
                    -Enabled $true | Out-Null

                Invoke-Apply-UserOptions -Identity $sam -LogonScript $logonScript -ChangePasswordAtNextLogon $mustChange -PasswordNeverExpires $neverExpires
                Write-Host "Created user '$sam' ($display)." -ForegroundColor Green
            }
            catch {
                Invoke-Pause-OnError -Message "Failed to add user '$sam': $($_.Exception.Message)"
            }
        }
    }
    else {
        [int]$count = Read-Host 'Enter number of users to generate (e.g. 1, 10, 50)'
        if ($count -lt 1) {
            Invoke-Pause-OnError -Message "Count must be at least 1."
            return
        }

        $prefix = (Read-Host "Enter username prefix [default: $ouName]").Trim()
        if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = $ouName }

        $plainPwd = Read-Host "Enter default password for generated users"
        $securePwd = ConvertTo-SecureString $plainPwd -AsPlainText -Force

        for ($i = 1; $i -le $count; $i++) {
            $uid = $i.ToString("D3")
            $sam = "$prefix$uid"
            $display = "$ouName $i"
            $upn = "$sam@$($DomainCtx.DnsRoot)"

            if (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
                Write-Warning "User '$sam' already exists. Skipping."
                continue
            }

            try {
                New-ADUser `
                    -Name $sam `
                    -DisplayName $display `
                    -SamAccountName $sam `
                    -UserPrincipalName $upn `
                    -Path $ouObj.DistinguishedName `
                    -AccountPassword $securePwd `
                    -Enabled $true | Out-Null

                Invoke-Apply-UserOptions -Identity $sam -LogonScript $logonScript -ChangePasswordAtNextLogon $mustChange -PasswordNeverExpires $neverExpires
                Write-Host "[$i/$count] Created user '$sam' ($display)." -ForegroundColor Green
            }
            catch {
                Invoke-Pause-OnError -Message "[$i/$count] Failed to add user '$sam': $($_.Exception.Message)"
            }
        }
    }
}

function Invoke-ListUsersWorkflow {
    param([Parameter(Mandatory)] $DomainCtx)

    Write-Host "`n--- List Existing AD Users ---" -ForegroundColor Cyan
    Write-Host "1. List users in a specific OU"
    Write-Host "2. Search users across the entire domain (by name/username)"
    $mode = Read-Host "Choose option [1/2]"

    $props = @('DisplayName', 'UserPrincipalName', 'Enabled', 'ScriptPath', 'PasswordNeverExpires', 'DistinguishedName')
    $users = @()

    if ($mode -eq '1') {
        $ouName = (Read-Host "Enter OU name (leave blank for entire domain)").Trim()
        if ([string]::IsNullOrWhiteSpace($ouName)) {
            $users = Get-ADUser -Filter * -Properties $props | Sort-Object SamAccountName
        }
        else {
            $ouObj = Get-ADOrganizationalUnit -Filter "Name -eq '$ouName'" -SearchBase $DomainCtx.DistinguishedName -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $ouObj) {
                Invoke-Pause-OnError -Message "OU '$ouName' not found."
                return
            }
            $users = Get-ADUser -Filter * -SearchBase $ouObj.DistinguishedName -Properties $props | Sort-Object SamAccountName
        }
    }
    elseif ($mode -eq '2') {
        $term = (Read-Host "Enter search text (SamAccountName, GivenName, Surname, or DisplayName)").Trim()
        $users = Get-ADUser -Filter "SamAccountName -like '*$term*' -or DisplayName -like '*$term*' -or GivenName -like '*$term*' -or Surname -like '*$term*'" -Properties $props | Sort-Object SamAccountName
    }
    else {
        Invoke-Pause-OnError -Message "Invalid selection."
        return
    }

    if (-not $users -or @($users).Count -eq 0) {
        Write-Host "No matching users found." -ForegroundColor Yellow
        return
    }

    $formatted = $users | Select-Object SamAccountName, DisplayName, Enabled, ScriptPath, PasswordNeverExpires, UserPrincipalName
    $formatted | Format-Table -AutoSize

    $exportCsv = Read-Host "Export this list to a CSV file? [y/N]"
    if ($exportCsv -match '^(Y|Yes)$') {
        $outFile = (Read-Host "Enter output CSV path (e.g. C:\Temp\ad_users.csv)").Trim('"').Trim()
        try {
            $formatted | Export-Csv -LiteralPath $outFile -NoTypeInformation -Encoding UTF8
            Write-Host "Exported $(@($formatted).Count) user(s) to '$outFile'." -ForegroundColor Green
        }
        catch {
            Invoke-Pause-OnError -Message "Failed to export CSV to '$outFile': $($_.Exception.Message)"
        }
    }
}

function Invoke-EditUserWorkflow {
    param([Parameter(Mandatory)] $DomainCtx)

    Write-Host "`n--- Edit Existing AD User ---" -ForegroundColor Cyan
    $sam = (Read-Host "Enter the SamAccountName (username) of the user to edit").Trim()
    if ([string]::IsNullOrWhiteSpace($sam)) {
        Invoke-Pause-OnError -Message "Username cannot be empty."
        return
    }

    $user = Get-ADUser -Identity $sam -Properties DisplayName, GivenName, Surname, ScriptPath, Enabled, PasswordNeverExpires, UserPrincipalName -ErrorAction SilentlyContinue
    if (-not $user) {
        Invoke-Pause-OnError -Message "User '$sam' was not found in Active Directory."
        return
    }

    Write-Host "`nCurrent settings for '$($user.SamAccountName)':" -ForegroundColor Yellow
    [PSCustomObject]@{
        SamAccountName       = $user.SamAccountName
        DisplayName          = $user.DisplayName
        GivenName            = $user.GivenName
        Surname              = $user.Surname
        Enabled              = $user.Enabled
        ScriptPath           = $user.ScriptPath
        PasswordNeverExpires = $user.PasswordNeverExpires
    } | Format-List

    Write-Host "Leave any prompt blank to keep its current value."
    $newDisplay = Read-Host "New Display Name [current: $($user.DisplayName)]"
    $newGiven   = Read-Host "New First Name [current: $($user.GivenName)]"
    $newSurname = Read-Host "New Last Name [current: $($user.Surname)]"
    $newScript  = Read-Host "New Logon Script (enter 'CLEAR' to remove) [current: $($user.ScriptPath)]"
    $newEnabled = Read-Host "Account status - Enable (E), Disable (D), or Keep [E/D/blank]"
    $newPwdOpt  = Read-Host "Password flag - Force change next logon (C), Never expires (N), or Keep [C/N/blank]"
    $newPwd     = Read-Host "Reset password to new value (leave blank to keep current password)"

    try {
        $setParams = @{ Identity = $user.SamAccountName }
        $hasFieldChanges = $false

        if (-not [string]::IsNullOrWhiteSpace($newDisplay)) { $setParams['DisplayName'] = $newDisplay.Trim(); $hasFieldChanges = $true }
        if (-not [string]::IsNullOrWhiteSpace($newGiven))   { $setParams['GivenName']   = $newGiven.Trim();   $hasFieldChanges = $true }
        if (-not [string]::IsNullOrWhiteSpace($newSurname)) { $setParams['Surname']     = $newSurname.Trim(); $hasFieldChanges = $true }

        if ($newScript -eq 'CLEAR') {
            $setParams['Clear'] = @('scriptPath')
            $hasFieldChanges = $true
        }
        elseif (-not [string]::IsNullOrWhiteSpace($newScript)) {
            $setParams['ScriptPath'] = $newScript.Trim()
            $hasFieldChanges = $true
        }

        if ($newEnabled -match '^(E|Enable)$') {
            $setParams['Enabled'] = $true
            $hasFieldChanges = $true
        }
        elseif ($newEnabled -match '^(D|Disable)$') {
            $setParams['Enabled'] = $false
            $hasFieldChanges = $true
        }

        if ($newPwdOpt -match '^(C|Change)$') {
            $setParams['PasswordNeverExpires']    = $false
            $setParams['ChangePasswordAtLogon'] = $true
            $hasFieldChanges = $true
        }
        elseif ($newPwdOpt -match '^(N|Never)$') {
            $setParams['PasswordNeverExpires']    = $true
            $setParams['ChangePasswordAtLogon'] = $false
            $hasFieldChanges = $true
        }

        if ($hasFieldChanges) {
            Set-ADUser @setParams
        }

        if (-not [string]::IsNullOrWhiteSpace($newPwd)) {
            $sec = ConvertTo-SecureString $newPwd -AsPlainText -Force
            Set-ADAccountPassword -Identity $user.SamAccountName -NewPassword $sec -Reset
        }

        Write-Host "Successfully updated '$($user.SamAccountName)'." -ForegroundColor Green
    }
    catch {
        Invoke-Pause-OnError -Message "Failed to update '$($user.SamAccountName)': $($_.Exception.Message)"
    }
}

# --- Main Loop ---
$domainCtx = Get-TargetDomainContext

while ($true) {
    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host " AD DS User Management ($($domainCtx.DnsRoot))" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "1. Create Users (Auto-generate or CSV)"
    Write-Host "2. List Existing Users (by OU or Search)"
    Write-Host "3. Edit an Existing User"
    Write-Host "4. Export CSV Model / Template"
    Write-Host "5. Switch Target Domain"
    Write-Host "6. Exit"
    $choice = (Read-Host "Select an option [1-6]").Trim()

    switch ($choice) {
        '1' { Invoke-CreateUsersWorkflow -DomainCtx $domainCtx }
        '2' { Invoke-ListUsersWorkflow -DomainCtx $domainCtx }
        '3' { Invoke-EditUserWorkflow -DomainCtx $domainCtx }
        '4' { Invoke-ExportCsvTemplateWorkflow }
        '5' { $domainCtx = Get-TargetDomainContext }
        '6' { Write-Host "Exiting."; break }
        default { Invoke-Pause-OnError -Message "Please enter a number between 1 and 6." }
    }

    if ($choice -eq '6') { break }
}