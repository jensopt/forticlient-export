# forticlient-export

A small terminal picker that exports FortiClient VPN connections (IPsec and SSL VPN) on Windows
to `.reg` files, so you can share a working connection or document it.
Type `fct-export`, move with the arrow keys, type to filter, mark with `Space`, export with `Enter`.

```
  FortiClient · export connections      filter: _
  PSK: kept   user login: removed   1 marked   → C:\Users\jhondoe\Downloads\FortiClient-Export

        Type  Name              SSO Gateway
  ──────────────────────────────────────────────────────────────────────
    [x] IPsec Contoso IPsec         vpn.contoso.com
  > [ ] IPsec Contoso IPsec SSO SSO vpn.contoso.com
    [ ] IPsec Fabrikam IPsec    SSO vpn1.fabrikam.com, vpn2.fabrikam.com  ! *Sorted differs
    [ ] SSL   Contoso SSL VPN       vpn.contoso.com:443

  4 of 4 connections
  ↑/↓ move · type to filter · Space mark · Enter export · → details · Esc clear/quit
  Tab PSK · Ctrl+U user login · Ctrl+A mark all · Ctrl+O folder · Ctrl+E open folder · Ctrl+R reload
```

## Install

Paste this into PowerShell (7 or Windows PowerShell 5.1, no admin needed):

```powershell
irm https://raw.githubusercontent.com/jensopt/forticlient-export/main/install.ps1 | iex
```

Run the same line again to **update**.

## What the installer changes

Everything is per user. Nothing needs admin rights, and **your PowerShell profile (`$PROFILE`) is
not touched**. PowerShell loads the module automatically the first time you type `fct-export`.

| What | Where |
|---|---|
| PowerShell module `FortiClientExport` | `Documents\PowerShell\Modules\FortiClientExport\` (PowerShell 7)<br>`Documents\WindowsPowerShell\Modules\FortiClientExport\` (5.1) |

## Usage

```
fct-export                                   interactive picker
fct-export -List                             list connections and exit
fct-export -Name 'Contoso*' -StripPsk        export matching connections without the picker
fct-export -Name 'Contoso SSL VPN' -OutDir C:\Temp
fct-export -?                                help
```

**In the picker:**

| Key | Action |
|---|---|
| `Up` / `Down`, `PgUp` / `PgDn`, `Home` / `End` | move |
| type letters | filter on name or gateway; `Backspace` edits the filter |
| `Space` | mark / unmark the current connection |
| `Enter` | export the marked connections, or the current one when nothing is marked (one `.reg` file each) |
| `Right` | show every setting of the connection (secrets masked); `Esc` or `Left` goes back |
| `Tab` | remove / keep the IPsec pre-shared key in the export |
| `Ctrl+U` | remove / keep the saved user login in the export |
| `Ctrl+A` | mark / unmark all connections shown |
| `Ctrl+O` / `Ctrl+E` | change / open the output folder |
| `Ctrl+R` | reload the connections from the registry |
| `Esc` | clear the filter; with an empty filter, quit |

Files are named `yyyyMMdd_<Type>_<Name>[_noPSK].reg`.

## What is exported

Each connection is exported with `reg export`, including its subkeys:

| Type | Registry key |
|---|---|
| IPsec | `HKLM\SOFTWARE\Fortinet\FortiClient\IPSec\Tunnels\<name>` (`P1`, `P2`, `Proposals`) |
| SSL VPN | `HKLM\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels\<name>` |

## Secrets

FortiClient stores some values encrypted. That encryption is reversible, so treat them as passwords.

| Value | Contents | Default |
|---|---|---|
| `AuthKey` (IPsec) | pre-shared key | **kept**, the connection needs it. Remove with `Tab` / `-StripPsk` |
| `User`, `Pass` (IPsec) | saved username/password | removed. Keep with `Ctrl+U` / `-KeepUserCredentials` |
| `DATA1`-`DATA3` (SSL VPN) | saved login | removed. Keep with `Ctrl+U` / `-KeepUserCredentials` |

## Importing on another PC

1. If the connection already exists in FortiClient, delete it first.
2. Run `reg import <file>.reg` as administrator, or double-click the file.
3. Restart the FortiClient console.

On a PC managed by FortiClient EMS, the EMS profile can overrule or remove locally added connections.

## Tips

- **`! *Sorted differs`**: FortiClient keeps `RemoteGWSorted` (IPsec) or `ServerSorted` (SSL VPN) next to
  the gateway. After a connection is edited, that copy can keep the old gateway list, and FortiClient
  keeps connecting there. Delete the connection and create it again.
- The details view (`Right`) is handy to document a connection: DWORDs are shown as decimal and hex.
- Use **Windows Terminal**. The legacy console host renders the picker poorly.

## Uninstall

```powershell
$docs = [Environment]::GetFolderPath('MyDocuments')
'PowerShell', 'WindowsPowerShell' | ForEach-Object { Remove-Item "$docs\$_\Modules\FortiClientExport" -Recurse -Force -ErrorAction SilentlyContinue }
```
