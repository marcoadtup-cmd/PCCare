# Ejecutores.ps1
# Tareas en segundo plano que lanzan los modulos independientes (AuditoriaPC.ps1 y OptimizarRed.ps1)
# desde PC Care. Usan Invoke-Exe, que viene en $ayudaActualizaciones (Actualizaciones.ps1).
# Cada modulo sigue pudiendose ejecutar solo, pero desde PC Care pasa por la cola de tareas y queda en el historial.

$sbInformeAuditoria = {
    param([string]$Ayuda, [string]$Script, [string]$Salida, [bool]$OmitirWU)
    . ([scriptblock]::Create($Ayuda))
    if (-not (Test-Path -LiteralPath $Script)) { throw ('No se encontró el módulo ' + $Script) }
    if (-not (Test-Path -LiteralPath $Salida)) { New-Item -ItemType Directory -Path $Salida -Force | Out-Null }
    $ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arg = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Salida "{1}" -NoAbrir' -f $Script, $Salida
    if ($OmitirWU) { $arg += ' -OmitirWindowsUpdate' }
    $inicio = Get-Date
    $r = Invoke-Exe $ps $arg
    $carpeta = Get-ChildItem -LiteralPath $Salida -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $inicio.AddSeconds(-5) } | Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $carpeta) { throw ('El informe no se generó (código {0}). {1}' -f $r.Codigo, ((@($r.Lineas) | Select-Object -Last 3) -join ' ')) }
    $html = Join-Path $carpeta.FullName 'Informe.html'
    if (-not (Test-Path -LiteralPath $html)) { throw ('No se encontró Informe.html en ' + $carpeta.FullName) }
    $resumen = $null
    try { $resumen = [System.IO.File]::ReadAllText((Join-Path $carpeta.FullName 'inventario.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { }
    $d = [ordered]@{ Informe = $html; Carpeta = $carpeta.FullName; Puntaje = 0; Criticos = 0; Alertas = 0; Apps = 0; Parches = 0 }
    if ($resumen) {
        $d.Puntaje = [int]$resumen.Puntaje; $d.Criticos = [int]$resumen.Criticos; $d.Alertas = [int]$resumen.Alertas
        $d.Apps = [int]$resumen.AppsDesactualizadas; $d.Parches = [int]$resumen.ParchesPendientes
    }
    return [pscustomobject]$d
}

$sbRedDiagnostico = {
    param([string]$Ayuda, [string]$Script, [string]$Carpeta, [bool]$SinDescarga, [int]$MB)
    . ([scriptblock]::Create($Ayuda))
    if (-not (Test-Path -LiteralPath $Script)) { throw ('No se encontró el módulo ' + $Script) }
    if (-not (Test-Path -LiteralPath $Carpeta)) { New-Item -ItemType Directory -Path $Carpeta -Force | Out-Null }
    $informe = Join-Path $Carpeta 'Ultimo_diagnostico.txt'
    $cambios = Join-Path $Carpeta 'Ultimos_cambios.json'
    foreach ($f in @($informe, $cambios)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    $ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arg = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Carpeta "{1}" -ArchivoInforme "{2}" -ArchivoCambios "{3}" -SinPausa -MBPrueba {4}' -f $Script, $Carpeta, $informe, $cambios, $MB
    if ($SinDescarga) { $arg += ' -SinDescarga' }
    $r = Invoke-Exe $ps $arg
    $texto = ''
    if (Test-Path -LiteralPath $informe) { $texto = [System.IO.File]::ReadAllText($informe, [System.Text.Encoding]::UTF8) }
    else { throw ('El diagnóstico no generó informe (código {0}). {1}' -f $r.Codigo, ((@($r.Lineas) | Select-Object -Last 3) -join ' ')) }
    $lista = @()
    if (Test-Path -LiteralPath $cambios) {
        $json = [System.IO.File]::ReadAllText($cambios, [System.Text.Encoding]::UTF8)
        if ($json.Trim()) { $datos = $json | ConvertFrom-Json; $lista = @($datos) }
    }
    return [pscustomobject]@{ Codigo = $r.Codigo; Informe = $texto; Cambios = $lista }
}

$sbRedAplicar = {
    param([string]$Ayuda, [string]$Script, [string]$Carpeta, [string[]]$Nombres, [bool]$Simular)
    . ([scriptblock]::Create($Ayuda))
    if ($Simular) {
        return [pscustomobject]@{ Simulado = $true; Informe = ('SIMULACIÓN: no se aplicó nada. Se habrían aplicado: ' + (@($Nombres) -join '; ')); Revertir = '' }
    }
    if (-not (Test-Path -LiteralPath $Script)) { throw ('No se encontró el módulo ' + $Script) }
    if (-not (Test-Path -LiteralPath $Carpeta)) { New-Item -ItemType Directory -Path $Carpeta -Force | Out-Null }
    $informe = Join-Path $Carpeta 'Ultima_aplicacion.txt'
    Remove-Item -LiteralPath $informe -Force -ErrorAction SilentlyContinue
    $ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arg = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Carpeta "{1}" -ArchivoInforme "{2}" -SinPausa -SinDescarga -AplicarSolo "{3}"' -f $Script, $Carpeta, $informe, (@($Nombres) -join '|')
    $inicio = Get-Date
    $r = Invoke-Exe $ps $arg
    $texto = ''
    if (Test-Path -LiteralPath $informe) { $texto = [System.IO.File]::ReadAllText($informe, [System.Text.Encoding]::UTF8) }
    else { throw ('La aplicación de cambios no generó informe (código {0}).' -f $r.Codigo) }
    $rev = Get-ChildItem -LiteralPath $Carpeta -Filter 'Revertir_Red_*.cmd' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $inicio.AddSeconds(-5) } | Sort-Object LastWriteTime | Select-Object -Last 1
    $rutaRev = ''
    if ($rev) { $rutaRev = $rev.FullName }
    return [pscustomobject]@{ Simulado = $false; Informe = $texto; Revertir = $rutaRev }
}

$sbRedReparar = {
    param([string]$Ayuda, [string]$Script, [string]$Carpeta, [bool]$Simular)
    . ([scriptblock]::Create($Ayuda))
    if ($Simular) {
        return [pscustomobject]@{ Simulado = $true; Informe = 'SIMULACIÓN: no se reparó nada. Se habría ejecutado: ipconfig /flushdns, netsh winsock reset, netsh int ip reset (exige reiniciar).' }
    }
    if (-not (Test-Path -LiteralPath $Script)) { throw ('No se encontró el módulo ' + $Script) }
    if (-not (Test-Path -LiteralPath $Carpeta)) { New-Item -ItemType Directory -Path $Carpeta -Force | Out-Null }
    $informe = Join-Path $Carpeta 'Ultima_reparacion.txt'
    Remove-Item -LiteralPath $informe -Force -ErrorAction SilentlyContinue
    $ps = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arg = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Carpeta "{1}" -ArchivoInforme "{2}" -SinPausa -SinDescarga -Reparar -Confirmado' -f $Script, $Carpeta, $informe
    $r = Invoke-Exe $ps $arg
    $texto = ''
    if (Test-Path -LiteralPath $informe) { $texto = [System.IO.File]::ReadAllText($informe, [System.Text.Encoding]::UTF8) }
    else { throw ('La reparación no generó informe (código {0}).' -f $r.Codigo) }
    return [pscustomobject]@{ Simulado = $false; Informe = $texto }
}
