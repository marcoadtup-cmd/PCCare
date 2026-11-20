# probar.ps1
# Prueba el instalador ya compilado: instala en silencio, compara cada archivo con el del repositorio,
# corre la autoprueba desde la carpeta instalada, desinstala y comprueba que el programa ya no esta.
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
$setups = @(Get-ChildItem -LiteralPath (Join-Path $raiz 'salida') -Filter 'PCCare-Setup-*-x64.exe')
if ($setups.Count -ne 1) { throw ('Se esperaba un instalador en salida\ y hay ' + $setups.Count) }
$setup = $setups[0].FullName
$tmp = [System.IO.Path]::GetTempPath()
$dir = Join-Path $tmp 'PCCareInstalado'
$log = Join-Path $tmp 'PCCare-setup.log'
if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }

Write-Host '== 1. Metadatos del instalador'
$info = (Get-Item -LiteralPath $setup).VersionInfo
Write-Host ('Producto: ' + $info.ProductName + ' | Versión de archivo: ' + $info.FileVersion + ' | Archivo: ' + (Split-Path -Leaf $setup))
$nombre = [System.IO.Path]::GetFileNameWithoutExtension($setup)
$versionNombre = $nombre.Substring('PCCare-Setup-'.Length).Replace('-x64', '')
if (-not $info.FileVersion.StartsWith($versionNombre)) { throw ('La versión interna (' + $info.FileVersion + ') no coincide con el nombre (' + $versionNombre + ')') }

Write-Host '== 2. Instalación silenciosa'
$p = Start-Process -FilePath $setup -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/DIR=' + $dir), ('/LOG=' + $log)) -Wait -PassThru
if ($p.ExitCode -ne 0) {
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 40 }
    throw ('El instalador terminó con código ' + $p.ExitCode)
}
foreach ($f in 'PCCare.ps1', 'LICENSE', 'CHANGELOG.md', 'unins000.exe') {
    if (-not (Test-Path -LiteralPath (Join-Path $dir $f))) { throw ('Falta ' + $f + ' en la carpeta instalada') }
}

Write-Host '== 3. Cada archivo instalado debe ser idéntico al del repositorio'
$rutas = New-Object System.Collections.Generic.List[string]
$rutas.Add('PCCare.ps1')
foreach ($m in Get-ChildItem -LiteralPath (Join-Path $raiz 'modulos') -File) { $rutas.Add('modulos\' + $m.Name) }
foreach ($m in Get-ChildItem -LiteralPath (Join-Path $raiz 'modulos\idioma') -File) { $rutas.Add('modulos\idioma\' + $m.Name) }
for ($i = 0; $i -lt $rutas.Count; $i++) {
    $rel = $rutas[$i]
    $rutaInst = Join-Path $dir $rel
    if (-not (Test-Path -LiteralPath $rutaInst)) { throw ('No se instaló ' + $rel) }
    $a = (Get-FileHash -LiteralPath (Join-Path $raiz $rel) -Algorithm SHA256).Hash
    $b = (Get-FileHash -LiteralPath $rutaInst -Algorithm SHA256).Hash
    if ($a -ne $b) { throw ('El archivo instalado difiere del repositorio: ' + $rel) }
}
Write-Host ('Archivos verificados: ' + $rutas.Count)

Write-Host '== 4. Autoprueba desde la carpeta instalada'
$ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'PCCare.ps1') -AutoPrueba
$logs = @(Get-ChildItem -LiteralPath $dir -Filter 'PCCare_autoprueba_*.log')
if ($logs.Count -eq 0) { throw 'La autoprueba instalada no dejó informe' }
Get-Content -LiteralPath $logs[0].FullName

Write-Host '== 5. Desinstalación silenciosa'
[void](Start-Process -FilePath (Join-Path $dir 'unins000.exe') -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait -PassThru)
$limite = (Get-Date).AddSeconds(90)
while ((Test-Path -LiteralPath (Join-Path $dir 'PCCare.ps1')) -and (Get-Date) -lt $limite) { Start-Sleep -Seconds 2 }
if (Test-Path -LiteralPath (Join-Path $dir 'PCCare.ps1')) { throw 'La desinstalación no quitó PCCare.ps1' }
Write-Host 'Instalación, verificación y desinstalación: correctas'
