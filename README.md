# forticlient-export

A small terminal picker that exports FortiClient VPN connections (IPsec and SSL VPN) on Windows
to `.reg` files, so you can share a working connection or document it.
Type `fct-export`, pick one or more connections, done.

```
=== FortiClient VPN export ===
  Output folder : C:\Users\you\Downloads\FortiClient-Export
  PSK           : kept (treat the export as a password)
  User login    : removed (User/Pass/DATA1-3)

    #  Type   Name                 SSO  Gateway
    1  IPsec  Contoso IPsec             vpn.contoso.com
    2  IPsec  Contoso IPsec SSO    yes  vpn.contoso.com
    3  IPsec  Fabrikam IPsec       yes  vpn1.fabrikam.com, vpn2.fabrikam.com  ! *Sorted differs

    4  SSL    Contoso SSL VPN           vpn.contoso.com:443

  1,3,5-7 = export   a = all shown   d <nr> = details   /text = filter   / = clear filter
  p = PSK on/off   u = user login on/off   o = output folder   e = open folder   r = reload   q = quit
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
| `1,3,5-7` | export these connections (one `.reg` file each) |
| `a` | export all connections shown |
| `d <nr>` | show every setting of a connection (secrets masked) |
| `/text` | filter on name or gateway; `/` clears the filter |
| `p` | remove/keep the IPsec pre-shared key in the export |
| `u` | remove/keep the saved user login in the export |
| `o` / `e` | change / open the output folder |
| `r` / `q` | reload / quit |

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
| `AuthKey` (IPsec) | pre-shared key | **kept**, the connection needs it. Remove with `p` / `-StripPsk` |
| `User`, `Pass` (IPsec) | saved username/password | removed. Keep with `u` / `-KeepUserCredentials` |
| `DATA1`-`DATA3` (SSL VPN) | saved login | removed. Keep with `u` / `-KeepUserCredentials` |

## Importing on another PC

1. If the connection already exists in FortiClient, delete it first.
2. Run `reg import <file>.reg` as administrator, or double-click the file.
3. Restart the FortiClient console.

On a PC managed by FortiClient EMS, the EMS profile can overrule or remove locally added connections.

## Tips

- **`! *Sorted differs`**: FortiClient keeps `RemoteGWSorted` (IPsec) or `ServerSorted` (SSL VPN) next to
  the gateway. After a connection is edited, that copy can keep the old gateway list, and FortiClient
  keeps connecting there. Delete the connection and create it again.
- `d <nr>` is handy to document a connection: DWORDs are shown as decimal and hex.
- Use **Windows Terminal**. The legacy console host renders the picker poorly.

## Uninstall

```powershell
$docs = [Environment]::GetFolderPath('MyDocuments')
'PowerShell', 'WindowsPowerShell' | ForEach-Object { Remove-Item "$docs\$_\Modules\FortiClientExport" -Recurse -Force -ErrorAction SilentlyContinue }
```
