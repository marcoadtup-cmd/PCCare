# Programas.ps1
# Programas instalados (con desinstalacion confirmada), programas con fallos (Visor de eventos)
# y registro de cambios del arranque para poder deshacerlos.
# Las funciones sin interfaz se prueban en la autoprueba. Los bloques $sb* corren en segundo plano.

$script:RaicesDesinstalar = @(
    @{ Ruta = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Origen = 'Equipo' },
    @{ Ruta = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Origen = 'Equipo (32 bits)' },
    @{ Ruta = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'; Origen = 'Usuario' }
)

function Get-ComandoDesinstalar {
    # Convierte el UninstallString del registro en archivo y argumentos para Start-Process.
    # Siempre el desinstalador interactivo del fabricante: nada silencioso.
    param([string]$Cadena)
    if ([string]::IsNullOrWhiteSpace($Cadena)) { return $null }
    $c = [Environment]::ExpandEnvironmentVariables($Cadena.Trim())
    $m = [regex]::Match($c, '(?i)^"?(?:[A-Z]:\\Windows\\System32\\)?msiexec(?:\.exe)?"?\s+/[IX]\s*(\{[0-9A-F-]{36}\})')
    if ($m.Success) { return [pscustomobject]@{ Archivo = 'msiexec.exe'; Argumentos = ('/x ' + $m.Groups[1].Value.ToUpper()); Msi = $true } }
    if ($c -match '(?i)msiexec') { return $null }   # otras formas de msiexec no se interpretan
    if ($c.StartsWith('"')) {
        $fin = $c.IndexOf('"', 1)
        if ($fin -lt 2) { return $null }
        $archivo = $c.Substring(1, $fin - 1)
        $resto = $c.Substring($fin + 1).Trim()
    }
    else {
        $m2 = [regex]::Match($c, '(?i)^(.+?\.exe)(?:\s+(.*))?$')
        if (-not $m2.Success) { return $null }
        $archivo = $m2.Groups[1].Value
        $resto = $m2.Groups[2].Value.Trim()
    }
    if ($archivo -notmatch '(?i)^[A-Z]:\\.+\.exe$') { return $null }
    return [pscustomobject]@{ Archivo = $archivo; Argumentos = $resto; Msi = $false }
}

function Test-ClaveDesinstalarPermitida {
    # La clave debe estar DENTRO de una de las tres raices Uninstall (nunca la raiz misma).
    param([string]$Clave)
    foreach ($r in $script:RaicesDesinstalar) {
        $raiz = $r.Ruta.TrimEnd('\') + '\'
        if ($Clave.Length -gt $raiz.Length -and $Clave.StartsWith($raiz, [System.StringComparison]::OrdinalIgnoreCase) -and $Clave.Substring($raiz.Length) -notmatch '\\') { return $true }
    }
    return $false
}

function Get-AvisoPrograma {
    # '' si no hay aviso; 'Bloqueado' para PC Care; texto de advertencia para componentes que usan otros programas.
    param([string]$Nombre)
    if ($Nombre -match '(?i)^PC Care\b') { return 'Bloqueado' }
    if ($Nombre -match '(?i)Visual C\+\+|\.NET|Windows SDK|DirectX|Runtime|Redistributable') { return 'Es un componente que usan otros programas. Si lo quitas, alguno puede dejar de abrir.' }
    if ($Nombre -match '(?i)\b(Intel|NVIDIA|AMD|Realtek|Synaptics|Elan|Dolby|Waves)\b') { return 'Parece un driver o software del fabricante del equipo. Quitarlo puede afectar sonido, video, touchpad o red.' }
    return ''
}

function Group-FallosProgramas {
    # Eventos: objetos con Tipo ('Fallo' o 'Cuelgue'), App, Modulo y Fecha [datetime].
    param([object[]]$Eventos)
    $salida = New-Object System.Collections.Generic.List[object]
    foreach ($g in (@($Eventos | Where-Object { $_ -and $_.App }) | Group-Object { ([string]$_.App).ToLowerInvariant() })) {
        $fallos = @($g.Group | Where-Object { $_.Tipo -eq 'Fallo' }).Count
        $cuelgues = @($g.Group | Where-Object { $_.Tipo -eq 'Cuelgue' }).Count
        $ultimo = ($g.Group | Sort-Object Fecha -Descending | Select-Object -First 1)
        $mod = @($g.Group | Where-Object { $_.Modulo } | Group-Object Modulo | Sort-Object Count -Descending | Select-Object -First 1)
        $salida.Add([pscustomobject]@{
                Programa = [string]$ultimo.App
                Fallos   = $fallos
                Cuelgues = $cuelgues
                Total    = $fallos + $cuelgues
                Ultimo   = ([datetime]$ultimo.Fecha).ToString('yyyy-MM-dd HH:mm')
                Modulo   = $(if ($mod.Count -gt 0) { [string]$mod[0].Name } else { '' })
            })
    }
    return , @($salida | Sort-Object Total, Ultimo -Descending)
}

# --- Arranque: registro de cambios para deshacer ------------------------------
function Get-LotesCambiosInicio {
    param([string]$Ruta)
    if (-not $Ruta -or -not (Test-Path -LiteralPath $Ruta)) { return , @() }
    try {
        $j = Get-Content -LiteralPath $Ruta -Raw -Encoding UTF8 | ConvertFrom-Json
        return , @($j)
    }
    catch { return , @() }
}

function Save-LotesCambiosInicio {
    param([string]$Ruta, [object[]]$Lotes)
    $dir = Split-Path -Parent $Ruta
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertTo-Json -InputObject @($Lotes) -Depth 5
    if (@($Lotes).Count -eq 0) { $json = '[]' }
    [System.IO.File]::WriteAllText($Ruta, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Add-LoteCambiosInicio {
    # Cambios: objetos con Nombre, Aprobado (clave StartupApproved), Antes y Despues (bool). Se guardan los 20 ultimos lotes.
    param([string]$Ruta, [object[]]$Cambios)
    if (@($Cambios).Count -eq 0) { return }
    $lotes = New-Object System.Collections.Generic.List[object]
    foreach ($l in (Get-LotesCambiosInicio $Ruta)) { $lotes.Add($l) }
    $lista = @($Cambios | ForEach-Object { [ordered]@{ Nombre = [string]$_.Nombre; Aprobado = [string]$_.Aprobado; Antes = [bool]$_.Antes; Despues = [bool]$_.Despues } })
    $lotes.Add([ordered]@{ Fecha = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Cambios = $lista })
    while ($lotes.Count -gt 20) { $lotes.RemoveAt(0) }
    Save-LotesCambiosInicio $Ruta $lotes.ToArray()
}

function Remove-UltimoLoteInicio {
    param([string]$Ruta)
    $lotes = @(Get-LotesCambiosInicio $Ruta)
    if ($lotes.Count -eq 0) { return }
    if ($lotes.Count -eq 1) { Save-LotesCambiosInicio $Ruta @(); return }
    Save-LotesCambiosInicio $Ruta @($lotes[0..($lotes.Count - 2)])
}

# --- Tareas en segundo plano ---------------------------------------------------
# Lista los programas instalados desde el registro. Solo lectura.
$sbProgramas = {
    param([string]$Ayuda)
    $raices = @(
        @{ Ruta = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Origen = 'Equipo' },
        @{ Ruta = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Origen = 'Equipo (32 bits)' },
        @{ Ruta = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'; Origen = 'Usuario' }
    )
    $vistos = @{}
    foreach ($r in $raices) {
        if (-not (Test-Path $r.Ruta)) { continue }
        foreach ($k in @(Get-ChildItem -Path $r.Ruta -ErrorAction SilentlyContinue)) {
            try {
                $nombre = [string]$k.GetValue('DisplayName')
                if (-not $nombre) { continue }
                if ($k.GetValue('SystemComponent') -eq 1) { continue }
                if ($k.GetValue('ParentKeyName')) { continue }
                if ([string]$k.GetValue('ReleaseType') -match 'Update|Hotfix') { continue }
                if (-not $k.GetValue('UninstallString')) { continue }
                $version = [string]$k.GetValue('DisplayVersion')
                $clave = $r.Ruta + '\' + $k.PSChildName
                $id = ($nombre + '|' + $version).ToLowerInvariant()
                if ($vistos.ContainsKey($id)) { continue }
                $vistos[$id] = $true
                $fecha = [string]$k.GetValue('InstallDate')
                if ($fecha -match '^(\d{4})(\d{2})(\d{2})$') { $fecha = '{0}-{1}-{2}' -f $Matches[1], $Matches[2], $Matches[3] } else { $fecha = '' }
                $mb = ''
                $kb = $k.GetValue('EstimatedSize')
                if ($kb) { $mb = [string][math]::Round([double]$kb / 1024) }
                [pscustomobject]@{ Nombre = $nombre.Trim(); Version = $version; Editor = ([string]$k.GetValue('Publisher')).Trim(); Fecha = $fecha; TamanoMB = $mb; Origen = $r.Origen; Clave = $clave }
            }
            catch { }
        }
    }
}

# Lee fallos (Id 1000) y cuelgues (Id 1002) de programas de los ultimos 30 dias. Solo lectura.
$sbProgramasFallos = {
    param([string]$Ayuda, [int]$Dias = 30)
    $desde = (Get-Date).AddDays(-1 * [math]::Max(1, $Dias))
    $eventos = @()
    try { $eventos = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1002; StartTime = $desde } -MaxEvents 3000 -ErrorAction Stop) } catch { }
    foreach ($e in $eventos) {
        try {
            $p = @($e.Properties | ForEach-Object { [string]$_.Value })
            if ($e.ProviderName -eq 'Application Error' -and $e.Id -eq 1000) {
                [pscustomobject]@{ Tipo = 'Fallo'; App = $p[0]; Modulo = $(if ($p.Count -gt 3) { $p[3] } else { '' }); Fecha = $e.TimeCreated }
            }
            elseif ($e.ProviderName -eq 'Application Hang' -and $e.Id -eq 1002) {
                [pscustomobject]@{ Tipo = 'Cuelgue'; App = $p[0]; Modulo = ''; Fecha = $e.TimeCreated }
            }
        }
        catch { }
    }
}

# Lanza el desinstalador del fabricante (interactivo) y espera a que termine.
# El archivo y los argumentos los arma Get-ComandoDesinstalar leyendo el registro en el momento, no la tabla.
$sbDesinstalarPrograma = {
    param([string]$Ayuda, [string]$Nombre, [string]$Clave, [string]$Archivo, [string]$Argumentos, [bool]$Simular)
    $mensajes = New-Object System.Collections.Generic.List[string]
    if ($Simular) {
        $mensajes.Add(('SIMULACIÓN: se abriría el desinstalador de {0}: {1} {2}' -f $Nombre, $Archivo, $Argumentos))
        return [pscustomobject]@{ Mensajes = $mensajes.ToArray(); Quitado = $false; Simulado = $true }
    }
    if (-not (Test-Path -LiteralPath $Clave)) { $mensajes.Add('El programa ya no figura como instalado: ' + $Nombre); return [pscustomobject]@{ Mensajes = $mensajes.ToArray(); Quitado = $true; Simulado = $false } }
    if ($Archivo -ne 'msiexec.exe' -and -not (Test-Path -LiteralPath $Archivo -PathType Leaf)) { throw ('No existe el desinstalador: ' + $Archivo) }
    $p = $null
    if ($Argumentos) { $p = Start-Process -FilePath $Archivo -ArgumentList $Argumentos -PassThru -Wait }
    else { $p = Start-Process -FilePath $Archivo -PassThru -Wait }
    Start-Sleep -Seconds 2
    $quitado = -not (Test-Path -LiteralPath $Clave)
    $codigo = ''
    try { $codigo = [string]$p.ExitCode } catch { }
    if ($quitado) { $mensajes.Add(('{0} se desinstaló (código {1}).' -f $Nombre, $codigo)) }
    else { $mensajes.Add(('{0} sigue instalado (código {1}). Si cancelaste, no pasa nada. Si el desinstalador sigue abierto, termina allí y pulsa "Actualizar lista".' -f $Nombre, $codigo)) }
    [pscustomobject]@{ Mensajes = $mensajes.ToArray(); Quitado = $quitado; Simulado = $false }
}
