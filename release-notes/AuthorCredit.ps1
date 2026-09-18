#!/usr/bin/env pwsh

function Get-AuthorCredit {
    param([string] $Login, [string] $Name)

    if (-not $Login) { return $Name }
    if ($Login.EndsWith('[bot]')) { return $Login }
    return "[$Login](https://github.com/$Login)"
}
