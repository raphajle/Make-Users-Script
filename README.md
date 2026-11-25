# Make-Users-Script

An interactive PowerShell tool for managing Active Directory users. It can create users individually or from a CSV, list and export users, edit existing accounts, and generate a CSV template.

## Requirements

- Windows PowerShell
- The Active Directory PowerShell module (RSAT / AD DS tools)
- An account with the required permissions to create and manage users and OUs
- Run PowerShell as Administrator

The script attempts to detect the local Active Directory domain at startup. If detection is unavailable or you choose not to use the detected domain, it prompts for the domain name and extension.

## Create users

Choose **Create Users** from the menu, select a default target OU, and then choose CSV import or automatic username generation. The default OU is checked and created under the domain if it does not already exist. Automatic generation puts all generated users in this OU.

### CSV import across multiple OUs

CSV import supports an optional `OU` column. Each row can specify a different OU, allowing one import to create users in multiple OUs.

```csv
FirstName,LastName,SamAccountName,Password,OU
Alex,Martin,amartin,ReplaceWithAUniquePassword,Students
Jamie,Lee,jlee,ReplaceWithAUniquePassword,"OU=Sales,DC=example,DC=com"
Taylor,Kim,tkim,ReplaceWithAUniquePassword,
```

- `OU` may contain an OU name or its distinguished name (DN).
- A blank `OU` uses the default target OU selected when the workflow starts.
- An existing OU name must identify exactly one OU in the domain. If a simple OU name is not found, the script creates it directly under the domain.
- A DN must identify an existing OU; missing DNs are not created.
- The `OU` column is optional. Existing CSV files with `FirstName`, `LastName`, `SamAccountName`, and `Password` continue to use the selected default OU.
- CSV files may include a header row. Headerless files with four or five columns are also accepted, in the same column order.

Use **Export CSV Model / Template** from the menu for a sample CSV. Fill in a unique password for each user before importing. Passwords in CSV files are plain text, so protect the file appropriately and remove it securely when it is no longer needed.

Rows with missing required values, an unresolved or ambiguous OU, or a username that already exists are skipped with a warning. The workflow also prompts for password-change and logon-script options.

## Other menu options

- **List Existing Users**: list users in a selected OU or search across the domain; optionally export the results to CSV.
- **Edit an Existing User**: update account details, status, logon script, or password.
- **Export CSV Model / Template**: create a sample CSV import file.
- **Switch Target Domain**: connect the tool to another domain.

## Run

Open an elevated PowerShell window, change to the directory containing the script, and run:

```powershell
.\Make-Users-Script.ps1
```
