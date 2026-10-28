#Requires -Version 7.4
Set-StrictMode -Version Latest

function Get-AuthorCredit {
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Login, [string] $Name)

    if (-not $Login) { return $Name }
    if ($Login.EndsWith('[bot]')) { return $Login }
    return "[$Login](https://github.com/$Login)"
}

Export-ModuleMember -Function Get-AuthorCredit
