# Cola.ps1
# Registro persistente de tareas de PC Care. No usa interfaz grafica: se carga con "punto" desde PCCare.ps1
# y tambien se puede probar sola (la autoprueba lo hace).
#
# Que se guarda: cada tarea con su nombre, las opciones marcadas, los parametros, el modo (simulacion o real)
# y su estado. Si PC Care se cierra o falla a mitad de una tarea, al volver a abrirlo se ofrece reanudarla
# segun la politica de cada tipo de tarea.

$script:RutaCola = Join-Path $env:LOCALAPPDATA 'PCCare\Cola.json'
$script:MaxRegistros = 300

# Politica de reanudacion por tipo de tarea:
#   Seguro    = repetible sin riesgo (analisis de solo lectura o limpieza de la lista cerrada de carpetas).
#   Confirmar = modifica el equipo. Se ofrece reanudar lo que NO llego a empezar; lo que estaba en curso
#               queda sin marcar porque pudo quedar a medias (por ejemplo una instalacion).
#   No        = nunca se reanuda sola; hay que repetirla a mano (registro, TurboPC, reparacion de red).
$script:PoliticaTipos = @{
    'Seguridad'           = 'Seguro'
    'Restauracion'        = 'Seguro'
    'AnalisisBasura'      = 'Seguro'
    'LimpiarBasura'       = 'Seguro'
    'AnalisisRegistro'    = 'Seguro'
    'Inicio'              = 'Seguro'
    'Diagnostico'         = 'Seguro'
    'Procesos'            = 'Seguro'
    'Grandes'             = 'Seguro'
    'Duplicados'          = 'Seguro'
    'AnalisisApps'        = 'Seguro'
    'AnalisisDrivers'     = 'Seguro'
    'Informe'             = 'Seguro'
    'RedDiagnostico'      = 'Seguro'
    'Antivirus'           = 'Seguro'
    'Programas'           = 'Seguro'
    'ProgramasFallos'     = 'Seguro'
    'Papelera'            = 'Confirmar'
    'AccionDiag'          = 'Confirmar'
    'ActualizarApp'       = 'Confirmar'
    'InstalarDrivers'     = 'Confirmar'
    'Store'               = 'Confirmar'
    'RedAplicar'          = 'Confirmar'
    'LimpiarRegistro'     = 'No'
    'Turbo'               = 'No'
    'InstalarHerramienta' = 'No'
    'RedReparar'          = 'No'
    'EscaneoDefender'     = 'No'
    'DesinstalarPrograma' = 'No'
}

function Get-PoliticaTarea {
    param([string]$Tipo)
    if ($Tipo -and $script:PoliticaTipos.ContainsKey($Tipo)) { return [string]$script:PoliticaTipos[$Tipo] }
    return 'No'
}

function Get-ClaveTarea {
    # Identifica "la misma tarea con las mismas opciones" para no encolarla dos veces.
    param([string]$Nombre, [string]$Tipo, [string]$Opciones, [hashtable]$Parametros)
    $partes = @()
    foreach ($k in @($Parametros.Keys | Where-Object { $_ -ne 'Ayuda' } | Sort-Object)) {
        $partes += ('{0}={1}' -f $k, (@($Parametros[$k]) -join ','))
    }
    $base = $Tipo
    if (-not $base) { $base = $Nombre }
    return ('{0}|{1}|{2}' -f $base, $Opciones, ($partes -join ';'))
}

function New-RegistroTarea {
    param([string]$Nombre, [string]$Tipo, [string]$Opciones, [hashtable]$Parametros, [string]$Modo, [string]$Clave)
    $serial = [ordered]@{}
    foreach ($k in $Parametros.Keys) {
        if ($k -ne 'Ayuda') { $serial[[string]$k] = $Parametros[$k] }
    }
    return [pscustomobject]@{
        Id           = [guid]::NewGuid().ToString('N').Substring(0, 8)
        Tipo         = $Tipo
        Politica     = (Get-PoliticaTarea $Tipo)
        Nombre       = $Nombre
        Opciones     = $Opciones
        Modo         = $Modo
        Clave        = $Clave
        Parametros   = $serial
        Estado       = 'Pendiente'
        EstadoPrevio = ''
        Creada       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Inicio       = ''
        Fin          = ''
        Detalle      = ''
    }
}

function ConvertTo-ValorParametro {
    # ConvertFrom-Json devuelve las listas como object[]; se dejan como lista para que los parametros tipados las acepten.
    param($Valor)
    if ($Valor -is [System.Array]) { return , @($Valor | ForEach-Object { $_ }) }
    return $Valor
}

function ConvertTo-CadenaJson {
    # Escapa una cadena para JSON sin depender de ConvertTo-Json.
    param([string]$Texto)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Texto.ToCharArray()) {
        $c = [int]$ch
        if ($c -eq 34) { [void]$sb.Append('\"') }
        elseif ($c -eq 92) { [void]$sb.Append('\\') }
        elseif ($c -eq 10) { [void]$sb.Append('\n') }
        elseif ($c -eq 13) { [void]$sb.Append('\r') }
        elseif ($c -eq 9) { [void]$sb.Append('\t') }
        elseif ($c -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $c)) }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function ConvertTo-TextoJson {
    # Serializador minimo y predecible para los registros de la cola: texto, numeros, booleanos, listas y diccionarios.
    # Reemplaza a ConvertTo-Json, que en Windows PowerShell 5.1 fallaba con "Los tipos de argumentos no coinciden".
    param($Valor)
    if ($null -eq $Valor) { return 'null' }
    if ($Valor -is [bool]) { if ($Valor) { return 'true' } else { return 'false' } }
    if ($Valor -is [string] -or $Valor -is [char]) { return ('"' + (ConvertTo-CadenaJson ([string]$Valor)) + '"') }
    if ($Valor -is [int] -or $Valor -is [long] -or $Valor -is [double] -or $Valor -is [decimal] -or $Valor -is [single] -or $Valor -is [int16] -or $Valor -is [byte] -or $Valor -is [uint32] -or $Valor -is [uint64]) {
        return $Valor.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Valor -is [System.Collections.IDictionary]) {
        # Sin enumeradores: se copian las claves a un arreglo y se recorre por indice.
        $partes = New-Object System.Collections.Generic.List[string]
        $nClaves = $Valor.Count
        $claves = New-Object object[] $nClaves
        $Valor.Keys.CopyTo($claves, 0)
        for ($i = 0; $i -lt $nClaves; $i++) {
            $k = $claves[$i]
            $partes.Add(('"' + (ConvertTo-CadenaJson ([string]$k)) + '":' + (ConvertTo-TextoJson ($Valor[$k]))))
        }
        return ('{' + ($partes -join ',') + '}')
    }
    if ($Valor -is [System.Collections.IList]) {
        $partes = New-Object System.Collections.Generic.List[string]
        $nItems = $Valor.Count
        for ($i = 0; $i -lt $nItems; $i++) { $partes.Add((ConvertTo-TextoJson ($Valor[$i]))) }
        return ('[' + ($partes -join ',') + ']')
    }
    if ($Valor -is [System.Collections.IEnumerable]) {
        $partes = New-Object System.Collections.Generic.List[string]
        foreach ($e in $Valor) { $partes.Add((ConvertTo-TextoJson $e)) }
        return ('[' + ($partes -join ',') + ']')
    }
    if ($Valor -is [System.Management.Automation.PSCustomObject]) {
        $partes = New-Object System.Collections.Generic.List[string]
        foreach ($prop in $Valor.PSObject.Properties) {
            $partes.Add(('"' + (ConvertTo-CadenaJson ([string]$prop.Name)) + '":' + (ConvertTo-TextoJson ($prop.Value))))
        }
        return ('{' + ($partes -join ',') + '}')
    }
    return ('"' + (ConvertTo-CadenaJson ([string]$Valor)) + '"')
}

function Save-Cola {
    # Escritura atomica: primero un archivo temporal y luego se reemplaza. Nunca lanza error.
    # Si falla devuelve $false y deja el paso y el motivo en $script:UltimoErrorCola (la autoprueba lo muestra).
    param($Registros)
    $script:UltimoErrorCola = ''
    $max = 300
    if ($script:MaxRegistros -is [int] -and $script:MaxRegistros -gt 0) { $max = $script:MaxRegistros }
    for ($intento = 1; $intento -le 3; $intento++) {
        $paso = 'preparar'
        try {
            $paso = 'crear la carpeta'
            $dir = Split-Path -Parent $script:RutaCola
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $paso = 'contar los registros'
            $esLista = ($Registros -is [System.Collections.IList])
            $total = 0
            if ($esLista) { $total = $Registros.Count } elseif ($null -ne $Registros) { $total = 1 }
            $paso = 'copiar los registros'
            $lista = New-Object System.Collections.ArrayList
            $desde = 0
            if ($total -gt $max) { $desde = $total - $max }
            for ($i = $desde; $i -lt $total; $i++) {
                if ($esLista) { [void]$lista.Add($Registros[$i]) } else { [void]$lista.Add($Registros) }
            }
            $paso = 'convertir a JSON'
            $json = ConvertTo-TextoJson $lista
            $paso = 'escribir el temporal'
            $tmp = $script:RutaCola + '.tmp'
            [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
            $paso = 'reemplazar el archivo'
            if (Test-Path -LiteralPath $script:RutaCola) { [System.IO.File]::Delete($script:RutaCola) }
            [System.IO.File]::Move($tmp, $script:RutaCola)
            return $true
        }
        catch {
            $script:UltimoErrorCola = ('{0} al {1}: {2} (línea {3})' -f $_.Exception.GetType().Name, $paso, $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber)
            # Un antivirus puede tener el archivo abierto un instante: se reintenta.
            Start-Sleep -Milliseconds 200
        }
    }
    return $false
}

function Import-Cola {
    # Devuelve una List[object]. Si el archivo esta danado lo aparta como .danado y empieza de cero.
    $lista = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $script:RutaCola)) { return , $lista }
    try {
        $raw = [System.IO.File]::ReadAllText($script:RutaCola, [System.Text.Encoding]::UTF8)
        if ($raw.Trim()) {
            $datos = $raw | ConvertFrom-Json
            foreach ($e in @($datos)) {
                $p = [ordered]@{}
                if ($e.Parametros) {
                    foreach ($prop in $e.Parametros.PSObject.Properties) { $p[$prop.Name] = ConvertTo-ValorParametro $prop.Value }
                }
                $e.Parametros = $p
                $lista.Add($e)
            }
        }
    }
    catch {
        try { Move-Item -LiteralPath $script:RutaCola -Destination ($script:RutaCola + '.danado') -Force } catch { }
        $lista.Clear()
    }
    return , $lista
}

function Set-TareasInterrumpidas {
    # Al abrir PC Care: lo que quedo Pendiente o En curso se marca Interrumpida.
    # Los analisis de solo lectura no se ofrecen: se repiten solos al abrir.
    param($Registros)
    $n = 0
    for ($i = 0; $i -lt $Registros.Count; $i++) {
        $r = $Registros[$i]
        if ($r.Estado -eq 'Pendiente' -or $r.Estado -eq 'En curso') {
            if ($r.Politica -eq 'Seguro' -and $r.Modo -eq 'Solo lectura') {
                $r.Estado = 'Descartada'
                $r.Detalle = 'Análisis de solo lectura interrumpido; se repite solo al abrir PC Care'
            }
            else {
                $r.EstadoPrevio = [string]$r.Estado
                $r.Estado = 'Interrumpida'
                if (-not $r.Detalle) { $r.Detalle = 'PC Care se cerró antes de terminarla' }
                $n++
            }
        }
    }
    return $n
}

function Get-ReanudarPorDefecto {
    param($Reg)
    if ($Reg.Politica -eq 'No') { return $false }
    if ($Reg.Politica -eq 'Seguro') { return $true }
    return ($Reg.EstadoPrevio -ne 'En curso')
}

function Get-TextoDuracion {
    param([string]$Inicio, [string]$Fin)
    if (-not $Inicio) { return '' }
    try {
        $a = [datetime]::ParseExact($Inicio, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        if ($Fin) { $b = [datetime]::ParseExact($Fin, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) }
        else { $b = Get-Date }
        $s = [int][math]::Max(0, ($b - $a).TotalSeconds)
        if ($s -lt 60) { return ('{0} s' -f $s) }
        return ('{0} min {1} s' -f [int][math]::Floor($s / 60), ($s % 60))
    }
    catch { return '' }
}

function Get-TextoCorto {
    param([string]$Texto, [int]$Max = 300)
    if ($Texto.Length -le $Max) { return $Texto }
    return $Texto.Substring(0, $Max - 1) + '…'
}
