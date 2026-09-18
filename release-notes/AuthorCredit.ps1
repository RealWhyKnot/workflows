#!/usr/bin/env pwsh

function Get-AuthorCredit {
    param([string] $Login, [string] $Name)

    if (-not $Login) { return $Name }
    return "[$Login](https://github.com/$Login)"
}
