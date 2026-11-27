# Resumen.ps1
# Resumen honesto del analisis, puntos de color del menu, impacto acumulado, ultimo analisis
# guardado y ficha del equipo. Logica sin interfaz para poder probarla en la autoprueba.
#
# Regla de honestidad: nunca se suman cosas distintas en una sola cifra de "problemas".
# Espacio recuperable, riesgos reales y actualizaciones se informan por separado,
# y el registro va aparte porque limpiarlo no acelera el equipo.

$script:UmbralEspacioAmbar = [double]2GB

function Format-TamanoResumen {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -gt 0) { return ('{0:N0} KB' -f [math]::Ceiling($Bytes / 1KB)) }
    return '0'
}

function Get-ResumenHonesto {
    # Cada parametro en -1 significa "todavia no se analizo".
    param(
        [double]$BytesBasura = -1,
        [int]$Criticos = -1,
        [int]$Alertas = -1,
        [int]$AppsPendientes = -1,
        [int]$DriversPendientes = -1,
        [int]$EntradasRegistro = -1
    )
    $l = New-Object System.Collections.Generic.List[string]
    if ($Criticos -ge 0 -and $Alertas -ge 0) {
        $l.Add(('Riesgos reales: {0} ({1} críticos, {2} alertas) en seguridad y diagnóstico.' -f ($Criticos + $Alertas), $Criticos, $Alertas))
    }
    else { $l.Add('Riesgos reales: sin analizar.') }
    if ($BytesBasura -ge 0) {
        $l.Add(('Espacio recuperable: {0} en temporales y cachés. No es un problema: es espacio que puedes liberar.' -f (Format-TamanoResumen $BytesBasura)))
    }
    else { $l.Add('Espacio recuperable: sin analizar.') }
    if ($AppsPendientes -ge 0 -or $DriversPendientes -ge 0) {
        $a = [math]::Max(0, $AppsPendientes); $d = [math]::Max(0, $DriversPendientes)
        $l.Add(('Actualizaciones disponibles: {0} aplicaciones y {1} drivers.' -f $a, $d))
    }
    else { $l.Add('Actualizaciones disponibles: sin revisar (página Actualizaciones).') }
    if ($EntradasRegistro -ge 0) {
        $l.Add(('Registro: {0} entradas inválidas. Se informan aparte porque limpiarlas ordena pero no acelera el equipo.' -f $EntradasRegistro))
    }
    return , $l.ToArray()
}

function Get-NivelPunto {
    # Dos niveles para el menu: Rojo (requiere atencion) y Ambar (mejorable). '' = sin punto.
    param([int]$Criticos, [int]$Alertas)
    if ($Criticos -gt 0) { return 'Rojo' }
    if ($Alertas -gt 0) { return 'Ambar' }
    return ''
}

function Get-NivelEspacio {
    # El espacio recuperable nunca es rojo: no es un riesgo.
    param([double]$Bytes)
    if ($Bytes -ge $script:UmbralEspacioAmbar) { return 'Ambar' }
    return ''
}

function Get-ColorNivel {
    param([string]$Nivel)
    switch ($Nivel) {
        'Rojo' { return '#E5484D' }
        'Ambar' { return '#F2A33A' }
    }
    return ''
}

# --- Impacto acumulado (lo que PC Care ya hizo en modo real) -----------------
function Get-Impacto {
    param([string]$Ruta)
    $vacio = [pscustomobject]@{ Bytes = [double]0; Acciones = 0; Desde = '' }
    if (-not $Ruta -or -not (Test-Path -LiteralPath $Ruta)) { return $vacio }
    try {
        $j = Get-Content -LiteralPath $Ruta -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{ Bytes = [double]$j.Bytes; Acciones = [int]$j.Acciones; Desde = [string]$j.Desde }
    }
    catch { return $vacio }
}

function Add-Impacto {
    # Suma bytes liberados y acciones aplicadas. Solo se llama en modo real.
    param([string]$Ruta, [double]$Bytes = 0, [int]$Acciones = 1)
    $i = Get-Impacto $Ruta
    if (-not $i.Desde) { $i.Desde = (Get-Date).ToString('yyyy-MM-dd') }
    $i.Bytes = [double]$i.Bytes + [math]::Max(0, $Bytes)
    $i.Acciones = [int]$i.Acciones + [math]::Max(0, $Acciones)
    try {
        $dir = Split-Path -Parent $Ruta
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $json = '{{"Bytes": {0}, "Acciones": {1}, "Desde": "{2}"}}' -f ([string]([long]$i.Bytes)), $i.Acciones, $i.Desde
        [System.IO.File]::WriteAllText($Ruta, $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
    return $i
}

function Get-TextoImpacto {
    param($Impacto)
    if (-not $Impacto -or ([int]$Impacto.Acciones -eq 0 -and [double]$Impacto.Bytes -eq 0)) {
        return 'Todavía no se aplicó ningún cambio en modo real en este equipo.'
    }
    return ('Desde {0}: {1} liberados y {2} acciones aplicadas en modo real.' -f $Impacto.Desde, (Format-TamanoResumen ([double]$Impacto.Bytes)), $Impacto.Acciones)
}

# --- Ultimo analisis guardado ------------------------------------------------
function Save-UltimoAnalisis {
    param([string]$Ruta, [string[]]$Lineas)
    try {
        $dir = Split-Path -Parent $Ruta
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $obj = [ordered]@{ Fecha = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Lineas = [string[]]@($Lineas) }
        [System.IO.File]::WriteAllText($Ruta, ($obj | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
        return $true
    }
    catch { return $false }
}

function Get-UltimoAnalisis {
    param([string]$Ruta)
    if (-not $Ruta -or -not (Test-Path -LiteralPath $Ruta)) { return $null }
    try {
        $j = Get-Content -LiteralPath $Ruta -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{ Fecha = [string]$j.Fecha; Lineas = [string[]]@($j.Lineas) }
    }
    catch { return $null }
}

# --- Ficha del equipo ---------------------------------------------------------
function Get-ResumenEquipo {
    $r = [ordered]@{ Modelo = ''; Procesador = ''; Memoria = ''; Windows = ''; Disco = '' }
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $r.Modelo = ('{0} {1}' -f ([string]$cs.Manufacturer).Trim(), ([string]$cs.Model).Trim()).Trim()
        $r.Memoria = ('{0:N0} GB' -f ([double]$cs.TotalPhysicalMemory / 1GB))
    }
    catch { }
    try {
        $cpu = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)[0]
        $r.Procesador = (([string]$cpu.Name) -replace '\s+', ' ').Trim()
        if ($cpu.NumberOfCores) { $r.Procesador += (' ({0} núcleos)' -f $cpu.NumberOfCores) }
    }
    catch { }
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $ver = ''
        try { $ver = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name DisplayVersion -ErrorAction Stop).DisplayVersion } catch { }
        $r.Windows = ('{0} {1} (compilación {2})' -f ([string]$os.Caption -replace '^Microsoft\s+', ''), $ver, $os.BuildNumber) -replace '\s+', ' '
    }
    catch { }
    try {
        $d = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive) -ErrorAction Stop
        $r.Disco = ('{0} libres de {1} en {2}' -f (Format-TamanoResumen ([double]$d.FreeSpace)), (Format-TamanoResumen ([double]$d.Size)), $env:SystemDrive)
    }
    catch { }
    return [pscustomobject]$r
}
