# compilar.ps1
# Compila el instalador de PC Care con Inno Setup y calcula su SHA256.
# Uso:  .\instalador\compilar.ps1                     (toma la version de PCCare.ps1)
#       .\instalador\compilar.ps1 -Version 2.1.0      (exige que coincida con PCCare.ps1)
param([string]$Version)
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

$linea = Select-String -LiteralPath (Join-Path $raiz 'PCCare.ps1') -Pattern '^\$VersionApp = ''([^'']+)''' | Select-Object -First 1
if (-not $linea) { throw 'No se encontró $VersionApp en PCCare.ps1' }
$versionApp = $linea.Matches[0].Groups[1].Value
if ($Version -and $Version -ne $versionApp) {
    throw ('La versión pedida (' + $Version + ') no coincide con la de PCCare.ps1 (' + $versionApp + '). Corrige la etiqueta o el programa.')
}
$Version = $versionApp

$iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
if (-not (Test-Path -LiteralPath $iscc)) {
    Write-Host 'Instalando Inno Setup...'
    choco install innosetup --no-progress -y | Out-Host
}
if (-not (Test-Path -LiteralPath $iscc)) { throw 'No se encontró ISCC.exe de Inno Setup 6.' }

& $iscc ('/DAppVersion=' + $Version) (Join-Path $PSScriptRoot 'PCCare.iss')
if ($LASTEXITCODE -ne 0) { throw ('ISCC terminó con código ' + $LASTEXITCODE) }

$exe = Join-Path $raiz ('salida\PCCare-Setup-' + $Version + '-x64.exe')
if (-not (Test-Path -LiteralPath $exe)) { throw ('No se generó ' + $exe) }
$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLower()
[System.IO.File]::WriteAllText(($exe + '.sha256'), ($hash + '  ' + (Split-Path -Leaf $exe) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('Instalador: ' + $exe)
Write-Host ('SHA256: ' + $hash)
