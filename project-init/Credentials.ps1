#requires -Version 5.1
function Read-ProjectCredential {
    param([string]$Account='Infobase', [string]$DefaultUserName)
    # Ask for a 1C account explicitly, without the Windows credential dialog.
    $prompt="$Account user name (1C account)"
    if ($DefaultUserName) { $prompt+=" [$DefaultUserName]" }
    $name=Read-Host $prompt
    if (-not $name) { $name=$DefaultUserName }
    if ([string]::IsNullOrWhiteSpace($name) -or $name -match '[\x00\r\n"]') {
        throw 'A non-empty 1C user name without quotes or line breaks is required.'
    }
    $password=Read-Host "$Account password (empty allowed)" -AsSecureString
    if ($null -eq $password) { throw 'Credential input cancelled.' }
    return [Management.Automation.PSCredential]::new($name,$password)
}
