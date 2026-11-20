# compilar.ps1 (lanzador)
# Compila lanzador\PCCare.exe con el csc.exe que ya trae Windows (.NET Framework 4). No instala nada.
# Uso:  .\lanzador\compilar.ps1                  (toma la version de PCCare.ps1)
param([string]$Version)
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot

$linea = Select-String -LiteralPath (Join-Path $raiz 'PCCare.ps1') -Pattern '^\$VersionApp = ''([^'']+)''' | Select-Object -First 1
if (-not $linea) { throw 'No se encontró $VersionApp en PCCare.ps1' }
$versionApp = $linea.Matches[0].Groups[1].Value
if ($Version -and $Version -ne $versionApp) { throw ('La versión pedida (' + $Version + ') no coincide con la de PCCare.ps1 (' + $versionApp + ').') }
$Version = $versionApp

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $csc)) { throw 'No se encontró csc.exe de .NET Framework 4 en este Windows.' }

$obj = Join-Path $PSScriptRoot 'obj'
$bin = Join-Path $PSScriptRoot 'bin'
foreach ($d in $obj, $bin) { if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d) } }

# Datos de version del .exe (los lee SignPath y la pestaña Detalles de Windows)
$info = @"
using System.Reflection;
[assembly: AssemblyTitle("PC Care")]
[assembly: AssemblyDescription("Lanzador de PC Care")]
[assembly: AssemblyCompany("NOVALTEK")]
[assembly: AssemblyProduct("PC Care")]
[assembly: AssemblyCopyright("MIT License, NOVALTEK")]
[assembly: AssemblyVersion("$Version.0")]
[assembly: AssemblyFileVersion("$Version.0")]
[assembly: AssemblyInformationalVersion("$Version")]
"@
$rutaInfo = Join-Path $obj 'AssemblyInfo.cs'
[System.IO.File]::WriteAllText($rutaInfo, $info, (New-Object System.Text.UTF8Encoding($true)))

$salida = Join-Path $bin 'PCCare.exe'
if (Test-Path -LiteralPath $salida) { Remove-Item -LiteralPath $salida -Force }
& $csc /nologo /target:winexe /platform:anycpu /optimize+ /debug- /warn:4 `
    ('/out:' + $salida) ('/win32manifest:' + (Join-Path $PSScriptRoot 'app.manifest')) ('/win32icon:' + (Join-Path $PSScriptRoot 'PCCare.ico')) `
    (Join-Path $PSScriptRoot 'Program.cs') $rutaInfo
if ($LASTEXITCODE -ne 0) { throw ('csc terminó con código ' + $LASTEXITCODE) }
if (-not (Test-Path -LiteralPath $salida)) { throw ('No se generó ' + $salida) }
$v = (Get-Item -LiteralPath $salida).VersionInfo
Write-Host ('Lanzador: ' + $salida + ' | ' + $v.ProductName + ' ' + $v.FileVersion + ' | ' + [math]::Round((Get-Item -LiteralPath $salida).Length / 1KB) + ' KB')
