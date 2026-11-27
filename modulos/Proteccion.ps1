# Proteccion.ps1
# Antivirus activo y escaneo con Microsoft Defender.
# Las funciones sin interfaz se prueban en la autoprueba. Los bloques $sb* corren en segundo plano.

function ConvertFrom-EstadoProductoAV {
    # productState de SecurityCenter2: el byte del medio indica si esta activo (10 u 11),
    # el ultimo si las firmas estan al dia (00). Ejemplo: 397568 = 0x061100 -> activo y al dia.
    param([int]$Estado)
    $hex = '{0:X6}' -f $Estado
    $medio = $hex.Substring($hex.Length - 4, 2)
    $final = $hex.Substring($hex.Length - 2, 2)
    return [pscustomobject]@{ Activo = (@('10', '11') -contains $medio); AlDia = ($final -eq '00') }
}

function Get-DecisionEscaneo {
    # Decide si PC Care puede pedir a Defender un escaneo y explica por que.
    # Modo: AMRunningMode de Get-MpComputerStatus ('Normal', 'Passive Mode', 'SxS Passive Mode', 'EDR Block Mode', ...).
    param([bool]$DefenderDisponible, [bool]$AntivirusHabilitado, [string]$Modo, [string[]]$OtrosActivos)
    $otros = @($OtrosActivos | Where-Object { $_ })
    $nombres = $otros -join ', '
    if (-not $DefenderDisponible) {
        if ($otros.Count -gt 0) { return [pscustomobject]@{ Permitido = $false; Nivel = 'Info'; Motivo = ('La protección la administra {0}. Microsoft Defender no está disponible en este equipo: usa el escaneo de ese antivirus.' -f $nombres) } }
        return [pscustomobject]@{ Permitido = $false; Nivel = 'Crítico'; Motivo = 'No se detectó ningún antivirus activo ni se pudo consultar Microsoft Defender.' }
    }
    if (-not $AntivirusHabilitado) {
        if ($otros.Count -gt 0) { return [pscustomobject]@{ Permitido = $false; Nivel = 'Info'; Motivo = ('La protección la administra {0}. Microsoft Defender está desactivado y no puede escanear: usa el escaneo de ese antivirus.' -f $nombres) } }
        return [pscustomobject]@{ Permitido = $false; Nivel = 'Crítico'; Motivo = 'Microsoft Defender está desactivado y no se detectó otro antivirus activo. Revisa Seguridad de Windows.' }
    }
    if ($Modo -and $Modo -match 'Passive') {
        $quien = 'otro antivirus'
        if ($otros.Count -gt 0) { $quien = $nombres }
        return [pscustomobject]@{ Permitido = $true; Nivel = 'Info'; Motivo = ('Microsoft Defender está en modo pasivo porque la protección la administra {0}. Puede escanear, pero lo que encuentre lo debe resolver ese antivirus.' -f $quien) }
    }
    return [pscustomobject]@{ Permitido = $true; Nivel = 'Al día'; Motivo = 'Microsoft Defender está activo y puede escanear.' }
}

function Get-TextoTipoEscaneo {
    param([string]$Tipo)
    switch ($Tipo) {
        'Rapido' { return 'Escaneo rápido' }
        'Completo' { return 'Escaneo completo' }
        'Carpeta' { return 'Escaneo de una carpeta' }
    }
    return $Tipo
}

# Lee los antivirus registrados en Windows y el estado de Defender. Solo lectura.
$sbAntivirus = {
    param([string]$Ayuda)
    $productos = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($p in @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)) {
            $hex = '{0:X6}' -f [int]$p.productState
            $medio = $hex.Substring($hex.Length - 4, 2)
            $final = $hex.Substring($hex.Length - 2, 2)
            $productos.Add([pscustomobject]@{
                    Nombre     = [string]$p.displayName
                    Activo     = (@('10', '11') -contains $medio)
                    AlDia      = ($final -eq '00')
                    EsDefender = ([string]$p.displayName -match 'Defender|Windows Security|Seguridad de Windows')
                })
        }
    }
    catch { }
    $def = [pscustomobject]@{ Disponible = $false; Habilitado = $false; TiempoReal = $false; Modo = ''; FirmaDias = -1; UltimoRapido = ''; UltimoCompleto = '' }
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $def.Disponible = $true
        $def.Habilitado = [bool]$mp.AntivirusEnabled
        $def.TiempoReal = [bool]$mp.RealTimeProtectionEnabled
        try { $def.Modo = [string]$mp.AMRunningMode } catch { }
        try { $def.FirmaDias = [int]$mp.AntivirusSignatureAge } catch { }
        try { if ($mp.QuickScanEndTime) { $def.UltimoRapido = ([datetime]$mp.QuickScanEndTime).ToString('yyyy-MM-dd HH:mm') } } catch { }
        try { if ($mp.FullScanEndTime) { $def.UltimoCompleto = ([datetime]$mp.FullScanEndTime).ToString('yyyy-MM-dd HH:mm') } } catch { }
    }
    catch { }
    [pscustomobject]@{ Productos = $productos.ToArray(); Defender = $def }
}

# Pide a Defender un escaneo y devuelve lo que detecto durante el escaneo.
# En simulacion no se inicia: Defender aplica su propia politica (puede poner archivos en cuarentena).
$sbEscaneoDefender = {
    param([string]$Ayuda, [string]$Tipo, [string]$Ruta, [bool]$Simular)
    $mensajes = New-Object System.Collections.Generic.List[string]
    $amenazas = New-Object System.Collections.Generic.List[object]
    if ($Simular) {
        $mensajes.Add('SIMULACIÓN: no se inicia el escaneo. Microsoft Defender actúa según su propia configuración (por ejemplo, pone archivos en cuarentena), así que solo se ejecuta en modo real.')
        return [pscustomobject]@{ Mensajes = $mensajes.ToArray(); Amenazas = $amenazas.ToArray(); Simulado = $true; Segundos = 0 }
    }
    $inicio = Get-Date
    switch ($Tipo) {
        'Rapido' { Start-MpScan -ScanType QuickScan -ErrorAction Stop }
        'Completo' { Start-MpScan -ScanType FullScan -ErrorAction Stop }
        'Carpeta' {
            if (-not $Ruta -or -not (Test-Path -LiteralPath $Ruta -PathType Container)) { throw ('La carpeta no existe: ' + $Ruta) }
            Start-MpScan -ScanType CustomScan -ScanPath $Ruta -ErrorAction Stop
        }
        default { throw ('Tipo de escaneo no reconocido: ' + $Tipo) }
    }
    $seg = [int]((Get-Date) - $inicio).TotalSeconds
    $nombres = @{}
    try { foreach ($t in @(Get-MpThreat -ErrorAction Stop)) { $nombres[[string]$t.ThreatID] = [string]$t.ThreatName } } catch { }
    try {
        foreach ($d in @(Get-MpThreatDetection -ErrorAction Stop)) {
            if (-not $d.InitialDetectionTime -or ([datetime]$d.InitialDetectionTime) -lt $inicio.AddMinutes(-1)) { continue }
            $nombre = $nombres[[string]$d.ThreatID]
            if (-not $nombre) { $nombre = 'Amenaza ' + [string]$d.ThreatID }
            $amenazas.Add([pscustomobject]@{
                    Nombre   = $nombre
                    Archivos = ((@($d.Resources) | Select-Object -First 3) -join '; ')
                    Fecha    = ([datetime]$d.InitialDetectionTime).ToString('yyyy-MM-dd HH:mm')
                })
        }
    }
    catch { $mensajes.Add('No se pudo leer el historial de detecciones de Defender.') }
    if ($amenazas.Count -eq 0) { $mensajes.Add(('Escaneo terminado en {0} s. Defender no detectó amenazas.' -f $seg)) }
    else { $mensajes.Add(('Escaneo terminado en {0} s. Defender detectó {1} amenazas y las trató según su configuración. Revisa Seguridad de Windows, Historial de protección.' -f $seg, $amenazas.Count)) }
    [pscustomobject]@{ Mensajes = $mensajes.ToArray(); Amenazas = $amenazas.ToArray(); Simulado = $false; Segundos = $seg }
}
