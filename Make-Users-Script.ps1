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
try {
    Import-Module ActiveDirectory -ErrorAction Stop
}
catch {
    Invoke-Pause-OnError -Message "Failed to load the ActiveDirectory module: $($_.Exception.Message)" -ExitAfterPause -ExitCode 1
}

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
            Server            = $dom.DNSRoot
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
            Server            = $dnsRoot
        }
    }
}

function Get-TargetOUByName {
    param(
        [Parameter(Mandatory)] [string]$OuName,
        [Parameter(Mandatory)] [string]$DomainDN,
        [Parameter(Mandatory)] [string]$Server
    )

    if ($OuName -match '^OU=') {
        return Get-ADOrganizationalUnit -Identity $OuName -Server $Server -ErrorAction SilentlyContinue
    }

    $ouMatches = @(Get-ADOrganizationalUnit -Filter * -SearchBase $DomainDN -Server $Server |
        Where-Object { $_.Name -eq $OuName })
    if ($ouMatches.Count -gt 1) {
        throw "Multiple OUs named '$OuName' were found. Specify the OU's distinguished name."
    }
    if ($ouMatches.Count -eq 1) {
        return $ouMatches[0]
    }

    return $null
}

function Invoke-Ensure-TargetOU {
    param(
        [Parameter(Mandatory)] [string]$OuName,
        [Parameter(Mandatory)] [string]$DomainDN,
        [Parameter(Mandatory)] [string]$Server
    )

    $ouObj = Get-TargetOUByName -OuName $OuName -DomainDN $DomainDN -Server $Server

    if ($ouObj) {
        Write-Host "OU found: $($ouObj.DistinguishedName)" -ForegroundColor Green
        return $ouObj
    }

    $directDN = "OU=$OuName,$DomainDN"
    Write-Host "OU '$OuName' not found. Creating '$directDN'..." -ForegroundColor Yellow
    $ouObj = New-ADOrganizationalUnit -Name $OuName -Path $DomainDN -Server $Server -PassThru
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
        [Parameter(Mandatory)] [string]$Server,
        [string]$LogonScript,
        [bool]$ChangePasswordAtNextLogon,
        [bool]$PasswordNeverExpires
    )

    $splat = @{ Identity = $Identity; Server = $Server }
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
            Password       = ''
        },
        [PSCustomObject]@{
            FirstName      = 'Marie'
            LastName       = 'Pierre'
            SamAccountName = 'mpierre'
            Password       = ''
        }
    )

    try {
        $templateRows | Export-Csv -LiteralPath $outPath -NoTypeInformation -Encoding UTF8
        Write-Host "CSV model created at '$outPath'." -ForegroundColor Green
        Write-Host "Columns: FirstName, LastName, SamAccountName, Password (fill in a unique password for each user)." -ForegroundColor Yellow

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
        $ouObj = Invoke-Ensure-TargetOU -OuName $ouName -DomainDN $DomainCtx.DistinguishedName -Server $DomainCtx.Server
    }
    catch {
        Invoke-Pause-OnError -Message "Failed to verify or create OU '$ouName': $($_.Exception.Message)"
        return
    }

    $logonScript = Get-LogonScriptChoice

    $mustChangeInput = Read-Host "User must change password at next logon? [y/N]"
    $mustChange      = $mustChangeInput -match '^(Y|Yes)$'
    $neverExpires    = $false

    $csvPathInput = (Read-Host 'Enter full CSV path (columns: FirstName,LastName,SamAccountName,Password) or leave blank for auto-generate').Trim('"').Trim()

    if (-not [string]::IsNullOrWhiteSpace($csvPathInput)) {
        if (-not (Test-Path -LiteralPath $csvPathInput -PathType Leaf)) {
            Invoke-Pause-OnError -Message "CSV file not found: $csvPathInput"
            return
        }

        try {
            $rawLines = @(Get-Content -LiteralPath $csvPathInput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($rawLines.Count -eq 0) {
                Invoke-Pause-OnError -Message "CSV file is empty: $csvPathInput"
                return
            }

            $firstRow = $rawLines[0] | ConvertFrom-Csv -Header 'Column1','Column2','Column3','Column4'
            if ($firstRow.Column1 -eq 'FirstName' -and $firstRow.Column2 -eq 'LastName' -and
                $firstRow.Column3 -eq 'SamAccountName' -and $firstRow.Column4 -eq 'Password') {
                $rows = @(Import-Csv -LiteralPath $csvPathInput)
            }
            else {
                $rows = @(Import-Csv -LiteralPath $csvPathInput -Header 'FirstName','LastName','SamAccountName','Password')
            }
        }
        catch {
            Invoke-Pause-OnError -Message "Failed to read CSV file '$csvPathInput': $($_.Exception.Message)"
            return
        }

        if ($rows.Count -eq 0) {
            Invoke-Pause-OnError -Message "CSV file contains no user rows: $csvPathInput"
            return
        }

        foreach ($row in $rows) {
            $requiredColumns = @('FirstName', 'LastName', 'SamAccountName', 'Password')
            $missingColumns = @($requiredColumns | Where-Object { -not $row.PSObject.Properties[$_] })
            if ($missingColumns.Count -gt 0) {
                Write-Warning "Skipping a CSV row because required columns are missing: $($missingColumns -join ', ')."
                continue
            }

            $fn      = ([string]$row.FirstName).Trim()
            $ln      = ([string]$row.LastName).Trim()
            $sam     = ([string]$row.SamAccountName).Trim()
            $rowpwd  = [string]$row.Password
            if ([string]::IsNullOrWhiteSpace($fn) -or [string]::IsNullOrWhiteSpace($ln) -or
                [string]::IsNullOrWhiteSpace($sam) -or [string]::IsNullOrWhiteSpace($rowpwd)) {
                Write-Warning "Skipping a CSV row with an empty first name, last name, username, or password."
                continue
            }

            if (Get-ADUser -Identity $sam -Server $DomainCtx.Server -ErrorAction SilentlyContinue) {
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
                    -Server $DomainCtx.Server `
                    -AccountPassword $securePwd `
                    -Enabled $true | Out-Null
            }
            catch {
                Invoke-Pause-OnError -Message "Failed to add user '$sam': $($_.Exception.Message)"
                continue
            }

            try {
                Invoke-Apply-UserOptions -Identity $sam -Server $DomainCtx.Server -LogonScript $logonScript -ChangePasswordAtNextLogon $mustChange -PasswordNeverExpires $neverExpires
                Write-Host "Created user '$sam' ($display)." -ForegroundColor Green
            }
            catch {
                Invoke-Pause-OnError -Message "User '$sam' was created, but applying account options failed: $($_.Exception.Message)"
            }
        }
    }
    else {
        $countInput = Read-Host 'Enter number of users to generate (e.g. 1, 10, 50)'
        [int]$count = 0
        if (-not [int]::TryParse($countInput, [ref]$count) -or $count -lt 1) {
            Invoke-Pause-OnError -Message "Count must be a whole number of at least 1."
            return
        }

        $prefix = (Read-Host "Enter username prefix [default: $ouName]").Trim()
        if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = $ouName }

        $securePwd = Read-Host "Enter default password for generated users" -AsSecureString

        for ($i = 1; $i -le $count; $i++) {
            $uid = $i.ToString("D3")
            $sam = "$prefix$uid"
            $display = "$ouName $i"
            $upn = "$sam@$($DomainCtx.DnsRoot)"

            if (Get-ADUser -Identity $sam -Server $DomainCtx.Server -ErrorAction SilentlyContinue) {
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
                    -Server $DomainCtx.Server `
                    -AccountPassword $securePwd `
                    -Enabled $true | Out-Null
            }
            catch {
                Invoke-Pause-OnError -Message "[$i/$count] Failed to add user '$sam': $($_.Exception.Message)"
                continue
            }

            try {
                Invoke-Apply-UserOptions -Identity $sam -Server $DomainCtx.Server -LogonScript $logonScript -ChangePasswordAtNextLogon $mustChange -PasswordNeverExpires $neverExpires
                Write-Host "[$i/$count] Created user '$sam' ($display)." -ForegroundColor Green
            }
            catch {
                Invoke-Pause-OnError -Message "User '$sam' was created, but applying account options failed: $($_.Exception.Message)"
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
        $ouName = (Read-Host "Enter OU name or distinguished name (leave blank for entire domain)").Trim()
        if ([string]::IsNullOrWhiteSpace($ouName)) {
            $users = Get-ADUser -Filter * -Server $DomainCtx.Server -Properties $props | Sort-Object SamAccountName
        }
        else {
            try {
                $ouObj = Get-TargetOUByName -OuName $ouName -DomainDN $DomainCtx.DistinguishedName -Server $DomainCtx.Server
            }
            catch {
                Invoke-Pause-OnError -Message $_.Exception.Message
                return
            }
            if (-not $ouObj) {
                Invoke-Pause-OnError -Message "OU '$ouName' not found."
                return
            }
            $users = Get-ADUser -Filter * -SearchBase $ouObj.DistinguishedName -Server $DomainCtx.Server -Properties $props | Sort-Object SamAccountName
        }
    }
    elseif ($mode -eq '2') {
        $term = (Read-Host "Enter search text (SamAccountName, GivenName, Surname, or DisplayName)").Trim()
        if ([string]::IsNullOrWhiteSpace($term)) {
            Invoke-Pause-OnError -Message "Search text cannot be empty."
            return
        }
        $escapedTerm = $term.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29').Replace([string][char]0, '\00')
        $ldapFilter = "(|(sAMAccountName=*$escapedTerm*)(displayName=*$escapedTerm*)(givenName=*$escapedTerm*)(sn=*$escapedTerm*))"
        $users = Get-ADUser -LDAPFilter $ldapFilter -Server $DomainCtx.Server -Properties $props | Sort-Object SamAccountName
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

    $user = Get-ADUser -Identity $sam -Server $DomainCtx.Server -Properties DisplayName, GivenName, Surname, ScriptPath, Enabled, PasswordNeverExpires, UserPrincipalName -ErrorAction SilentlyContinue
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
        $setParams['Server'] = $DomainCtx.Server
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
            Set-ADAccountPassword -Identity $user.SamAccountName -Server $DomainCtx.Server -NewPassword $sec -Reset
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