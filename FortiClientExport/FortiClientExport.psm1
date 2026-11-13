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

# Non-ASCII glyphs as char codes, so the file stays ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI).
$script:E    = [char]27
$script:Dot  = [string][char]0x00B7   # middle dot
$script:Line = [string][char]0x2500   # box drawing horizontal
$script:Up   = [string][char]0x2191
$script:Down = [string][char]0x2193
$script:Right = [string][char]0x2192
$script:Left = [string][char]0x2190

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

function Get-FctDetailLines {
    param([Parameter(Mandatory)] $Tunnel)

    $e      = $script:E
    $hidden = $script:PskValues + $script:UserValues
    $out    = New-Object System.Collections.Generic.List[string]
    $out.Add("  $e[90m$($Tunnel.RegPath)$e[0m")

    $keys = @(Get-Item $Tunnel.PSPath) + @(Get-ChildItem $Tunnel.PSPath -Recurse)
    foreach ($k in $keys) {
        $rel = $k.Name.Substring($k.Name.IndexOf($Tunnel.Name) + $Tunnel.Name.Length)
        if (-not $rel) { $rel = '\' }
        $names = $k.GetValueNames() | Sort-Object
        if (-not $names) { continue }
        $out.Add('')
        $out.Add("  $e[33m[$rel]$e[0m")
        foreach ($n in $names) {
            $val = $k.GetValue($n)
            $shown = if ($hidden -contains $n) {
                if ("$val") { "$e[90m<hidden>$e[0m" } else { "$e[90m<empty>$e[0m" }
            }
            elseif ($k.GetValueKind($n) -eq 'DWord') { '{0} (0x{0:X})' -f $val }
            else { "$val" }
            $out.Add(('    {0,-28} {1}' -f $n, $shown))
        }
    }
    $out
}

#endregion

#region Plain output (-List)

function Write-FctTable {
    param($Items)
    $maxGw = 45
    $wName = [Math]::Max(4, ($Items | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum)
    Write-Host ('  {0,-5}  {1}  {2,-3}  Gateway' -f 'Type', 'Name'.PadRight($wName), 'SSO') -ForegroundColor DarkGray
    $prevType = $null
    foreach ($t in $Items) {
        if ($prevType -and $t.Type -ne $prevType) { Write-Host '' }
        $prevType = $t.Type
        $sso = if ($t.SSO) { 'yes' } else { '' }
        $gw  = ("$($t.Gateway)" -replace ';', ', ')
        if ($gw.Length -gt $maxGw) { $gw = $gw.Substring(0, $maxGw - 3) + '...' }
        Write-Host ('  {0,-5}  {1}  {2,-3}  {3}' -f $t.Type, $t.Name.PadRight($wName), $sso, $gw) -NoNewline
        if ($t.GwSorted) { Write-Host '  ! *Sorted differs' -ForegroundColor Red } else { Write-Host '' }
    }
}

#endregion

#region Picker

# The picker reads keys and writes frames through these two script blocks, so it can be driven
# by a test script. Defaults: the real console.
$script:ReadKey = { [Console]::ReadKey($true) }
$script:Write   = { param($s) [Console]::Write($s) }

function Get-FctWindowSize {
    try   { [pscustomobject]@{ Width = [Console]::WindowWidth; Height = [Console]::WindowHeight } }
    catch { [pscustomobject]@{ Width = 120; Height = 40 } }   # no console attached (tests)
}

function Read-FctInput {
    param([string]$Prompt, [string]$Default)
    $e = $script:E
    $text = $Default
    & $script:Write "$e[?25h"
    try {
        while ($true) {
            & $script:Write ("$e[H$e[J`n  $e[1m$Prompt$e[0m`n`n  > $text`n`n  $e[90mEnter accept $script:Dot Esc cancel$e[0m" + "$e[4;$($text.Length + 5)H")
            $k = & $script:ReadKey
            switch ($k.Key) {
                'Enter'     { return $text.Trim().Trim('"') }
                'Escape'    { return $null }
                'Backspace' { if ($text) { $text = $text.Substring(0, $text.Length - 1) } }
                default     { if (-not [char]::IsControl($k.KeyChar)) { $text += $k.KeyChar } }
            }
        }
    }
    finally { & $script:Write "$e[?25l" }
}

function Show-FctDetail {
    param([Parameter(Mandatory)] $Tunnel)
    $e     = $script:E
    $lines = @(Get-FctDetailLines -Tunnel $Tunnel)
    $top   = 0
    while ($true) {
        $size   = Get-FctWindowSize
        $rows   = [Math]::Max(3, $size.Height - 6)
        $maxTop = [Math]::Max(0, $lines.Count - $rows)
        $top    = [Math]::Min([Math]::Max(0, $top), $maxTop)
        $last   = [Math]::Min($lines.Count, $top + $rows) - 1

        $frame = New-Object System.Collections.Generic.List[string]
        $frame.Add('')
        $frame.Add("  $e[1m$($Tunnel.Type) $script:Dot $($Tunnel.Name)$e[0m      $e[90m$($Tunnel.Gateway)$e[0m")
        $frame.Add('  ' + ($script:Line * [Math]::Min(70, $size.Width - 4)))
        foreach ($l in $lines[$top..$last]) { $frame.Add($l) }
        $frame.Add('')
        $pos = if ($lines.Count -gt $rows) { "   ($($top + 1)-$($last + 1) of $($lines.Count))" } else { '' }
        $frame.Add("  $e[90m$script:Up/$script:Down scroll $script:Dot Esc/$script:Left back$pos$e[0m")
        & $script:Write ("$e[H$e[J" + ($frame -join "`n"))

        $k = & $script:ReadKey
        switch ($k.Key) {
            'UpArrow'    { $top-- }
            'DownArrow'  { $top++ }
            'PageUp'     { $top -= $rows }
            'PageDown'   { $top += $rows }
            'Home'       { $top = 0 }
            'End'        { $top = $maxTop }
            'Escape'     { return }
            'LeftArrow'  { return }
            'Backspace'  { return }
            'Q'          { return }
        }
    }
}

function Start-FctTui {
    param([string]$Folder, [bool]$RemovePsk, [bool]$RemoveUser)

    $e      = $script:E
    $all    = @(Get-FctTunnel)
    $marked = New-Object 'System.Collections.Generic.HashSet[string]'
    $filter = ''; $index = 0; $top = 0; $status = ''

    & $script:Write "$e[?1049h$e[?25l"   # alternate screen, hide cursor
    try {
        while ($true) {
            $shown = @($all | Where-Object { -not $filter -or $_.Name -like "*$filter*" -or "$($_.Gateway)" -like "*$filter*" })
            if ($index -ge $shown.Count) { $index = [Math]::Max(0, $shown.Count - 1) }

            $size = Get-FctWindowSize
            $rows = [Math]::Max(3, $size.Height - 10)
            if ($index -lt $top) { $top = $index }
            if ($index -ge $top + $rows) { $top = $index - $rows + 1 }
            $top = [Math]::Max(0, [Math]::Min($top, $shown.Count - $rows))

            $wName = 4
            foreach ($t in $shown) { if ($t.Name.Length -gt $wName) { $wName = $t.Name.Length } }
            # "  > [x] IPsec  <name> SSO <gateway>  ! *Sorted differs"
            $wGw = [Math]::Max(12, $size.Width - $wName - 40)

            $psk = if ($RemovePsk)  { "$e[32mremoved$e[0m" } else { "$e[33mkept$e[0m" }
            $usr = if ($RemoveUser) { "$e[32mremoved$e[0m" } else { "$e[33mkept$e[0m" }
            $mrk = if ($marked.Count) { "$e[1;32m$($marked.Count) marked$e[0m" } else { "$e[90m0 marked$e[0m" }
            $maxF = [Math]::Max(20, $size.Width - 60)
            $fold = if ($Folder.Length -gt $maxF) { '...' + $Folder.Substring($Folder.Length - $maxF + 3) } else { $Folder }

            $frame = New-Object System.Collections.Generic.List[string]
            $frame.Add('')
            $frame.Add("  $e[1mFortiClient $script:Dot export connections$e[0m      filter: $e[33m$filter$e[0m_")
            $frame.Add("  PSK: $psk   user login: $usr   $mrk   $e[90m$script:Right $fold$e[0m")
            $frame.Add('  ' + ($script:Line * [Math]::Min(90, $size.Width - 4)))

            if (-not $shown) { $frame.Add("  $e[90m(no match)$e[0m") }
            $last = [Math]::Min($shown.Count, $top + $rows) - 1
            for ($i = $top; $i -le $last; $i++) {
                $t   = $shown[$i]
                $sel = ($i -eq $index)
                $on  = $marked.Contains($t.RegPath)
                $mk  = if ($on) { '[x]' } else { '[ ]' }
                $sso = if ($t.SSO) { 'SSO' } else { '' }
                $gw  = ("$($t.Gateway)" -replace ';', ', ')
                if ($gw.Length -gt $wGw) { $gw = $gw.Substring(0, $wGw - 3) + '...' }
                $warn = if ($t.GwSorted) { "  $e[31m! *Sorted differs$e[0m" } else { '' }

                if ($sel) {
                    $row = '> {0} {1,-5} {2} {3,-3} {4}' -f $mk, $t.Type, $t.Name.PadRight($wName), $sso, $gw.PadRight($wGw)
                    $frame.Add("  $e[7m$row$e[0m$warn")
                }
                else {
                    $mkC   = if ($on) { "$e[32m$mk$e[0m" } else { "$e[90m$mk$e[0m" }
                    $typeC = if ($t.Type -eq 'IPsec') { "$e[36m{0,-5}$e[0m" -f $t.Type } else { "$e[35m{0,-5}$e[0m" -f $t.Type }
                    $frame.Add(('    {0} {1} {2} {3,-3} {4}{5}' -f $mkC, $typeC, $t.Name.PadRight($wName), $sso, $gw, $warn))
                }
            }

            $frame.Add('')
            if ($status) { $frame.Add("  $status") }
            elseif ($shown.Count -gt $rows) { $frame.Add("  $e[90m$($top + 1)-$($last + 1) of $($shown.Count)$e[0m") }
            else { $frame.Add("  $e[90m$($shown.Count) of $($all.Count) connections$e[0m") }
            $frame.Add("  $e[90m$script:Up/$script:Down move $script:Dot type to filter $script:Dot Space mark $script:Dot Enter export $script:Dot $script:Right details $script:Dot Esc clear/quit$e[0m")
            $frame.Add("  $e[90mTab PSK $script:Dot Ctrl+U user login $script:Dot Ctrl+A mark all $script:Dot Ctrl+O folder $script:Dot Ctrl+E open folder $script:Dot Ctrl+R reload$e[0m")
            & $script:Write ("$e[H$e[J" + ($frame -join "`n"))

            $k = & $script:ReadKey
            $status = ''
            $ctrl = ($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0
            try {
                if ($ctrl) {
                    switch ($k.Key) {
                        'A' {
                            $allOn = $shown.Count -gt 0 -and @($shown | Where-Object { -not $marked.Contains($_.RegPath) }).Count -eq 0
                            foreach ($t in $shown) { if ($allOn) { [void]$marked.Remove($t.RegPath) } else { [void]$marked.Add($t.RegPath) } }
                        }
                        'U' { $RemoveUser = -not $RemoveUser }
                        'O' { $new = Read-FctInput -Prompt 'Output folder' -Default $Folder; if ($new) { $Folder = $new } }
                        'E' {
                            if (-not (Test-Path $Folder)) { New-Item -ItemType Directory $Folder -Force | Out-Null }
                            Start-Process explorer.exe $Folder
                        }
                        'R' {
                            $all = @(Get-FctTunnel)
                            $exists = @($all | ForEach-Object { $_.RegPath })
                            foreach ($p in @($marked)) { if ($exists -notcontains $p) { [void]$marked.Remove($p) } }
                            $status = "$e[90mReloaded: $($all.Count) connections$e[0m"
                        }
                    }
                }
                else {
                    switch ($k.Key) {
                        'UpArrow'    { if ($index -gt 0) { $index-- } }
                        'DownArrow'  { if ($index -lt $shown.Count - 1) { $index++ } }
                        'PageUp'     { $index = [Math]::Max(0, $index - $rows) }
                        'PageDown'   { $index = [Math]::Max(0, [Math]::Min($shown.Count - 1, $index + $rows)) }
                        'Home'       { $index = 0 }
                        'End'        { $index = [Math]::Max(0, $shown.Count - 1) }
                        'Spacebar'   {
                            if ($shown) {
                                $p = $shown[$index].RegPath
                                if (-not $marked.Remove($p)) { [void]$marked.Add($p) }
                                if ($index -lt $shown.Count - 1) { $index++ }
                            }
                        }
                        'Tab'        { $RemovePsk = -not $RemovePsk }
                        'RightArrow' { if ($shown) { Show-FctDetail -Tunnel $shown[$index] } }
                        'Enter'      {
                            $sel = if ($marked.Count) { @($all | Where-Object { $marked.Contains($_.RegPath) }) }
                                   elseif ($shown)    { @($shown[$index]) }
                                   else               { @() }
                            if ($sel) {
                                $done = foreach ($t in $sel) { Export-FctTunnel -Tunnel $t -Folder $Folder -RemovePsk $RemovePsk -RemoveUser $RemoveUser }
                                $marked.Clear()
                                $what = if ($done.Count -eq 1) { $done[0].Name } else { "$($done.Count) connections" }
                                $status = "$e[32mExported $what $script:Right $fold$e[0m"
                            }
                        }
                        'Escape'     { if ($filter) { $filter = ''; $index = 0 } else { return } }
                        'Backspace'  { if ($filter) { $filter = $filter.Substring(0, $filter.Length - 1); $index = 0 } }
                        default      { if ($k.KeyChar -match '[\w\-./:]') { $filter += $k.KeyChar; $index = 0 } }
                    }
                }
            }
            catch { $status = "$e[31mERROR: $($_.Exception.Message)$e[0m" }
        }
    }
    finally { & $script:Write "$e[?25h$e[?1049l" }   # restore screen and cursor
}

#endregion

function fct-export {
    <#
    .SYNOPSIS
        Export FortiClient VPN connections (IPsec + SSL VPN) to .reg files.

    .DESCRIPTION
        Reads HKLM:\SOFTWARE\Fortinet\FortiClient\IPSec\Tunnels and ...\Sslvpn\Tunnels and exports
        each selected connection, including its P1/P2/Proposals subkeys, with reg.exe.

        Picker keys: Up/Down move, type to filter, Space mark, Enter export (marked, or the current
        row), Right details, Tab PSK on/off, Ctrl+U user login on/off, Ctrl+A mark all shown,
        Ctrl+O output folder, Ctrl+E open output folder, Ctrl+R reload, Esc clear filter / quit.

        Secrets in the export:
          - The saved user login (IPsec User/Pass, SSL VPN DATA1-3) is removed by default.
            Use -KeepUserCredentials to keep it.
          - The IPsec pre-shared key (AuthKey) is kept by default, because the connection does not
            work without it. Use -StripPsk (or Tab in the picker) to remove it.
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

    if ([Console]::IsInputRedirected) { throw 'The picker needs an interactive console. Use -List or -Name instead.' }
    Start-FctTui -Folder $OutDir -RemovePsk ([bool]$StripPsk) -RemoveUser (-not $KeepUserCredentials)
}

Export-ModuleMember -Function fct-export
