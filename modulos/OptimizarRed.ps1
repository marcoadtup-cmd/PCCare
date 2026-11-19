#Requires -Version 3.0
<#
.SYNOPSIS
    OptimizarRed: valida y optimiza la conectividad de Windows, pensado para compartir internet del celular por cable USB.

.DESCRIPTION
    Compatible con Windows 10 y 11 (y Server 2012 R2 o superior) con Windows PowerShell 3.0 o mayor.
    Windows 7 y 8.1 requieren WMF 5.1.

    Por defecto SOLO DIAGNOSTICA (no cambia nada). Genera trafico de prueba: unos 8 MB de descarga
    mas algunos pings. Usa -SinDescarga si tu plan de datos esta muy justo.

    Con -Aplicar propone cada cambio, pide confirmacion S/N y guarda un archivo .cmd para revertirlo.
    Con -Reparar ademas ofrece reiniciar la pila de red (winsock e IP). Esto exige reiniciar el equipo.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\OptimizarRed.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\OptimizarRed.ps1 -Aplicar
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\OptimizarRed.ps1 -SinDescarga
#>
[CmdletBinding()]
param(
    [switch]$Aplicar,
    [switch]$Reparar,
    [switch]$SinDescarga,
    [ValidateRange(1, 50)][int]$MBPrueba = 8,
    [string]$Carpeta = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PCCare\Red'),
    # Parametros que usa PC Care para ejecutar este modulo sin preguntas en consola:
    [string]$ArchivoInforme,   # ruta fija del informe de texto (UTF-8)
    [string]$ArchivoCambios,   # si se indica, escribe aqui la lista de cambios propuestos (JSON)
    [string]$AplicarSolo,      # nombres de cambios aprobados, separados por | (se aplican sin preguntar)
    [switch]$SinPausa,         # no esperar Enter al terminar
    [switch]$Confirmado        # con -Reparar: ya se confirmo en PC Care
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$rutaScript = $PSCommandPath
if (-not $rutaScript) { $rutaScript = $MyInvocation.MyCommand.Path }

$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (($Aplicar -or $Reparar -or $AplicarSolo) -and -not $esAdmin) {
    $arg = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $rutaScript), '-MBPrueba', [string]$MBPrueba)
    if ($Aplicar) { $arg += '-Aplicar' }
    if ($Reparar) { $arg += '-Reparar' }
    if ($SinDescarga) { $arg += '-SinDescarga' }
    if ($AplicarSolo) { $arg += @('-AplicarSolo', ('"{0}"' -f $AplicarSolo)) }
    if ($ArchivoInforme) { $arg += @('-ArchivoInforme', ('"{0}"' -f $ArchivoInforme)) }
    if ($SinPausa) { $arg += '-SinPausa' }
    if ($Confirmado) { $arg += '-Confirmado' }
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arg }
    catch { Write-Host 'Para aplicar cambios se necesitan permisos de administrador.' -ForegroundColor Red }
    exit
}

# ---------------------------------------------------------------------------
# Salida y registro
# ---------------------------------------------------------------------------
$script:inf = New-Object System.Collections.Generic.List[string]
$script:hall = New-Object System.Collections.ArrayList
$script:cambios = New-Object System.Collections.ArrayList
$script:bytesUsados = [double]0

function Linea {
    param([string]$T = '', [string]$C = 'Gray')
    Write-Host $T -ForegroundColor $C
    [void]$script:inf.Add($T)
}
function Titulo {
    param([string]$T)
    Linea ''
    Linea ('=== ' + $T + ' ===') 'Cyan'
}
function Nota {
    param([string]$Nivel, [string]$Titulo, [string]$Detalle = '')
    $c = 'Gray'
    if ($Nivel -eq 'OK') { $c = 'Green' }
    elseif ($Nivel -eq 'AVISO') { $c = 'Yellow' }
    elseif ($Nivel -eq 'PROBLEMA') { $c = 'Red' }
    Linea ('[{0,-8}] {1}' -f $Nivel, $Titulo) $c
    if ($Detalle) { Linea ('           ' + $Detalle) 'DarkGray' }
    [void]$script:hall.Add([pscustomobject]@{ Nivel = $Nivel; Titulo = $Titulo; Detalle = $Detalle })
}
function Add-Cambio {
    param([string]$Nombre, [string]$Efecto, [string[]]$Cmds, [string[]]$Revertir)
    [void]$script:cambios.Add([pscustomobject]@{ Nombre = $Nombre; Efecto = $Efecto; Cmds = $Cmds; Revertir = $Revertir })
}

# ---------------------------------------------------------------------------
# Pruebas
# ---------------------------------------------------------------------------
function Test-Latencia {
    param([string]$Destino, [int]$N = 15, [int]$Timeout = 2000)
    $p = New-Object System.Net.NetworkInformation.Ping
    $t = New-Object System.Collections.Generic.List[double]
    $perdidos = 0
    for ($i = 0; $i -lt $N; $i++) {
        try {
            $r = $p.Send($Destino, $Timeout)
            if ($r.Status -eq 'Success') { $t.Add([double]$r.RoundtripTime) } else { $perdidos++ }
        }
        catch { $perdidos++ }
        Start-Sleep -Milliseconds 150
    }
    $script:bytesUsados += $N * 64
    if ($t.Count -eq 0) { return [pscustomobject]@{ Destino = $Destino; Enviados = $N; Perdida = 100; Min = 0; Prom = 0; Max = 0; Jitter = 0; Ok = $false } }
    $m = $t | Measure-Object -Average -Minimum -Maximum
    $suma = 0.0
    for ($i = 1; $i -lt $t.Count; $i++) { $suma += [math]::Abs($t[$i] - $t[$i - 1]) }
    $jit = 0.0
    if ($t.Count -gt 1) { $jit = $suma / ($t.Count - 1) }
    return [pscustomobject]@{
        Destino = $Destino; Enviados = $N; Perdida = [math]::Round(100 * $perdidos / $N, 0)
        Min = $m.Minimum; Prom = [math]::Round($m.Average, 0); Max = $m.Maximum; Jitter = [math]::Round($jit, 0); Ok = $true
    }
}

function Get-MtuRuta {
    param([string]$Destino)
    $p = New-Object System.Net.NetworkInformation.Ping
    $opt = New-Object System.Net.NetworkInformation.PingOptions(64, $true)
    $pasa = {
        param([int]$Carga)
        $buf = New-Object byte[] $Carga
        for ($k = 0; $k -lt 2; $k++) {
            try { $r = $p.Send($Destino, 2000, $buf, $opt); if ($r.Status -eq 'Success') { return $true } } catch { }
        }
        return $false
    }
    if (& $pasa 1472) { return 1500 }
    $lo = 1200; $hi = 1472
    if (-not (& $pasa $lo)) { return 0 }
    while (($hi - $lo) -gt 1) {
        $mid = [int][math]::Floor(($lo + $hi) / 2)
        if (& $pasa $mid) { $lo = $mid } else { $hi = $mid }
    }
    return ($lo + 28)
}

function Get-MtuInterfaz {
    param([string]$Nombre)
    $sal = & netsh interface ipv4 show subinterfaces 2>$null
    foreach ($l in $sal) {
        if ($l -match '^\s*(\d+)\s+-?\d+\s+\d+\s+\d+\s+(.+?)\s*$') {
            if ($Matches[2] -eq $Nombre) { return [int64]$Matches[1] }
        }
    }
    return 0
}

function Test-Descarga {
    param([string]$Url, [double]$LimiteBytes, [int]$MaxSeg = 25)
    try { [Net.ServicePointManager]::SecurityProtocol = 3072 } catch { }
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Timeout = 10000
    $req.ReadWriteTimeout = 10000
    $req.UserAgent = 'Mozilla/5.0 OptimizarRed'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $resp = $req.GetResponse()
    $ttfb = $sw.ElapsedMilliseconds
    $st = $resp.GetResponseStream()
    $buf = New-Object byte[] 65536
    $total = [double]0
    while (($n = $st.Read($buf, 0, $buf.Length)) -gt 0) {
        $total += $n
        if ($total -ge $LimiteBytes -or $sw.Elapsed.TotalSeconds -gt $MaxSeg) { break }
    }
    $sw.Stop()
    $resp.Close()
    $seg = ($sw.ElapsedMilliseconds - $ttfb) / 1000.0
    if ($seg -lt 0.05) { $seg = 0.05 }
    return [pscustomobject]@{ Mbps = [math]::Round($total * 8 / 1e6 / $seg, 1); Bytes = $total; TtfbMs = $ttfb }
}

function Get-MedianaDns {
    param([string]$Servidor)
    $nombres = 'www.microsoft.com', 'www.google.com', 'www.cloudflare.com', 'www.office.com', 'www.bing.com'
    $t = New-Object System.Collections.Generic.List[double]
    foreach ($n in $nombres) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try { [void](Resolve-DnsName -Name $n -Server $Servidor -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop); $t.Add($sw.Elapsed.TotalMilliseconds) } catch { }
    }
    $script:bytesUsados += 5 * 200
    if ($t.Count -lt 3) { return $null }
    $o = @($t | Sort-Object)
    return [math]::Round($o[[int][math]::Floor($o.Count / 2)], 0)
}

function Test-MismaRed {
    param([string]$Ip, [string]$Mascara, [string]$Gw)
    try {
        $a = [Net.IPAddress]::Parse($Ip).GetAddressBytes()
        $m = [Net.IPAddress]::Parse($Mascara).GetAddressBytes()
        $g = [Net.IPAddress]::Parse($Gw).GetAddressBytes()
        for ($i = 0; $i -lt 4; $i++) { if (($a[$i] -band $m[$i]) -ne ($g[$i] -band $m[$i])) { return $false } }
        return $true
    }
    catch { return $true }
}

function Invoke-Cmd {
    param([string]$Comando)
    $global:LASTEXITCODE = 0
    $sal = Invoke-Expression ($Comando + ' 2>&1')
    return [pscustomobject]@{ Codigo = $global:LASTEXITCODE; Salida = (($sal | Out-String).Trim()) }
}

# ---------------------------------------------------------------------------
# 1. Equipo
# ---------------------------------------------------------------------------
$so = Get-CimInstance Win32_OperatingSystem
Linea 'OptimizarRed: validación y optimización de conectividad' 'White'
Linea ('Equipo: {0}  |  {1} (compilación {2})  |  PowerShell {3}' -f $env:COMPUTERNAME, $so.Caption, $so.BuildNumber, $PSVersionTable.PSVersion)
$modo = 'Solo diagnóstico (no se cambia nada)'
if ($Aplicar) { $modo = 'Diagnóstico y aplicación de cambios con confirmación' }
if ($AplicarSolo) { $modo = 'Diagnóstico y aplicación de los cambios aprobados en PC Care' }
Linea ('Modo: ' + $modo + '  |  Administrador: ' + $(if ($esAdmin) { 'sí' } else { 'no' }))
if (-not $SinDescarga) { Linea ('Esta prueba consume unos {0} MB de tu plan de datos (descarga de prueba).' -f ($MBPrueba + 1)) 'Yellow' }

# ---------------------------------------------------------------------------
# 2. Adaptadores y ruta preferida
# ---------------------------------------------------------------------------
Titulo 'Adaptadores de red activos'
$cfgs = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE')
$adaptadores = @(Get-CimInstance Win32_NetworkAdapter)
$rutas = @(Get-CimInstance Win32_IP4RouteTable -Filter "Destination='0.0.0.0'")
$lista = New-Object System.Collections.Generic.List[object]
foreach ($c in $cfgs) {
    $a = $adaptadores | Where-Object { [string]$_.DeviceID -eq [string]$c.Index } | Select-Object -First 1
    $ip4 = @($c.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
    if ($ip4.Count -eq 0) { continue }
    $nombre = ''; $pnp = ''; $nom = ''; $vel = 0
    if ($a) {
        $nombre = [string]$a.NetConnectionID; $pnp = [string]$a.PNPDeviceID; $nom = [string]$a.Name
        if ($null -ne $a.Speed) { $vel = [math]::Round([double]$a.Speed / 1e6, 0) }
    }
    $txt = '{0} {1} {2} {3}' -f $c.Description, $nom, $pnp, $nombre
    $virtual = ($txt -match 'Hyper-V|VMware|VirtualBox|vEthernet|Loopback|Bluetooth|WSL|Npcap')
    $vpn = ($txt -match 'VPN|TAP-|WireGuard|Tunnel|Fortinet|AnyConnect|OpenVPN|Kerio|Wintun')
    $wifi = ($txt -match 'Wi-?Fi|Wireless|802\.11|WLAN|Inal')
    $usb = (($txt -match 'RNDIS|Remote NDIS|NCM|Apple Mobile|iPhone|Android|Samsung Mobile|USB\\') -or ($ip4[0] -match '^(192\.168\.(42|43|44)\.|172\.20\.10\.)')) -and -not $wifi -and -not $virtual
    $gws = @($c.DefaultIPGateway | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
    $mascara = ''
    if ($c.IPSubnet) { $mascara = [string]@($c.IPSubnet)[0] }
    $gw = ''; $gwFuera = @()
    foreach ($g in $gws) {
        if ($mascara -and -not (Test-MismaRed $ip4[0] $mascara $g)) { $gwFuera += $g }
        elseif (-not $gw) { $gw = $g }
    }
    if (-not $gw -and $gws.Count -gt 0) { $gw = $gws[0] }
    $metrica = 9999
    $hecho = $false
    if ((Get-Command Get-NetRoute -ErrorAction SilentlyContinue) -and (Get-Command Get-NetIPInterface -ErrorAction SilentlyContinue)) {
        try {
            $nr = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex ([int]$c.InterfaceIndex) -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
            $ni = Get-NetIPInterface -InterfaceIndex ([int]$c.InterfaceIndex) -AddressFamily IPv4 -ErrorAction Stop
            if ($nr -and $ni) { $metrica = [int]$nr.RouteMetric + [int]$ni.InterfaceMetric; $hecho = $true }
        }
        catch { }
    }
    if (-not $hecho) {
        $ruta = $rutas | Where-Object { [int]$_.InterfaceIndex -eq [int]$c.InterfaceIndex } | Sort-Object Metric1 | Select-Object -First 1
        if ($ruta) { $metrica = [int]$ruta.Metric1 }
    }
    $tipo = 'Ethernet'
    if ($usb) { $tipo = 'USB (tethering)' } elseif ($wifi) { $tipo = 'Wi-Fi' } elseif ($vpn) { $tipo = 'VPN' } elseif ($virtual) { $tipo = 'Virtual' }
    $lista.Add([pscustomobject]@{
            Nombre = $nombre; Descripcion = [string]$c.Description; Tipo = $tipo; Ip = $ip4[0]; Ips = @($c.IPAddress)
            Gateway = $gw; GwFuera = $gwFuera; DnsActual = @($c.DNSServerSearchOrder); Dhcp = [bool]$c.DHCPEnabled; Indice = [int]$c.InterfaceIndex
            MetricaInterfaz = [int]$c.IPConnectionMetric; MetricaRuta = $metrica; VelMbps = $vel; Usb = $usb; Wifi = $wifi; Vpn = $vpn; Virtual = $virtual
        })
}
if ($lista.Count -eq 0) {
    Nota 'PROBLEMA' 'No hay ningún adaptador con dirección IP' 'Conecta el cable USB, activa "Compartir Internet por USB" en el celular y vuelve a ejecutar.'
}
else {
    Linea ('{0,-22} {1,-16} {2,-16} {3,-16} {4,8} {5,8}' -f 'Adaptador', 'Tipo', 'IP', 'Puerta', 'Mbps', 'Métrica') 'White'
    foreach ($x in $lista) {
        Linea ('{0,-22} {1,-16} {2,-16} {3,-16} {4,8} {5,8}' -f ([string]$x.Nombre).Substring(0, [math]::Min(22, ([string]$x.Nombre).Length)), $x.Tipo, $x.Ip, $x.Gateway, $x.VelMbps, $x.MetricaRuta)
    }
}

$candidatos = @($lista | Where-Object { -not $_.Virtual -and -not $_.Vpn -and $_.Gateway })
$preferido = $candidatos | Sort-Object MetricaRuta | Select-Object -First 1
$objetivo = $lista | Where-Object { $_.Usb } | Select-Object -First 1
$vpnActiva = @($lista | Where-Object { $_.Vpn })

if (-not $objetivo -and $lista.Count -gt 0) {
    Nota 'AVISO' 'No se detectó un adaptador USB de tethering con dirección IP' 'En el celular activa "Compartir Internet por USB" (Android) o "Punto de acceso personal" con cable (iPhone). Se analizará el adaptador preferido.'
    $objetivo = $preferido
    try {
        $candUsb = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { ($_.InterfaceDescription -match 'RNDIS|Remote NDIS|NCM|Apple Mobile|iPhone|Android|Samsung Mobile|USB') -and ($_.InterfaceDescription -notmatch 'Bluetooth|Wi-?Fi|Wireless|Virtual|VMware|Hyper-V') })
        if ($candUsb.Count -gt 0) {
            foreach ($u in $candUsb) { Nota 'INFO' ('Adaptador USB visto pero sin conexión usable: {0} (estado: {1})' -f $u.Name, $u.Status) 'Si dice Disconnected o Not Present: reconecta el cable, desactiva y activa "Compartir Internet por USB" en el celular. Si no tiene IP, desactiva y activa el adaptador en Windows.' }
        }
        else {
            Nota 'INFO' 'Windows no ve ningún adaptador USB de tethering' 'Causas típicas: cable solo de carga, celular en modo "Solo carga" (elige "Transferencia de archivos"), falta el controlador RNDIS, o en iPhone falta Apple Devices/iTunes. Prueba otro cable y otro puerto USB directo.'
        }
    } catch { }
}
elseif ($objetivo) {
    Nota 'OK' ('Adaptador de tethering detectado: ' + $objetivo.Nombre) ('{0} | IP {1} | puerta {2}' -f $objetivo.Descripcion, $objetivo.Ip, $objetivo.Gateway)
    if ($objetivo.VelMbps -gt 0 -and $objetivo.VelMbps -lt 100) {
        Nota 'AVISO' ('El enlace USB negocia solo {0} Mbps' -f $objetivo.VelMbps) 'Prueba otro cable de datos (no solo de carga) y un puerto USB directo del equipo, sin hub.'
    }
}

if ($objetivo -and $preferido) {
    if ($preferido.Indice -ne $objetivo.Indice) {
        Nota 'PROBLEMA' ('Windows prefiere {0} ({1}) antes que el USB' -f $preferido.Nombre, $preferido.Tipo) 'Parte del tráfico sale por la otra red. Se propone dar prioridad al USB.'
        $rev = @()
        if (Get-Command Set-NetIPInterface -ErrorAction SilentlyContinue) {
            $rev = @('powershell.exe -NoProfile -Command "Set-NetIPInterface -InterfaceIndex {0} -AddressFamily IPv4 -AutomaticMetric Enabled"' -f $objetivo.Indice)
        }
        else { $rev = @('netsh interface ipv4 set interface interface={0} metric={1}' -f $objetivo.Indice, $objetivo.MetricaInterfaz) }
        Add-Cambio 'Dar prioridad al adaptador USB' ('Métrica de interfaz de {0} en 5. Windows usará primero el USB.' -f $objetivo.Nombre) @(('netsh interface ipv4 set interface interface={0} metric=5' -f $objetivo.Indice)) $rev
    }
    elseif ($objetivo.Usb) { Nota 'OK' 'Windows ya prefiere el adaptador de tethering para salir a internet' }
}
$otrosWifi = @($lista | Where-Object { $_.Wifi -and (-not $objetivo -or $_.Indice -ne $objetivo.Indice) })
if ($otrosWifi.Count -gt 0) {
    Nota 'AVISO' 'El Wi-Fi también está conectado' 'En un café, esa red es pública y compite con tu USB. Conviene desconectarla mientras usas el tethering.'
    Add-Cambio 'Desconectar el Wi-Fi público' 'Cierra la conexión Wi-Fi actual. Se vuelve a conectar desde la barra de tareas.' @('netsh wlan disconnect') @('rem Vuelve a conectar el Wi-Fi manualmente desde la barra de tareas si lo necesitas')
}
foreach ($x in ($lista | Where-Object { -not $_.Virtual -and $_.GwFuera.Count -gt 0 })) {
    Nota 'AVISO' ('{0}: puerta de enlace fuera de la red del adaptador ({1})' -f $x.Nombre, ($x.GwFuera -join ', ')) ('La IP {0} no pertenece a esa red, por eso no responde. Si internet funciona, es una puerta sobrante o una configuración manual vieja: revísala con "ipconfig /all".' -f $x.Ip)
}
if ($vpnActiva.Count -gt 0) { Nota 'INFO' ('VPN activa: ' + (($vpnActiva | ForEach-Object { $_.Nombre }) -join ', ')) 'No se cambiará el DNS mientras haya VPN, para no romper nombres internos.' }

# ---------------------------------------------------------------------------
# 3. Latencia, pérdida y jitter
# ---------------------------------------------------------------------------
Titulo 'Latencia, pérdida de paquetes y jitter (15 pings por destino)'
$destinos = @()
$etiquetaGw = 'Puerta de enlace'
if ($objetivo -and $objetivo.Usb) { $etiquetaGw = 'Puerta del celular' }
if ($objetivo -and $objetivo.Gateway) { $destinos += , @($etiquetaGw, $objetivo.Gateway) }
$destinos += , @('Cloudflare', '1.1.1.1')
$destinos += , @('Google', '8.8.8.8')
$resPing = @{}
Linea ('{0,-20} {1,-14} {2,9} {3,7} {4,7} {5,7} {6,8}' -f 'Destino', 'Dirección', 'Pérdida %', 'Mín', 'Prom', 'Máx', 'Jitter') 'White'
foreach ($d in $destinos) {
    $r = Test-Latencia $d[1]
    $resPing[$d[0]] = $r
    Linea ('{0,-20} {1,-14} {2,9} {3,7} {4,7} {5,7} {6,8}' -f $d[0], $d[1], $r.Perdida, $r.Min, $r.Prom, $r.Max, $r.Jitter)
}
if ($resPing.ContainsKey($etiquetaGw)) {
    $g = $resPing[$etiquetaGw]
    if (-not $g.Ok) { Nota 'INFO' ('{0}: no responde ping' -f $etiquetaGw) 'Muchos celulares y routers bloquean el ping. Se usa el resto de pruebas como referencia.' }
    elseif (-not $objetivo.Usb) { Nota 'OK' ('{0} responde ({1} ms)' -f $etiquetaGw, $g.Prom) }
    elseif ($g.Prom -gt 20 -or $g.Perdida -gt 0) { Nota 'PROBLEMA' ('El enlace USB al celular es lento o pierde paquetes ({0} ms, {1}% perdido)' -f $g.Prom, $g.Perdida) 'Cambia el cable, usa un puerto USB directo, sin hub, y revisa que el celular no esté en ahorro de batería.' }
    else { Nota 'OK' ('Enlace USB con el celular sano ({0} ms)' -f $g.Prom) }
}
$internet = @('Cloudflare', 'Google') | ForEach-Object { $resPing[$_] } | Where-Object { $_.Ok }
if (@($internet).Count -eq 0) {
    Nota 'PROBLEMA' 'No hay respuesta de internet por ping' 'Puede ser un bloqueo de ICMP del operador o que el plan sin saldo/estancado. Se continúa con pruebas HTTP.'
}
else {
    $mejor = @($internet) | Sort-Object Perdida, Prom | Select-Object -First 1
    $prom = [int]$mejor.Prom
    $jit = [int]$mejor.Jitter
    $perd = [int]$mejor.Perdida
    $perdMax = [int]((@($internet) | Measure-Object Perdida -Maximum).Maximum)
    $destPeor = @($internet) | Sort-Object Perdida -Descending | Select-Object -First 1
    if ($perd -gt 2) { Nota 'PROBLEMA' ('Pérdida de paquetes hacia internet: {0}% (incluso hacia el mejor destino)' -f $perd) 'Es pérdida real del enlace: mejora la señal, cambia el cable USB o de puerto, o prueba otra banda.' }
    elseif ($perdMax -gt 20) { Nota 'INFO' ('{0} perdió {1}% de los pings, pero {2} respondió con {3}%' -f $destPeor.Destino, $perdMax, $mejor.Destino, $perd) 'Es limitación de ICMP hacia ese destino (límite de tasa del operador o del router), no del enlace. Tu conexión no está perdiendo paquetes.' }
    else { Nota 'OK' ('Pérdida de paquetes baja ({0}%)' -f $perd) }
    if ($prom -gt 150) { Nota 'PROBLEMA' ('Latencia alta hacia internet: {0} ms' -f $prom) 'Señal móvil débil o red congestionada. Las videollamadas y el escritorio remoto se sentirán lentos.' }
    elseif ($prom -gt 80) { Nota 'AVISO' ('Latencia moderada: {0} ms' -f $prom) 'Aceptable para web y correo; justa para videollamadas.' }
    else { Nota 'OK' ('Latencia buena: {0} ms' -f $prom) }
    if ($jit -gt 30) { Nota 'AVISO' ('Jitter alto: {0} ms' -f $jit) 'Las llamadas VoIP y videollamadas pueden cortarse. Mejora la cobertura o usa la banda 5G si tu plan la permite.' }
}

# ---------------------------------------------------------------------------
# 4. MTU
# ---------------------------------------------------------------------------
Titulo 'Tamaño de paquete (MTU)'
if ($objetivo -and ($resPing.ContainsKey('Cloudflare') -and $resPing['Cloudflare'].Ok)) {
    $mtuRuta = Get-MtuRuta '1.1.1.1'
    $mtuIf = Get-MtuInterfaz $objetivo.Nombre
    if ($mtuRuta -eq 0) { Nota 'INFO' 'No se pudo medir el MTU de la ruta' 'La red bloquea los paquetes de prueba sin fragmentar. No se cambia nada.' }
    else {
        Linea ('MTU de la interfaz: {0}  |  MTU soportado por la ruta: {1}' -f $mtuIf, $mtuRuta)
        if ($mtuIf -gt 0 -and $mtuRuta -lt $mtuIf -and $mtuRuta -ge 1280) {
            Nota 'PROBLEMA' ('El MTU de la interfaz ({0}) es mayor que el de la ruta ({1})' -f $mtuIf, $mtuRuta) 'Causa páginas que no cargan por completo o conexiones que se cuelgan en redes móviles.'
            Add-Cambio 'Ajustar el MTU al de la ruta' ('MTU de {0} en {1} hasta el próximo reinicio.' -f $objetivo.Nombre, $mtuRuta) @(('netsh interface ipv4 set subinterface "{0}" mtu={1} store=active' -f $objetivo.Nombre, $mtuRuta)) @(('netsh interface ipv4 set subinterface "{0}" mtu={1} store=active' -f $objetivo.Nombre, $mtuIf))
        }
        else { Nota 'OK' 'El MTU es adecuado para esta red' }
    }
}
else { Nota 'INFO' 'Prueba de MTU omitida (sin respuesta de internet por ping)' }

# ---------------------------------------------------------------------------
# 5. DNS
# ---------------------------------------------------------------------------
Titulo 'Velocidad de resolución DNS (mediana de 5 consultas)'
if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) { Nota 'INFO' 'Prueba DNS omitida (Windows sin Resolve-DnsName)' }
else {
    $pruebas = New-Object System.Collections.Generic.List[object]
    $actual = ''
    if ($objetivo -and $objetivo.DnsActual.Count -gt 0) { $actual = [string]$objetivo.DnsActual[0] }
    $cands = @()
    if ($actual) { $cands += , @('DNS actual del adaptador', $actual) }
    $cands += , @('Cloudflare', '1.1.1.1')
    $cands += , @('Google', '8.8.8.8')
    $cands += , @('Quad9', '9.9.9.9')
    foreach ($c in $cands) {
        $m = Get-MedianaDns $c[1]
        $pruebas.Add([pscustomobject]@{ Nombre = $c[0]; Ip = $c[1]; Ms = $m })
        if ($null -eq $m) { Linea ('{0,-32} {1,-12} sin respuesta' -f $c[0], $c[1]) } else { Linea ('{0,-32} {1,-12} {2,6} ms' -f $c[0], $c[1], $m) }
    }
    $ok = @($pruebas | Where-Object { $null -ne $_.Ms } | Sort-Object Ms)
    $act = $pruebas | Where-Object { $_.Nombre -like 'DNS actual*' } | Select-Object -First 1
    if ($ok.Count -eq 0) { Nota 'PROBLEMA' 'Ningún servidor DNS respondió' 'Sin DNS no se abren sitios por nombre. Revisa el plan de datos y vuelve a conectar el USB.' }
    elseif ($act -and $null -eq $act.Ms) {
        Nota 'PROBLEMA' 'El DNS que entrega el celular no responde' 'Es una causa habitual de "hay conexión pero no abre nada".'
    }
    elseif ($act -and $ok[0].Ip -ne $act.Ip -and ($act.Ms - $ok[0].Ms) -ge 15 -and $ok[0].Ms -lt ($act.Ms * 0.7)) {
        Nota 'AVISO' ('{0} responde {1} ms más rápido que el DNS actual' -f $ok[0].Nombre, ($act.Ms - $ok[0].Ms))
    }
    else { Nota 'OK' 'El DNS actual responde bien' }
    $mejor = $ok | Select-Object -First 1
    $hayProblemaDns = ($ok.Count -gt 0) -and $act -and (($null -eq $act.Ms) -or ($mejor.Ip -ne $act.Ip -and ($act.Ms - $mejor.Ms) -ge 15 -and $mejor.Ms -lt ($act.Ms * 0.7)))
    if ($hayProblemaDns -and $objetivo -and $vpnActiva.Count -eq 0) {
        $sec = '1.0.0.1'
        if ($mejor.Ip -eq '8.8.8.8') { $sec = '8.8.4.4' } elseif ($mejor.Ip -eq '9.9.9.9') { $sec = '149.112.112.112' }
        $rev = @(('netsh interface ip set dns name="{0}" dhcp' -f $objetivo.Nombre))
        if (-not $objetivo.Dhcp -and $objetivo.DnsActual.Count -gt 0) {
            $rev = @(('netsh interface ip set dns name="{0}" static {1} primary' -f $objetivo.Nombre, $objetivo.DnsActual[0]))
            if ($objetivo.DnsActual.Count -gt 1) { $rev += ('netsh interface ip add dns name="{0}" {1} index=2' -f $objetivo.Nombre, $objetivo.DnsActual[1]) }
        }
        Add-Cambio ('Usar DNS de ' + $mejor.Nombre + ' en el adaptador USB') ('DNS {0} y {1} solo en {2}.' -f $mejor.Ip, $sec, $objetivo.Nombre) @(('netsh interface ip set dns name="{0}" static {1} primary' -f $objetivo.Nombre, $mejor.Ip), ('netsh interface ip add dns name="{0}" {1} index=2' -f $objetivo.Nombre, $sec)) $rev
    }
}

# ---------------------------------------------------------------------------
# 6. Velocidad real
# ---------------------------------------------------------------------------
Titulo 'Velocidad de descarga real'
if ($SinDescarga) { Nota 'INFO' 'Descarga omitida por -SinDescarga (no se gastan datos)' }
else {
    $limite = [double]$MBPrueba * 1MB
    $urls = @(('https://speed.cloudflare.com/__down?bytes={0}' -f [int64]$limite), 'http://speedtest.tele2.net/10MB.zip')
    $res = $null
    foreach ($u in $urls) {
        try { $res = Test-Descarga $u $limite; break } catch { Linea ('   Sin acceso a ' + ([uri]$u).Host + ': ' + $_.Exception.Message) 'DarkGray' }
    }
    if (-not $res) { Nota 'PROBLEMA' 'No se pudo completar la descarga de prueba' 'Revisa el saldo del plan, el proxy y que el navegador abra páginas.' }
    else {
        $script:bytesUsados += $res.Bytes
        Linea ('Descarga: {0} Mbps  |  respuesta del servidor: {1} ms  |  datos usados: {2:N1} MB' -f $res.Mbps, $res.TtfbMs, ($res.Bytes / 1MB))
        if ($res.Mbps -lt 5) { Nota 'PROBLEMA' ('Velocidad muy baja: {0} Mbps' -f $res.Mbps) 'Suficiente solo para mensajería y correo. Revisa señal, throttling del plan o consumo en segundo plano.' }
        elseif ($res.Mbps -lt 15) { Nota 'AVISO' ('Velocidad moderada: {0} Mbps' -f $res.Mbps) 'Sirve para trabajo en la nube y videollamadas sencillas.' }
        else { Nota 'OK' ('Velocidad buena: {0} Mbps' -f $res.Mbps) }
        Linea '(Una sola conexión suele medir menos que el máximo real del plan. Úsalo como referencia.)' 'DarkGray'
    }
}

# ---------------------------------------------------------------------------
# 7. Configuración de Windows que afecta la conexión
# ---------------------------------------------------------------------------
Titulo 'Configuración de Windows'

# Conexion de uso medido
$costo = ''
try {
    [void][Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]
    $perfil = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
    if ($perfil) { $costo = [string]$perfil.GetConnectionCost().NetworkCostType }
}
catch { }
if ($costo -eq 'Unrestricted') {
    Nota 'AVISO' 'Windows NO trata esta conexión como de uso medido' 'Las actualizaciones y la sincronización pueden gastar tu plan. Actívalo en Configuración > Red e Internet > (tu conexión) > Conexión de uso medido.'
}
elseif ($costo -in 'Fixed', 'Variable') { Nota 'OK' 'La conexión está marcada como de uso medido' 'Windows pospone actualizaciones grandes.' }
else { Nota 'INFO' 'No se pudo leer si la conexión es de uso medido' 'Revísalo manualmente en Configuración > Red e Internet.' }

# Ajuste automatico de TCP
$tcp = @(& netsh int tcp show global 2>$null)
$lineaTcp = $tcp | Where-Object { $_ -match '(?i)auto-?tuning|ajuste autom|autoajuste' } | Select-Object -First 1
if ($lineaTcp) {
    $valor = ''
    if ($lineaTcp -match ':') { $valor = ($lineaTcp -split ':', 2)[1].Trim() }
    if ($valor -match '(?i)disabled|deshabilit|desactiv') {
        Nota 'PROBLEMA' 'El ajuste automático de la ventana TCP está desactivado' 'Limita la velocidad en enlaces con latencia, como los móviles.'
        Add-Cambio 'Activar el ajuste automático de TCP' 'Vuelve al valor normal recomendado por Microsoft.' @('netsh int tcp set global autotuninglevel=normal') @('netsh int tcp set global autotuninglevel=disabled')
    }
    else { Nota 'OK' ('Ajuste automático de TCP: ' + $valor) }
}

# Suspension selectiva de USB
try {
    $q = @(& powercfg /query SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4738-b5a4-1d57a5ce7ae9 2>$null)
    $hex = @([regex]::Matches(($q -join "`n"), '0x[0-9a-fA-F]{8}') | ForEach-Object { [Convert]::ToInt32($_.Value.Substring(2), 16) })
    if ($hex.Count -ge 2) {
        $ac = $hex[$hex.Count - 2]; $dc = $hex[$hex.Count - 1]
        if ($ac -eq 1 -or $dc -eq 1) {
            Nota 'AVISO' 'La suspensión selectiva de USB está activa' 'Windows puede apagar el puerto USB y cortar el tethering sin avisar. Desactivarla aumenta un poco el consumo de batería.'
            $g1 = '2a737441-1930-4402-8d77-b2bebba308a3'; $g2 = '48e6b7a6-50f5-4738-b5a4-1d57a5ce7ae9'
            Add-Cambio 'Desactivar la suspensión selectiva de USB' 'Evita cortes del tethering en el plan de energía actual (red eléctrica y batería).' @(
                ('powercfg /setacvalueindex SCHEME_CURRENT {0} {1} 0' -f $g1, $g2), ('powercfg /setdcvalueindex SCHEME_CURRENT {0} {1} 0' -f $g1, $g2), 'powercfg /setactive SCHEME_CURRENT') @(
                ('powercfg /setacvalueindex SCHEME_CURRENT {0} {1} {2}' -f $g1, $g2, $ac), ('powercfg /setdcvalueindex SCHEME_CURRENT {0} {1} {2}' -f $g1, $g2, $dc), 'powercfg /setactive SCHEME_CURRENT')
        }
        else { Nota 'OK' 'La suspensión selectiva de USB ya está desactivada' }
    }
}
catch { }

# Proxy del sistema
try {
    $ie = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    $proxyOn = ([int]$ie.ProxyEnable -eq 1)
    $pac = [string]$ie.AutoConfigURL
    if ($proxyOn -or $pac) {
        Nota 'AVISO' 'Hay un proxy configurado en Windows' ('{0}{1}Si es de tu empresa y no usas VPN, puede bloquear la navegación fuera de la oficina.' -f $(if ($proxyOn) { 'Servidor: ' + [string]$ie.ProxyServer + '. ' } else { '' }), $(if ($pac) { 'Script PAC: ' + $pac + '. ' } else { '' }))
    }
    else { Nota 'OK' 'Sin proxy configurado' }
}
catch { }

# IPv6
if ($objetivo) {
    $globalV6 = @($objetivo.Ips | Where-Object { $_ -match ':' -and $_ -notmatch '^fe80' })
    if ($globalV6.Count -gt 0) {
        $r6 = Test-Latencia '2606:4700:4700::1111' 4
        if ($r6.Ok) { Nota 'OK' ('IPv6 operativo ({0} ms)' -f $r6.Prom) }
        else { Nota 'AVISO' 'Hay dirección IPv6 pero no sale a internet' 'Puede causar esperas de varios segundos al abrir sitios. No se desactiva IPv6 por seguridad; prueba reconectar el USB.' }
    }
    else { Nota 'INFO' 'La red solo entrega IPv4 (normal en muchos planes móviles)' }
}

# Portal cautivo / salida HTTP
try {
    $req = [Net.HttpWebRequest]::Create('http://www.msftconnecttest.com/connecttest.txt')
    $req.Timeout = 8000; $req.AllowAutoRedirect = $false
    $resp = $req.GetResponse()
    $lector = New-Object IO.StreamReader($resp.GetResponseStream())
    $cuerpo = $lector.ReadToEnd(); $lector.Close(); $resp.Close()
    if ($cuerpo -match 'Microsoft Connect Test') { Nota 'OK' 'Salida a internet confirmada (sin portal cautivo)' }
    else { Nota 'PROBLEMA' 'La red intercepta la conexión (portal cautivo o filtro)' 'Abre el navegador y acepta el portal, o desconecta el Wi-Fi del café para usar solo el USB.' }
}
catch { Nota 'AVISO' 'No se pudo confirmar la salida HTTP a internet' $_.Exception.Message }

# Programas que consumen datos en segundo plano
$sync = 'OneDrive', 'Dropbox', 'GoogleDriveFS', 'ms-teams', 'Teams', 'Steam', 'EpicGamesLauncher', 'qbittorrent', 'utorrent', 'BitTorrent', 'Spotify', 'MicrosoftEdgeUpdate'
$activos = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $sync -contains $_.ProcessName } | Select-Object -ExpandProperty ProcessName -Unique)
if ($activos.Count -gt 0) { Nota 'INFO' 'Programas que pueden gastar datos en segundo plano' (($activos -join ', ') + '. Pausa la sincronización mientras uses el plan del celular.') }
if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
    try {
        $con = @(Get-NetTCPConnection -State Established -ErrorAction Stop | Where-Object { $_.RemoteAddress -notmatch '^(127\.|::1|0\.0\.0\.0)' })
        $top = @($con | Group-Object OwningProcess | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object {
                $n = 'sistema'; try { $n = (Get-Process -Id ([int]$_.Name) -ErrorAction Stop).ProcessName } catch { }
                '{0} ({1})' -f $n, $_.Count })
        if ($top.Count -gt 0) { Linea ('Más conexiones abiertas: ' + ($top -join ', ')) 'DarkGray' }
    }
    catch { }
}

# ---------------------------------------------------------------------------
# 8. Resumen
# ---------------------------------------------------------------------------
Titulo 'Resumen'
$nProb = @($script:hall | Where-Object { $_.Nivel -eq 'PROBLEMA' }).Count
$nAv = @($script:hall | Where-Object { $_.Nivel -eq 'AVISO' }).Count
$nOk = @($script:hall | Where-Object { $_.Nivel -eq 'OK' }).Count
Linea ('{0} en orden, {1} avisos, {2} problemas. Datos usados por esta prueba: {3:N1} MB.' -f $nOk, $nAv, $nProb, ($script:bytesUsados / 1MB)) 'White'
if ($nProb -gt 0) {
    Linea 'Qué atender primero:' 'White'
    foreach ($h in ($script:hall | Where-Object { $_.Nivel -eq 'PROBLEMA' })) { Linea ('  - ' + $h.Titulo) 'Red' }
}
if ($script:cambios.Count -gt 0 -and -not $Aplicar -and -not $AplicarSolo) {
    Linea ''
    Linea ('Cambios propuestos ({0}), no aplicados:' -f $script:cambios.Count) 'Yellow'
    foreach ($c in $script:cambios) { Linea ('  - {0}: {1}' -f $c.Nombre, $c.Efecto) 'Yellow' }
    if ($ArchivoCambios) { Linea 'Márcalos en la lista de PC Care y pulsa "Aplicar mejoras marcadas".' 'Yellow' }
    else { Linea 'Para aplicarlos con confirmación, ejecuta OptimizarRed_Aplicar.cmd' 'Yellow' }
}

# ---------------------------------------------------------------------------
# 9. Aplicar cambios con confirmacion
# ---------------------------------------------------------------------------
$revertir = New-Object System.Collections.Generic.List[string]
$aplicados = 0
if (($Aplicar -or $AplicarSolo) -and $script:cambios.Count -gt 0) {
    Titulo 'Aplicar cambios'
    $soloNombres = @()
    if ($AplicarSolo) { $soloNombres = @($AplicarSolo -split '\|' | Where-Object { $_ }) }
    foreach ($c in $script:cambios) {
        if ($soloNombres.Count -gt 0 -and ($soloNombres -notcontains $c.Nombre)) { continue }
        Linea ''
        Linea ('Cambio: ' + $c.Nombre) 'White'
        Linea ('  Efecto: ' + $c.Efecto)
        foreach ($cmd in $c.Cmds) { Linea ('  Comando: ' + $cmd) 'DarkGray' }
        if ($soloNombres.Count -gt 0) { $resp = 's'; Linea '  Aprobado en PC Care.' 'DarkGray' }
        else { $resp = Read-Host '  ¿Aplicar este cambio? (S/N)' }
        if ($resp -notmatch '^(s|si|sí|y|yes)$') { Linea '  Omitido.'; continue }
        $fallo = $false
        foreach ($cmd in $c.Cmds) {
            $r = Invoke-Cmd $cmd
            if ($r.Codigo -ne 0) { $fallo = $true; Linea ('  ERROR ({0}): {1}' -f $r.Codigo, $r.Salida) 'Red' }
        }
        if ($fallo) { continue }
        $aplicados++
        Linea '  Aplicado.' 'Green'
        $revertir.Add('rem ' + $c.Nombre)
        foreach ($rv in $c.Revertir) { $revertir.Add($rv) }
    }
}
if ($Reparar) {
    Titulo 'Reparación de la pila de red'
    Linea 'Reinicia Winsock y la pila IP. Corrige fallos profundos de conexión. NO se puede revertir y exige reiniciar el equipo.' 'Yellow'
    if ($Confirmado) { $resp = 's' }
    else { $resp = Read-Host '¿Ejecutar la reparación? (S/N)' }
    if ($resp -match '^(s|si|sí|y|yes)$') {
        foreach ($cmd in 'ipconfig /flushdns', 'netsh winsock reset', 'netsh int ip reset') {
            $r = Invoke-Cmd $cmd
            Linea ('  {0} -> código {1}' -f $cmd, $r.Codigo)
        }
        Linea 'Reinicia el equipo para completar la reparación.' 'Yellow'
        $aplicados++
    }
}
if ($aplicados -gt 0) {
    [void](Invoke-Cmd 'ipconfig /flushdns')
    Linea ''
    Linea ('{0} cambios aplicados. Caché DNS vaciada.' -f $aplicados) 'Green'
}

# ---------------------------------------------------------------------------
# 10. Archivos de salida
# ---------------------------------------------------------------------------
$marca = (Get-Date).ToString('yyyyMMdd_HHmm')
try {
    if (-not (Test-Path -LiteralPath $Carpeta)) { New-Item -ItemType Directory -Path $Carpeta -Force | Out-Null }
    $informe = Join-Path $Carpeta ('Red_{0}_{1}.txt' -f $env:COMPUTERNAME, $marca)
    if ($ArchivoInforme) { $informe = $ArchivoInforme }
    Set-Content -LiteralPath $informe -Value $script:inf -Encoding UTF8
    if ($ArchivoCambios) {
        $lista = @($script:cambios | ForEach-Object { [pscustomobject]@{ Nombre = [string]$_.Nombre; Efecto = [string]$_.Efecto; Cmds = @($_.Cmds) } })
        [System.IO.File]::WriteAllText($ArchivoCambios, (ConvertTo-Json -InputObject $lista -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    }
    Linea ''
    Linea ('Informe guardado en: ' + $informe) 'Gray'
    if ($revertir.Count -gt 0) {
        $rev = Join-Path $Carpeta ('Revertir_Red_{0}_{1}.cmd' -f $env:COMPUTERNAME, $marca)
        $contenido = @('@echo off', 'rem Revierte los cambios aplicados por OptimizarRed. Ejecutar como administrador.') + $revertir + @('echo Listo.', 'pause')
        Set-Content -LiteralPath $rev -Value $contenido -Encoding ASCII
        Linea ('Para deshacer los cambios (como administrador): ' + $rev) 'Gray'
    }
}
catch { Linea ('No se pudo guardar el informe: ' + $_.Exception.Message) 'Red' }
Linea ''
if (-not $SinPausa) { [void](Read-Host 'Pulsa Enter para cerrar') }
