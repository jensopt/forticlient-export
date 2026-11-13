# forticlient-export installer / updater:
#   irm https://raw.githubusercontent.com/jensopt/forticlient-export/main/install.ps1 | iex
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $repo   = 'https://raw.githubusercontent.com/jensopt/forticlient-export/main'
    $module = 'FortiClientExport'
    $docs   = [Environment]::GetFolderPath('MyDocuments')
    $tmp    = Join-Path ([IO.Path]::GetTempPath()) ('forticlient-export-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $tmp | Out-Null

    try {
        foreach ($f in "$module.psm1", "$module.psd1") {
            Invoke-WebRequest "$repo/$module/$f" -OutFile (Join-Path $tmp $f) -UseBasicParsing
        }

        # PowerShell 7 and Windows PowerShell 5.1 each have their own user module folder.
        foreach ($ps in 'PowerShell', 'WindowsPowerShell') {
            $modDir = Join-Path $docs "$ps\Modules\$module"
            New-Item -ItemType Directory -Force $modDir | Out-Null
            Copy-Item (Join-Path $tmp "$module.ps*1") $modDir -Force
            Write-Host "  module -> $modDir"
        }

        Import-Module $module -Global -Force -DisableNameChecking   # fct-export is not Verb-Noun on purpose
        Write-Host "`nDone. Type 'fct-export' to start, 'fct-export -?' for help. No PowerShell profile was changed." -ForegroundColor Green
    }
    catch { Write-Host "`nInstall failed: $($_.Exception.Message)" -ForegroundColor Red }
    finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
