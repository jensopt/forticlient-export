# FortiClient VPN connection export (IPsec + SSL VPN) to .reg, with a small terminal UI.
#   fct-export                            interactive picker
#   fct-export -List                      list connections and exit
#   fct-export -Name 'Contoso*' -StripPsk export without the picker
#   fct-export -?                         help

$script:RegRoot   = 'SOFTWARE\Fortinet\FortiClient'
$script:TypePaths = [ordered]@{ IPsec = 'IPSec\Tunnels'; SSL = 'Sslvpn\Tunnels' }

# Encrypted values in the export. FortiClient's encryption is reversible: treat them as passwords.
$script:PskValues  = @('AuthKey')                                 # IPsec pre-shared key
$script:UserValues = @('User', 'Pass', 'DATA1', 'DATA2', 'DATA3')  # saved user login (IPsec / SSL VPN)

#region Data

function Get-FctTunnel {
    $result = foreach ($type in $script:TypePaths.Keys) {
        $psPath = "HKLM:\$script:RegRoot\$($script:TypePaths[$type])"
        if (-not (Test-Path $psPath)) { continue }

        foreach ($key in Get-ChildItem $psPath) {
            if ($type -eq 'IPsec') {
                $p1 = Join-Path $key.PSPath 'P1'
                $v  = if (Test-Path $p1) { Get-ItemProperty $p1 } else { $null }
                $gw = $v.RemoteGW; $sorted = $v.RemoteGWSorted; $sso = $v.sso_enabled
            }
            else {
                $v  = Get-ItemProperty $key.PSPath
                $gw = $v.Server;   $sorted = $v.ServerSorted;   $sso = $v.sso_enabled
            }

            [pscustomobject]@{
                Type     = $type
                Name     = $key.PSChildName
                Gateway  = $gw
                SSO      = ($sso -eq 1)
                # Known trap: after editing a connection, *Sorted can keep the old gateway
                GwSorted = ($sorted -and $gw -and ($sorted -ne $gw))
                RegPath  = "HKLM\$script:RegRoot\$($script:TypePaths[$type])\$($key.PSChildName)"
                PSPath   = $key.PSPath
            }
        }
    }
    @($result | Sort-Object Type, Name)
}

function Export-FctTunnel {
    param(
        [Parameter(Mandatory)] $Tunnel,
        [Parameter(Mandatory)] [string]$Folder,
        [bool]$RemovePsk,
        [bool]$RemoveUser
    )

    if (-not (Test-Path $Folder)) { New-Item -ItemType Directory -Path $Folder -Force | Out-Null }

    $invalid  = [IO.Path]::GetInvalidFileNameChars()
    $safeName = -join ($Tunnel.Name.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { '_' } else { $_ } })
    $suffix   = if ($RemovePsk) { '_noPSK' } else { '' }
    $file     = Join-Path $Folder ("{0}_{1}_{2}{3}.reg" -f (Get-Date -Format 'yyyyMMdd'), $Tunnel.Type, $safeName, $suffix)

    $out = & reg.exe export $Tunnel.RegPath $file /y 2>&1
    if ($LASTEXITCODE -ne 0) { throw "reg export failed for '$($Tunnel.Name)': $out" }

    $secrets = @()
    if ($RemovePsk)  { $secrets += $script:PskValues }
    if ($RemoveUser) { $secrets += $script:UserValues }

    $removed = 0
    if ($secrets.Count -gt 0) {
        $pattern  = '^"(' + (($secrets | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')"='
        $lines    = Get-Content -LiteralPath $file -Encoding Unicode
        $keep     = New-Object System.Collections.Generic.List[string]
        $skipCont = $false
        foreach ($line in $lines) {
            if ($skipCont) { $skipCont = $line.EndsWith('\'); continue }   # continuation of a hex value
            if ($line -match $pattern) { $removed++; $skipCont = $line.EndsWith('\'); continue }
            $keep.Add($line)
        }
        # regedit format = UTF-16 LE with BOM
        Set-Content -LiteralPath $file -Value $keep -Encoding Unicode
    }

    [pscustomobject]@{ Name = $Tunnel.Name; File = $file; Removed = $removed }
}

function Show-FctTunnelDetail {
    param([Parameter(Mandatory)] $Tunnel)

    $hidden = $script:PskValues + $script:UserValues
    Write-Host ''
    Write-Host "$($Tunnel.Type) - $($Tunnel.Name)" -ForegroundColor Cyan
    Write-Host $Tunnel.RegPath -ForegroundColor DarkGray

    $keys = @(Get-Item $Tunnel.PSPath) + @(Get-ChildItem $Tunnel.PSPath -Recurse)
    foreach ($k in $keys) {
        $rel = $k.Name.Substring($k.Name.IndexOf($Tunnel.Name) + $Tunnel.Name.Length)
        if (-not $rel) { $rel = '\' }
        $names = $k.GetValueNames() | Sort-Object
        if (-not $names) { continue }
        Write-Host "  [$rel]" -ForegroundColor Yellow
        foreach ($n in $names) {
            $val = $k.GetValue($n)
            $shown = if ($hidden -contains $n) {
                if ("$val") { '<hidden>' } else { '<empty>' }
            }
            elseif ($k.GetValueKind($n) -eq 'DWord') { '{0} (0x{0:X})' -f $val }
            else { "$val" }
            Write-Host ('    {0,-28} {1}' -f $n, $shown)
        }
    }
}

#endregion

#region UI

function ConvertFrom-FctSelection {
    param([string]$Text, [int]$Max)
    $idx = foreach ($part in ($Text -split '[,; ]+' | Where-Object { $_ })) {
        if ($part -match '^(\d+)-(\d+)$') { [int]$Matches[1]..[int]$Matches[2] }
        elseif ($part -match '^\d+$')     { [int]$part }
        else { throw "Invalid selection: '$part'" }
    }
    $idx = @($idx | Sort-Object -Unique)
    $bad = @($idx | Where-Object { $_ -lt 1 -or $_ -gt $Max })
    if ($bad) { throw "Out of range: $($bad -join ', ') (1-$Max)" }
    $idx
}

function Write-FctTable {
    param($Items)
    $maxGw = 45
    $wName = [Math]::Max(4, ($Items | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum)
    Write-Host ('  {0,3}  {1,-5}  {2}  {3,-3}  Gateway' -f '#', 'Type', 'Name'.PadRight($wName), 'SSO') -ForegroundColor DarkGray
    $prevType = $null
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $t = $Items[$i]
        if ($prevType -and $t.Type -ne $prevType) { Write-Host '' }   # blank line between IPsec and SSL
        $prevType = $t.Type
        $sso   = if ($t.SSO) { 'yes' } else { '' }
        $gw    = ("$($t.Gateway)" -replace ';', ', ')
        if ($gw.Length -gt $maxGw) { $gw = $gw.Substring(0, $maxGw - 3) + '...' }
        $color = if ($t.Type -eq 'IPsec') { 'White' } else { 'Gray' }
        Write-Host ('  {0,3}  {1,-5}  {2}  {3,-3}  {4}' -f ($i + 1), $t.Type, $t.Name.PadRight($wName), $sso, $gw) -ForegroundColor $color -NoNewline
        if ($t.GwSorted) { Write-Host '  ! *Sorted differs' -ForegroundColor Red } else { Write-Host '' }
    }
}

function Start-FctTui {
    param([string]$Folder, [bool]$RemovePsk, [bool]$RemoveUser)

    $filter  = ''
    $message = ''
    $all     = Get-FctTunnel

    while ($true) {
        Clear-Host
        $view = @(if ($filter) { $all | Where-Object { $_.Name -like "*$filter*" -or "$($_.Gateway)" -like "*$filter*" } } else { $all })

        Write-Host '=== FortiClient VPN export ===' -ForegroundColor Cyan
        Write-Host ("  Output folder : {0}" -f $Folder)
        if ($RemovePsk) { Write-Host '  PSK           : REMOVED from export' -ForegroundColor Green }
        else            { Write-Host '  PSK           : kept (treat the export as a password)' -ForegroundColor Yellow }
        if ($RemoveUser) { Write-Host '  User login    : removed (User/Pass/DATA1-3)' -ForegroundColor Green }
        else             { Write-Host '  User login    : KEPT' -ForegroundColor Yellow }
        if ($filter) { Write-Host ("  Filter        : *{0}*" -f $filter) -ForegroundColor Magenta }
        Write-Host ''

        if ($view.Count -eq 0) { Write-Host '  (no connections found)' -ForegroundColor DarkGray }
        else { Write-FctTable -Items $view }

        Write-Host ''
        Write-Host '  1,3,5-7 = export   a = all shown   d <nr> = details   /text = filter   / = clear filter' -ForegroundColor DarkGray
        Write-Host '  p = PSK on/off   u = user login on/off   o = output folder   e = open folder   r = reload   q = quit' -ForegroundColor DarkGray
        if ($message) { Write-Host ''; Write-Host $message; $message = '' }

        $in = (Read-Host "`nChoice").Trim()
        try {
            switch -Regex ($in) {
                '^q$'          { return }
                '^r$'          { $all = Get-FctTunnel; break }
                '^p$'          { $RemovePsk = -not $RemovePsk; break }
                '^u$'          { $RemoveUser = -not $RemoveUser; break }
                '^e$'          { if (-not (Test-Path $Folder)) { New-Item -ItemType Directory $Folder -Force | Out-Null }; Start-Process explorer.exe $Folder; break }
                '^o$'          { $new = Read-Host "New output folder (Enter = $Folder)"; if ($new) { $Folder = $new.Trim('"') }; break }
                '^/$'          { $filter = ''; break }
                '^/(.+)$'      { $filter = $Matches[1]; break }
                '^d\s*(\d+)$'  {
                    $n = ConvertFrom-FctSelection -Text $Matches[1] -Max $view.Count
                    Show-FctTunnelDetail -Tunnel $view[$n[0] - 1]
                    Read-Host "`nEnter = back" | Out-Null
                    break
                }
                '^(a|[\d,;\s-]+)$' {
                    $sel = if ($in -eq 'a') { $view } else { ConvertFrom-FctSelection -Text $in -Max $view.Count | ForEach-Object { $view[$_ - 1] } }
                    if (-not $sel) { break }
                    $lines = foreach ($t in $sel) {
                        $r = Export-FctTunnel -Tunnel $t -Folder $Folder -RemovePsk $RemovePsk -RemoveUser $RemoveUser
                        $note = if ($r.Removed) { "  ($($r.Removed) secret value(s) removed)" } else { '' }
                        "  OK  {0}  ->  {1}{2}" -f $r.Name, (Split-Path $r.File -Leaf), $note
                    }
                    $message = "Exported to $Folder`n" + ($lines -join "`n")
                    break
                }
                '^$'           { break }
                default        { $message = "Unknown choice: '$in'" }
            }
        }
        catch { $message = "ERROR: $($_.Exception.Message)" }
    }
}

#endregion

function fct-export {
    <#
    .SYNOPSIS
        Export FortiClient VPN connections (IPsec + SSL VPN) to .reg files.

    .DESCRIPTION
        Reads HKLM:\SOFTWARE\Fortinet\FortiClient\IPSec\Tunnels and ...\Sslvpn\Tunnels and exports
        each selected connection, including its P1/P2/Proposals subkeys, with reg.exe.

        Secrets in the export:
          - The saved user login (IPsec User/Pass, SSL VPN DATA1-3) is removed by default.
            Use -KeepUserCredentials to keep it.
          - The IPsec pre-shared key (AuthKey) is kept by default, because the connection does not
            work without it. Use -StripPsk (or 'p' in the picker) to remove it.
        FortiClient encrypts these values, but that encryption is reversible: treat an export that
        contains the PSK as a password.

        Import on another PC: 'reg import <file>' as administrator (or double-click), then restart
        the FortiClient console. Delete an existing connection before importing a new version of it.

    .PARAMETER List
        List the connections and exit.

    .PARAMETER Name
        Export the connections whose name matches (wildcards allowed), without the picker.

    .PARAMETER OutDir
        Output folder. Default: %USERPROFILE%\Downloads\FortiClient-Export.

    .PARAMETER StripPsk
        Remove the IPsec pre-shared key from the export.

    .PARAMETER KeepUserCredentials
        Keep the saved user login in the export.

    .EXAMPLE
        fct-export
        Interactive picker.

    .EXAMPLE
        fct-export -Name 'Contoso*' -StripPsk -OutDir C:\Temp
        Export every connection starting with "Contoso", without the PSK.
    #>
    [CmdletBinding()]
    param(
        [switch]$List,
        [string[]]$Name,
        [string]$OutDir = (Join-Path $env:USERPROFILE 'Downloads\FortiClient-Export'),
        [switch]$StripPsk,
        [switch]$KeepUserCredentials
    )

    $ErrorActionPreference = 'Stop'

    if ($List) {
        $t = Get-FctTunnel
        if ($t.Count -eq 0) { Write-Host 'No FortiClient connections found.'; return }
        Write-FctTable -Items $t
        return
    }

    if ($Name) {
        $t = Get-FctTunnel | Where-Object { $n = $_.Name; @($Name | Where-Object { $n -like $_ }).Count -gt 0 }
        if (-not $t) { throw "No connection found for: $($Name -join ', ')" }
        foreach ($x in $t) {
            Export-FctTunnel -Tunnel $x -Folder $OutDir -RemovePsk ([bool]$StripPsk) -RemoveUser (-not $KeepUserCredentials)
        }
        return
    }

    Start-FctTui -Folder $OutDir -RemovePsk ([bool]$StripPsk) -RemoveUser (-not $KeepUserCredentials)
}

Export-ModuleMember -Function fct-export
