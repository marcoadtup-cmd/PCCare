#Requires -Version 5.1
<#
.SYNOPSIS
    PC Care: limpieza, optimizacion, actualizaciones, red, diagnostico y monitoreo para Windows 11.
    Todo se ejecuta desde esta ventana. Las tareas quedan en una cola que se guarda en disco.

.DESCRIPTION
    Principios de seguridad:
      - Arranca en MODO SIMULACION: muestra lo que haria sin modificar nada, hasta que el usuario lo desactive.
      - La limpieza de basura solo borra dentro de una lista cerrada de carpetas temporales y de cache.
      - Nunca sigue accesos directos de carpeta (junctions) ni toca Windows, Program Files, ProgramData o AppData
        al buscar archivos grandes y duplicados; esos archivos van a la Papelera, no se borran.
      - El registro solo admite tres tipos de entrada comprobada y exporta un respaldo .reg antes de borrar.
      - Los programas de inicio se desactivan igual que el Administrador de tareas: no se elimina nada.
      - TurboPC no cierra nada por su cuenta: solo cierra los procesos que el usuario marque.
      - Si PC Care se cierra a mitad de una tarea, al abrirlo se ofrece reanudarla. Solo se reanuda sin riesgo lo
        que es repetible; lo que pudo quedar a medias (instalaciones, registro, TurboPC) exige decision del usuario.
      - Una tarea guardada en simulacion nunca se repite en modo real.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\PCCare.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\PCCare.ps1 -AutoPrueba
    Ejecuta todos los analisis en solo lectura y escribe PCCare_autoprueba_<EQUIPO>.log junto al script.

.NOTES
    Requiere administrador (se eleva solo). Licencia MIT.
#>
[CmdletBinding()]
param(
    [switch]$AutoPrueba,
    [switch]$Completa,
    [string]$CarpetaDatos = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PCCare')
)

$ErrorActionPreference = 'Stop'
$VersionApp = '2.0.3'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) {
    try {
        $argumentos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
        if ($AutoPrueba) { $argumentos += '-AutoPrueba' }
        if ($Completa) { $argumentos += '-Completa' }
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argumentos
    }
    catch { [void][System.Windows.MessageBox]::Show('PC Care necesita permisos de administrador.', 'PC Care') }
    exit
}

# ===========================================================================
# MOTOR: funciones compartidas por todas las tareas en segundo plano
# ===========================================================================
$ayuda = {
    function Format-Tamano {
        param([double]$Bytes)
        if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
        if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
        if ($Bytes -gt 0) { return ('{0:N0} KB' -f [math]::Ceiling($Bytes / 1KB)) }
        return '0'
    }

    # --- Guardas de seguridad ------------------------------------------------
    function Test-RutaPermitida {
        # Verdadero solo si la ruta esta estrictamente DENTRO de una de las raices de la lista cerrada.
        param([string]$Ruta, [string[]]$Raices)
        try { $completa = [System.IO.Path]::GetFullPath($Ruta) } catch { return $false }
        foreach ($r in $Raices) {
            if (-not $r) { continue }
            try { $raiz = [System.IO.Path]::GetFullPath($r).TrimEnd('\') + '\' } catch { continue }
            if ($raiz.Length -lt 12) { continue }   # jamas una raiz tan corta como C:\ o C:\Users\
            if ($completa.Length -gt $raiz.Length -and $completa.StartsWith($raiz, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    }

    function Get-RaicesUsuario {
        # Carpetas de primer nivel de la unidad del sistema donde vive informacion del usuario.
        $prohibidas = @('Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', '$Recycle.Bin', 'System Volume Information',
            'Recovery', 'PerfLogs', 'Documents and Settings', 'MSOCache', 'Config.Msi', '$WinREAgent', '$Windows.~BT', '$Windows.~WS',
            'Windows.old', '$SysReset', 'OneDriveTemp', 'Intel', 'AMD', 'NVIDIA', 'Drivers', 'eSupport', 'inetpub')
        $oculto = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
        $salida = @()
        try {
            foreach ($d in (New-Object System.IO.DirectoryInfo ($env:SystemDrive + '\')).GetDirectories()) {
                if ($prohibidas -contains $d.Name) { continue }
                if ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                if (($d.Attributes -band $oculto) -eq $oculto) { continue }
                $salida += $d.FullName
            }
        }
        catch { }
        return $salida
    }

    function Test-ArchivoUsuarioSeguro {
        # Un archivo solo puede ir a la Papelera si esta en carpetas de usuario y fuera de AppData.
        param([string]$Ruta, [string[]]$Raices)
        try { $completa = [System.IO.Path]::GetFullPath($Ruta) } catch { return $false }
        $dentro = $false
        foreach ($r in $Raices) {
            if ($r -and $completa.StartsWith($r.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $dentro = $true; break }
        }
        if (-not $dentro) { return $false }
        if ($completa -match '\\AppData\\') { return $false }
        foreach ($p in @($env:windir, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
            if ($p -and $completa.StartsWith($p.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        return $true
    }

    function Get-ArchivosSeguros {
        # Recorre una carpeta sin seguir junctions ni enlaces. Las carpetas sin permiso se omiten.
        param([string]$Raiz, [string[]]$ExcluirNombres = @(), [long]$MinBytes = 0)
        $pila = New-Object System.Collections.Stack
        $pila.Push($Raiz)
        while ($pila.Count -gt 0) {
            $dir = [string]$pila.Pop()
            try {
                $info = New-Object System.IO.DirectoryInfo $dir
                foreach ($f in $info.GetFiles()) { if ($f.Length -ge $MinBytes) { $f } }
                foreach ($d in $info.GetDirectories()) {
                    if ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                    if ($ExcluirNombres -contains $d.Name) { continue }
                    $pila.Push($d.FullName)
                }
            }
            catch { }
        }
    }

    function Get-RaicesNube {
        # Carpetas sincronizadas con OneDrive o SharePoint: borrar ahi tambien borra en la nube.
        $r = @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer)
        try {
            foreach ($k in (Get-ChildItem -Path 'HKCU:\Software\Microsoft\OneDrive\Accounts' -ErrorAction Stop)) {
                $t = Join-Path $k.PSPath 'Tenants'
                if (Test-Path $t) {
                    foreach ($s in (Get-ChildItem -Path $t -ErrorAction SilentlyContinue)) {
                        foreach ($n in $s.GetValueNames()) { if ($n -match '^[A-Za-z]:\\') { $r += $n } }
                    }
                }
            }
        }
        catch { }
        return @($r | Where-Object { $_ } | Sort-Object -Unique)
    }

    function Test-EnNube {
        param([string]$Ruta, [string[]]$RaicesNube)
        foreach ($n in $RaicesNube) {
            if ($Ruta.StartsWith($n.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    }

    # --- Basura --------------------------------------------------------------
    function Get-CategoriasBasura {
        $local = $env:LOCALAPPDATA
        $win = $env:windir
        $navegadores = @()
        foreach ($base in @("$local\Microsoft\Edge\User Data", "$local\Google\Chrome\User Data", "$local\BraveSoftware\Brave-Browser\User Data")) {
            if (-not (Test-Path -LiteralPath $base)) { continue }
            foreach ($perfil in (Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
                foreach ($sub in @('Cache\Cache_Data', 'Code Cache', 'GPUCache')) { $navegadores += (Join-Path $perfil.FullName $sub) }
            }
        }
        $ff = "$local\Mozilla\Firefox\Profiles"
        if (Test-Path -LiteralPath $ff) {
            foreach ($perfil in (Get-ChildItem -LiteralPath $ff -Directory -ErrorAction SilentlyContinue)) { $navegadores += (Join-Path $perfil.FullName 'cache2') }
        }
        $tempUsuario = @()
        if ($env:TEMP -and $env:TEMP -match '\\Temp') { $tempUsuario = @($env:TEMP) }
        $lista = @(
            @{ Id = 'TempUsuario'; Nombre = 'Temporales del usuario'; Rutas = $tempUsuario; Horas = 24 },
            @{ Id = 'TempWindows'; Nombre = 'Temporales de Windows'; Rutas = @("$win\Temp"); Horas = 24 },
            @{ Id = 'WUCache'; Nombre = 'Caché de descargas de Windows Update'; Rutas = @("$win\SoftwareDistribution\Download"); Horas = 0 },
            @{ Id = 'Navegadores'; Nombre = 'Caché de navegadores (Edge, Chrome, Brave, Firefox)'; Rutas = $navegadores; Horas = 0 },
            @{ Id = 'Errores'; Nombre = 'Informes y volcados de error'; Rutas = @("$local\CrashDumps", "$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue", "$win\Minidump"); Horas = 0 },
            @{ Id = 'Papelera'; Nombre = 'Papelera de reciclaje'; Rutas = @(); Horas = 0 }
        )
        foreach ($c in $lista) { $c.Rutas = @($c.Rutas | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) }
        return $lista
    }

    function Get-ArchivosCategoria {
        param([hashtable]$Categoria)
        $limite = (Get-Date).AddHours(-1 * [int]$Categoria.Horas)
        foreach ($raiz in $Categoria.Rutas) {
            foreach ($f in (Get-ArchivosSeguros -Raiz $raiz)) {
                if ($Categoria.Horas -gt 0 -and $f.LastWriteTime -gt $limite) { continue }
                if (Test-RutaPermitida $f.FullName $Categoria.Rutas) { $f }
            }
        }
    }

    function Get-TamanoPapelera {
        $bytes = 0; $n = 0
        try {
            $shell = New-Object -ComObject Shell.Application
            foreach ($i in $shell.Namespace(10).Items()) { $bytes += [double]$i.Size; $n++ }
        }
        catch { }
        return @{ Bytes = $bytes; Archivos = $n }
    }

    # --- Registro ------------------------------------------------------------
    function Get-RutaDeComando {
        # Extrae la ruta absoluta del ejecutable de una linea de comando. Si no es clara, devuelve $null (no se toca).
        param([string]$Comando)
        if (-not $Comando) { return $null }
        $c = [Environment]::ExpandEnvironmentVariables($Comando.Trim())
        $p = $null
        if ($c -match '^"([^"]+)"') { $p = $Matches[1] }
        elseif ($c -match '^(.+?\.(exe|com|bat|cmd|msi))(\s|,|$)') { $p = $Matches[1] }
        if (-not $p -or $p -notmatch '^[A-Za-z]:\\') { return $null }
        return $p
    }

    function Test-FaltaEnDiscoFijo {
        # Verdadero solo si la unidad existe, es un disco fijo y la ruta NO existe.
        param([string]$Ruta)
        if (-not $Ruta -or $Ruta -notmatch '^[A-Za-z]:\\') { return $false }
        try {
            $unidad = New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($Ruta))
            if (-not $unidad.IsReady -or $unidad.DriveType -ne [System.IO.DriveType]::Fixed) { return $false }
        }
        catch { return $false }
        return -not (Test-Path -LiteralPath $Ruta)
    }

    $script:ClavesRun = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )
    $script:ClavesDesinstalar = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $script:ClaveAppPaths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths'

    function Test-ClaveRegistroPermitida {
        param([string]$Tipo, [string]$RutaPS)
        switch ($Tipo) {
            'Inicio' { return ($script:ClavesRun -contains $RutaPS) }
            'Ruta de aplicación' { return $RutaPS.StartsWith($script:ClaveAppPaths + '\', [System.StringComparison]::OrdinalIgnoreCase) }
            'Desinstalador huérfano' {
                foreach ($c in $script:ClavesDesinstalar) { if ($RutaPS.StartsWith($c + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true } }
                return $false
            }
        }
        return $false
    }

    # --- Monitoreo -----------------------------------------------------------
    function Get-BytesRed {
        $rx = [double]0; $tx = [double]0
        foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($n.OperationalStatus -ne 'Up' -or $n.NetworkInterfaceType -eq 'Loopback' -or $n.NetworkInterfaceType -eq 'Tunnel') { continue }
            try { $s = $n.GetIPStatistics(); $rx += $s.BytesReceived; $tx += $s.BytesSent } catch { }
        }
        return @{ Rx = $rx; Tx = $tx }
    }

    function Get-UsoCpuRam {
        $cpu = 0
        try { $cpu = [int](Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime } catch { }
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $total = [double]$os.TotalVisibleMemorySize * 1KB
        $libre = [double]$os.FreePhysicalMemory * 1KB
        return @{ Cpu = $cpu; RamTotal = $total; RamLibre = $libre; RamPct = [int][math]::Round((1 - $libre / $total) * 100) }
    }

    function Get-TemperaturaDiscos {
        $salida = @()
        try {
            foreach ($d in (Get-PhysicalDisk -ErrorAction Stop)) {
                $temp = $null; $desgaste = $null; $horas = $null
                try {
                    $r = $d | Get-StorageReliabilityCounter -ErrorAction Stop
                    if ($r.Temperature -gt 0) { $temp = [int]$r.Temperature }
                    if ($null -ne $r.Wear) { $desgaste = [int]$r.Wear }
                    if ($null -ne $r.PowerOnHours) { $horas = [int64]$r.PowerOnHours }
                }
                catch { }
                $salida += [pscustomobject]@{
                    Disco = [string]$d.FriendlyName; Tipo = [string]$d.MediaType; Salud = [string]$d.HealthStatus
                    Temp = $temp; Desgaste = $desgaste; Horas = $horas; TamanoGB = [int][math]::Round($d.Size / 1GB)
                }
            }
        }
        catch { }
        return $salida
    }

    function Get-ConexionesPorProceso {
        $salida = @()
        try {
            $con = @(Get-NetTCPConnection -State Established -ErrorAction Stop | Where-Object { $_.RemoteAddress -notmatch '^(127\.|::1$)' })
            foreach ($g in ($con | Group-Object OwningProcess)) {
                $nombre = 'PID ' + $g.Name
                try { $nombre = (Get-Process -Id ([int]$g.Name) -ErrorAction Stop).ProcessName } catch { }
                $salida += [pscustomobject]@{
                    Proceso = $nombre; Conexiones = $g.Count
                    Destinos = @($g.Group | ForEach-Object { $_.RemoteAddress } | Sort-Object -Unique).Count
                }
            }
        }
        catch { }
        # Suma las instancias de un mismo programa
        return @($salida | Group-Object Proceso | ForEach-Object {
                [pscustomobject]@{
                    Proceso = $_.Name
                    Conexiones = [int]($_.Group | Measure-Object Conexiones -Sum).Sum
                    Destinos = [int]($_.Group | Measure-Object Destinos -Sum).Sum
                }
            } | Sort-Object Conexiones -Descending)
    }

    $script:ProcesosCriticos = @('System', 'Idle', 'Registry', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'svchost', 'fontdrvhost',
        'dwm', 'explorer', 'sihost', 'ctfmon', 'taskhostw', 'RuntimeBroker', 'ShellExperienceHost', 'StartMenuExperienceHost', 'SearchHost',
        'MsMpEng', 'NisSrv', 'SecurityHealthService', 'SecurityHealthSystray', 'audiodg', 'spoolsv', 'conhost', 'dllhost', 'WmiPrvSE',
        'powershell', 'pwsh', 'WindowsTerminal', 'OpenConsole', 'Memory Compression', 'LsaIso', 'TextInputHost', 'ApplicationFrameHost', 'SystemSettings')
}

# ===========================================================================
# MOTOR: tareas
# ===========================================================================
$sbAnalizarBasura = {
    param([string]$Ayuda)
    . ([scriptblock]::Create($Ayuda))
    foreach ($c in (Get-CategoriasBasura)) {
        if ($c.Id -eq 'Papelera') { $p = Get-TamanoPapelera; $bytes = $p.Bytes; $n = $p.Archivos }
        else {
            $bytes = [double]0; $n = 0
            foreach ($f in (Get-ArchivosCategoria $c)) { $bytes += $f.Length; $n++ }
        }
        [pscustomobject]@{ Id = $c.Id; Nombre = $c.Nombre; Bytes = $bytes; Archivos = $n }
    }
}

$sbLimpiarBasura = {
    param([string]$Ayuda, [string[]]$Ids, [bool]$Simular)
    . ([scriptblock]::Create($Ayuda))
    $mensajes = New-Object System.Collections.Generic.List[string]
    $total = [double]0
    foreach ($c in (Get-CategoriasBasura)) {
        if ($Ids -notcontains $c.Id) { continue }
        $liberado = [double]0; $borrados = 0; $omitidos = 0
        if ($c.Id -eq 'Papelera') {
            $p = Get-TamanoPapelera
            if (-not $Simular) { try { Clear-RecycleBin -Force -ErrorAction Stop } catch { } }
            $liberado = $p.Bytes; $borrados = $p.Archivos
        }
        else {
            $detenidos = @()
            if ($c.Id -eq 'WUCache' -and -not $Simular) {
                foreach ($s in @('wuauserv', 'bits')) {
                    try {
                        $svc = Get-Service -Name $s -ErrorAction Stop
                        if ($svc.Status -eq 'Running') { Stop-Service -Name $s -Force -ErrorAction Stop; $detenidos += $s }
                    }
                    catch { }
                }
            }
            try {
                foreach ($f in (Get-ArchivosCategoria $c)) {
                    if ($Simular) { $liberado += $f.Length; $borrados++; continue }
                    try { $t = $f.Length; [System.IO.File]::Delete($f.FullName); $liberado += $t; $borrados++ } catch { $omitidos++ }
                }
            }
            finally {
                foreach ($s in $detenidos) { try { Start-Service -Name $s -ErrorAction Stop } catch { } }
            }
        }
        $total += $liberado
        $mensajes.Add(('{0}: {1} en {2} archivos; {3} en uso, omitidos.' -f $c.Nombre, (Format-Tamano $liberado), $borrados, $omitidos))
    }
    [pscustomobject]@{ Mensajes = $mensajes.ToArray(); Bytes = $total; Simulado = $Simular }
}

$sbGrandes = {
    param([string]$Ayuda, [int]$MinMB)
    . ([scriptblock]::Create($Ayuda))
    $nube = Get-RaicesNube
    $soloNube = 0x00441000   # Offline, RecallOnOpen, RecallOnDataAccess: el archivo no ocupa disco local
    $lista = foreach ($raiz in (Get-RaicesUsuario)) {
        foreach ($f in (Get-ArchivosSeguros -Raiz $raiz -ExcluirNombres @('AppData') -MinBytes ([long]$MinMB * 1MB))) {
            if (([int]$f.Attributes -band $soloNube) -ne 0) { continue }
            [pscustomobject]@{
                Grupo = ''; Ruta = $f.FullName; Nombre = $f.Name; Carpeta = $f.DirectoryName; Bytes = [long]$f.Length
                Modificado = $f.LastWriteTime.ToString('yyyy-MM-dd'); Nube = $(if (Test-EnNube $f.FullName $nube) { 'Sincronizado' } else { '' })
            }
        }
    }
    @($lista | Sort-Object Bytes -Descending | Select-Object -First 300)
}

$sbDuplicados = {
    param([string]$Ayuda, [int]$MinMB)
    . ([scriptblock]::Create($Ayuda))
    function Get-HashArchivo {
        param([string]$Ruta, [int]$MaxBytes = 0)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $fs = $null
        try {
            $fs = New-Object System.IO.FileStream($Ruta, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            if ($MaxBytes -gt 0) {
                $buf = New-Object byte[] ([int][math]::Min([long]$MaxBytes, $fs.Length))
                $n = $fs.Read($buf, 0, $buf.Length)
                return [System.BitConverter]::ToString($sha.ComputeHash($buf, 0, $n))
            }
            return [System.BitConverter]::ToString($sha.ComputeHash($fs))
        }
        catch { return $null }
        finally { if ($fs) { $fs.Dispose() }; $sha.Dispose() }
    }
    $nube = Get-RaicesNube
    $soloNube = 0x00441000
    $todos = foreach ($raiz in (Get-RaicesUsuario)) {
        foreach ($f in (Get-ArchivosSeguros -Raiz $raiz -ExcluirNombres @('AppData') -MinBytes ([long]$MinMB * 1MB))) {
            if (([int]$f.Attributes -band $soloNube) -eq 0) { $f }
        }
    }
    $grupo = 0
    $salida = New-Object System.Collections.Generic.List[object]
    foreach ($porTamano in (@($todos) | Group-Object Length | Where-Object { $_.Count -gt 1 })) {
        # 1) mismo tamano  2) mismo inicio (256 KB)  3) mismo contenido completo
        $parciales = $porTamano.Group | ForEach-Object { [pscustomobject]@{ F = $_; H = (Get-HashArchivo $_.FullName 262144) } } | Where-Object { $_.H }
        foreach ($porInicio in (@($parciales) | Group-Object H | Where-Object { $_.Count -gt 1 })) {
            $completos = $porInicio.Group | ForEach-Object { [pscustomobject]@{ F = $_.F; H = (Get-HashArchivo $_.F.FullName) } } | Where-Object { $_.H }
            foreach ($iguales in (@($completos) | Group-Object H | Where-Object { $_.Count -gt 1 })) {
                $grupo++
                foreach ($x in ($iguales.Group | Sort-Object { $_.F.LastWriteTime } -Descending)) {
                    $f = $x.F
                    $salida.Add([pscustomobject]@{
                            Grupo = [string]$grupo; Ruta = $f.FullName; Nombre = $f.Name; Carpeta = $f.DirectoryName; Bytes = [long]$f.Length
                            Modificado = $f.LastWriteTime.ToString('yyyy-MM-dd'); Nube = $(if (Test-EnNube $f.FullName $nube) { 'Sincronizado' } else { '' })
                        })
                }
            }
        }
    }
    $salida.ToArray()
}

$sbPapelera = {
    param([string]$Ayuda, [string[]]$Rutas, [bool]$Simular)
    . ([scriptblock]::Create($Ayuda))
    Add-Type -AssemblyName Microsoft.VisualBasic
    $raices = Get-RaicesUsuario
    $hechos = New-Object System.Collections.Generic.List[string]
    $mensajes = New-Object System.Collections.Generic.List[string]
    $bytes = [double]0
    foreach ($r in $Rutas) {
        if (-not (Test-ArchivoUsuarioSeguro $r $raices)) { $mensajes.Add('BLOQUEADO por seguridad (fuera de carpetas de usuario): ' + $r); continue }
        if (-not (Test-Path -LiteralPath $r -PathType Leaf)) { $mensajes.Add('Ya no existe: ' + $r); continue }
        try {
            $t = (Get-Item -LiteralPath $r -Force).Length
            if (-not $Simular) {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($r, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
            }
            $bytes += $t
            $hechos.Add($r)
        }
        catch { $mensajes.Add(('No se pudo mover {0}: {1}' -f $r, $_.Exception.Message)) }
    }
    $mensajes.Add(('{0} archivos a la Papelera, {1}.' -f $hechos.Count, (Format-Tamano $bytes)))
    [pscustomobject]@{ Mensajes = $mensajes.ToArray(); Hechos = $hechos.ToArray(); Bytes = $bytes; Simulado = $Simular }
}

$sbAnalizarRegistro = {
    param([string]$Ayuda)
    . ([scriptblock]::Create($Ayuda))
    foreach ($clave in $script:ClavesRun) {
        if (-not (Test-Path $clave)) { continue }
        $k = Get-Item -Path $clave
        foreach ($n in $k.GetValueNames()) {
            if (-not $n) { continue }
            $ruta = Get-RutaDeComando ([string]$k.GetValue($n))
            if (Test-FaltaEnDiscoFijo $ruta) {
                [pscustomobject]@{ Tipo = 'Inicio'; RutaPS = $clave; Valor = $n; Detalle = 'No existe: ' + $ruta }
            }
        }
    }
    if (Test-Path $script:ClaveAppPaths) {
        foreach ($k in (Get-ChildItem -Path $script:ClaveAppPaths -ErrorAction SilentlyContinue)) {
            $ruta = Get-RutaDeComando ([string]$k.GetValue(''))
            if (-not $ruta) { $crudo = [Environment]::ExpandEnvironmentVariables(([string]$k.GetValue('')).Trim('"', ' ')); if ($crudo -match '^[A-Za-z]:\\') { $ruta = $crudo } }
            if (Test-FaltaEnDiscoFijo $ruta) {
                [pscustomobject]@{ Tipo = 'Ruta de aplicación'; RutaPS = ($script:ClaveAppPaths + '\' + $k.PSChildName); Valor = ''; Detalle = 'No existe: ' + $ruta }
            }
        }
    }
    foreach ($raiz in $script:ClavesDesinstalar) {
        if (-not (Test-Path $raiz)) { continue }
        foreach ($k in (Get-ChildItem -Path $raiz -ErrorAction SilentlyContinue)) {
            try {
                if ($k.GetValue('SystemComponent') -eq 1 -or -not $k.GetValue('DisplayName')) { continue }
                $carpeta = [Environment]::ExpandEnvironmentVariables(([string]$k.GetValue('InstallLocation')).Trim('"', ' '))
                $desinst = Get-RutaDeComando ([string]$k.GetValue('UninstallString'))
                # Huerfano solo si faltan AMBOS: la carpeta de instalacion y el desinstalador
                if ((Test-FaltaEnDiscoFijo $carpeta) -and (Test-FaltaEnDiscoFijo $desinst)) {
                    [pscustomobject]@{ Tipo = 'Desinstalador huérfano'; RutaPS = ($raiz + '\' + $k.PSChildName); Valor = ''; Detalle = ([string]$k.GetValue('DisplayName')) + ': ya no existe ' + $carpeta }
                }
            }
            catch { }
        }
    }
}

$sbLimpiarRegistro = {
    param([string]$Ayuda, [string[]]$Items, [bool]$Punto, [string]$Carpeta, [bool]$Simular)
    . ([scriptblock]::Create($Ayuda))
    $mensajes = New-Object System.Collections.Generic.List[string]
    $hechos = New-Object System.Collections.Generic.List[string]
    $destino = Join-Path $Carpeta ('RespaldoRegistro\{0}_{1}' -f $env:COMPUTERNAME, (Get-Date).ToString('yyyyMMdd_HHmmss'))
    if (-not $Simular) {
        New-Item -ItemType Directory -Path $destino -Force | Out-Null
        if ($Punto) {
            try { Checkpoint-Computer -Description 'PC Care antes de limpiar registro' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop; $mensajes.Add('Punto de restauración solicitado.') }
            catch { $mensajes.Add('AVISO: no se pudo crear el punto de restauración: ' + $_.Exception.Message) }
        }
    }
    $n = 0
    foreach ($item in $Items) {
        $partes = $item -split '\|', 3
        $tipo = $partes[0]; $rutaPS = $partes[1]; $valor = $partes[2]
        if (-not (Test-ClaveRegistroPermitida $tipo $rutaPS)) { $mensajes.Add('BLOQUEADO por seguridad: ' + $rutaPS); continue }
        if (-not (Test-Path -LiteralPath $rutaPS)) { $mensajes.Add('Ya no existe: ' + $rutaPS); continue }
        if ($Simular) { $hechos.Add($item); $mensajes.Add(('Se eliminaría [{0}] {1} {2}' -f $tipo, $rutaPS, $valor)); continue }
        $n++
        $rutaReg = $rutaPS -replace '^HKLM:\\', 'HKLM\' -replace '^HKCU:\\', 'HKCU\'
        $archivo = Join-Path $destino ('{0:D3}.reg' -f $n)
        $salida = & reg.exe export $rutaReg $archivo /y 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $archivo)) { $mensajes.Add('Sin respaldo, no se toca: ' + $rutaPS); continue }
        try {
            if ($tipo -eq 'Inicio') { Remove-ItemProperty -LiteralPath $rutaPS -Name $valor -ErrorAction Stop }
            else { Remove-Item -LiteralPath $rutaPS -Recurse -Force -ErrorAction Stop }
            $hechos.Add($item)
            $mensajes.Add(('Eliminado [{0}] {1} {2} (respaldo {3})' -f $tipo, $rutaPS, $valor, $archivo))
        }
        catch { $mensajes.Add(('No se pudo eliminar {0}: {1}' -f $rutaPS, $_.Exception.Message)) }
    }
    if (-not $Simular -and $hechos.Count -gt 0) { $mensajes.Add('Para deshacer: doble clic en los .reg de ' + $destino) }
    [pscustomobject]@{ Mensajes = $mensajes.ToArray(); Hechos = $hechos.ToArray(); Simulado = $Simular }
}

$sbInicio = {
    param([string]$Ayuda)
    . ([scriptblock]::Create($Ayuda))
    function Test-Activo {
        param([string]$ClaveAprobado, [string]$Nombre)
        try {
            $b = (Get-ItemProperty -LiteralPath $ClaveAprobado -Name $Nombre -ErrorAction Stop).$Nombre
            if ($b -is [byte[]] -and $b.Length -gt 0) { return (($b[0] -band 1) -eq 0) }
        }
        catch { }
        return $true
    }
    $base = '\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\'
    $mapa = @(
        @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Aprobado = 'HKCU:' + $base + 'Run'; Origen = 'Usuario' },
        @{ Run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Aprobado = 'HKLM:' + $base + 'Run'; Origen = 'Equipo' },
        @{ Run = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Aprobado = 'HKLM:' + $base + 'Run32'; Origen = 'Equipo (32 bits)' }
    )
    $items = @()
    foreach ($m in $mapa) {
        if (-not (Test-Path $m.Run)) { continue }
        $k = Get-Item -Path $m.Run
        foreach ($n in $k.GetValueNames()) {
            if (-not $n) { continue }
            $items += [pscustomobject]@{ Nombre = $n; Comando = [string]$k.GetValue($n); Origen = $m.Origen; Aprobado = $m.Aprobado; Activo = (Test-Activo $m.Aprobado $n) }
        }
    }
    $carpetas = @(
        @{ Ruta = [Environment]::GetFolderPath('Startup'); Aprobado = 'HKCU:' + $base + 'StartupFolder'; Origen = 'Carpeta Inicio (usuario)' },
        @{ Ruta = [Environment]::GetFolderPath('CommonStartup'); Aprobado = 'HKLM:' + $base + 'StartupFolder'; Origen = 'Carpeta Inicio (equipo)' }
    )
    foreach ($c in $carpetas) {
        if (-not $c.Ruta -or -not (Test-Path -LiteralPath $c.Ruta)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $c.Ruta -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
            $items += [pscustomobject]@{ Nombre = $f.Name; Comando = $f.FullName; Origen = $c.Origen; Aprobado = $c.Aprobado; Activo = (Test-Activo $c.Aprobado $f.Name) }
        }
    }
    $arranque = $null
    try {
        $e = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 1 -ErrorAction Stop
        $x = [xml]$e.ToXml()
        $ms = ($x.Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' }).'#text'
        if ($ms) { $arranque = [int]([double]$ms / 1000) }
    }
    catch { }
    [pscustomobject]@{ Items = $items; ArranqueSeg = $arranque }
}

$sbDiagnostico = {
    param([string]$Ayuda)
    . ([scriptblock]::Create($Ayuda))
    function Nuevo { param($Id, $Estado, $Titulo, $Detalle, $Accion = '', $Texto = '')
        [pscustomobject]@{ Id = $Id; Estado = $Estado; Titulo = $Titulo; Detalle = $Detalle; Accion = $Accion; TextoAccion = $Texto } }
    $letra = $env:SystemDrive.TrimEnd(':')

    $pend = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    if ($pend) { Nuevo 'Reinicio' 'ALERTA' 'Reinicio pendiente' 'Hay parches instalados que no aplican hasta reiniciar. Reinicia cuando puedas.' }
    else { Nuevo 'Reinicio' 'OK' 'Reinicio pendiente' 'No hay reinicios pendientes.' }

    try {
        $d = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive)
        $pct = [int][math]::Round($d.FreeSpace / $d.Size * 100)
        $txt = '{0}% libre ({1} de {2}).' -f $pct, (Format-Tamano $d.FreeSpace), (Format-Tamano $d.Size)
        if ($pct -lt 10) { Nuevo 'Espacio' 'CRITICO' ('Espacio en ' + $env:SystemDrive) ($txt + ' Windows Update puede fallar. Usa Limpieza.') }
        elseif ($pct -lt 20) { Nuevo 'Espacio' 'ALERTA' ('Espacio en ' + $env:SystemDrive) ($txt + ' Conviene liberar espacio en Limpieza.') }
        else { Nuevo 'Espacio' 'OK' ('Espacio en ' + $env:SystemDrive) $txt }
    }
    catch { }

    $esSSD = $false
    foreach ($disco in (Get-TemperaturaDiscos)) {
        if ($disco.Tipo -eq 'SSD') { $esSSD = $true }
        if ($disco.Salud -and $disco.Salud -ne 'Healthy') { Nuevo 'Salud' 'CRITICO' ('Salud del disco ' + $disco.Disco) ('Estado: {0}. Respalda la información y reemplaza el disco.' -f $disco.Salud) }
        else { Nuevo 'Salud' 'OK' ('Salud del disco ' + $disco.Disco) ('{0}, {1} GB, estado correcto.' -f $disco.Tipo, $disco.TamanoGB) }
    }
    if ($esSSD) { Nuevo 'Optimizar' 'INFO' ('Optimización de ' + $env:SystemDrive) 'Unidad SSD: se optimiza con TRIM. No se desfragmenta.' 'Optimizar' 'Optimizar ahora' }
    else { Nuevo 'Optimizar' 'INFO' ('Optimización de ' + $env:SystemDrive) 'Windows elige el método según el tipo de disco (desfragmentar en discos mecánicos).' 'Optimizar' 'Optimizar ahora' }

    try {
        $img = Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop
        if ([string]$img.ImageHealthState -eq 'Healthy') { Nuevo 'Sistema' 'OK' 'Archivos de sistema' 'El almacén de componentes de Windows no reporta daños.' }
        else { Nuevo 'Sistema' 'CRITICO' 'Archivos de sistema' ('Estado: {0}. Se repara con DISM y SFC (tarda 15 a 40 minutos).' -f $img.ImageHealthState) 'Reparar' 'Reparar' }
    }
    catch { Nuevo 'Sistema' 'INFO' 'Archivos de sistema' 'No se pudo consultar el estado con DISM.' }

    try {
        $wu = Get-CimInstance -ClassName Win32_Service -Filter "Name='wuauserv'"
        if ($wu.StartMode -eq 'Disabled') { Nuevo 'WU' 'CRITICO' 'Servicio de Windows Update' 'Está deshabilitado: el equipo no recibe parches.' 'WU' 'Habilitar' }
        else { Nuevo 'WU' 'OK' 'Servicio de Windows Update' 'Habilitado.' }
    }
    catch { }

    $u = Get-UsoCpuRam
    if ($u.RamPct -ge 85) { Nuevo 'Memoria' 'ALERTA' 'Uso de memoria' ('{0}% en uso. Activa TurboPC o cierra lo que no uses.' -f $u.RamPct) }
    else { Nuevo 'Memoria' 'OK' 'Uso de memoria' ('{0}% en uso de {1}.' -f $u.RamPct, (Format-Tamano $u.RamTotal)) }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $dias = [int]((Get-Date) - $os.LastBootUpTime).TotalDays
    if ($dias -gt 14) { Nuevo 'Encendido' 'ALERTA' 'Tiempo sin reiniciar' ('{0} días. Reiniciar libera memoria y aplica parches.' -f $dias) }
    else { Nuevo 'Encendido' 'OK' 'Tiempo sin reiniciar' ('{0} días.' -f $dias) }

    Nuevo 'DNS' 'INFO' 'Caché DNS' 'Vaciarla resuelve páginas que no cargan tras un cambio de red.' 'DNS' 'Vaciar caché'
}

$sbAccionDiag = {
    param([string]$Ayuda, [string]$Id, [bool]$Simular)
    . ([scriptblock]::Create($Ayuda))
    $letra = $env:SystemDrive.TrimEnd(':')
    if ($Simular) { return ('SIMULACIÓN: se ejecutaría la acción "{0}".' -f $Id) }
    switch ($Id) {
        'Optimizar' { Optimize-Volume -DriveLetter $letra -ErrorAction Stop; return ('Unidad {0}: optimizada.' -f $letra) }
        'DNS' { Clear-DnsClientCache -ErrorAction Stop; return 'Caché DNS vaciada.' }
        'WU' { Set-Service -Name wuauserv -StartupType Manual -ErrorAction Stop; return 'Windows Update habilitado (inicio manual).' }
        'Reparar' {
            $a = & dism.exe /Online /Cleanup-Image /RestoreHealth 2>&1 | Select-Object -Last 4
            $codigoDism = $LASTEXITCODE
            $b = & sfc.exe /scannow 2>&1 | Select-Object -Last 4
            return ('DISM terminó con código {0}; SFC con código {1}. Detalle en C:\Windows\Logs\CBS\CBS.log' -f $codigoDism, $LASTEXITCODE)
        }
    }
    return 'Acción no reconocida.'
}

$sbProcesos = {
    param([string]$Ayuda)
    . ([scriptblock]::Create($Ayuda))
    $sesion = (Get-Process -Id $PID).SessionId
    Get-Process | Where-Object { $_.SessionId -eq $sesion -and $script:ProcesosCriticos -notcontains $_.ProcessName } |
        Group-Object ProcessName | ForEach-Object {
            $mb = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB)
            $ventana = @($_.Group | Where-Object { $_.MainWindowHandle -ne 0 }).Count -gt 0
            [pscustomobject]@{ Proceso = $_.Name; Instancias = $_.Count; MemoriaMB = [int]$mb; Ventana = $(if ($ventana) { 'Con ventana abierta' } else { 'Segundo plano' }) }
        } | Where-Object { $_.MemoriaMB -ge 100 } | Sort-Object MemoriaMB -Descending
}

$sbTurbo = {
    param([string]$Ayuda, [bool]$Activar, [string]$PlanPrevio, [string[]]$Nombres, [bool]$Simular)
    . ([scriptblock]::Create($Ayuda))
    $mensajes = New-Object System.Collections.Generic.List[string]
    $plan = ''
    if (-not $Activar) {
        if ($PlanPrevio -and -not $Simular) { & powercfg.exe /setactive $PlanPrevio 2>&1 | Out-Null }
        $mensajes.Add('TurboPC desactivado: plan de energía anterior restaurado.')
        return [pscustomobject]@{ Mensajes = $mensajes.ToArray(); PlanPrevio = ''; LiberadoBytes = 0 }
    }
    $actual = (& powercfg.exe /getactivescheme 2>&1) -join ' '
    if ($actual -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $plan = $Matches[1] }
    if ($Simular) {
        $mensajes.Add(('SIMULACIÓN: plan de energía a alto rendimiento, liberar memoria de trabajo y cerrar: {0}' -f ($(if ($Nombres) { $Nombres -join ', ' } else { 'nada' }))))
        return [pscustomobject]@{ Mensajes = $mensajes.ToArray(); PlanPrevio = $plan; LiberadoBytes = 0 }
    }
    $antes = (Get-UsoCpuRam).RamLibre
    & powercfg.exe /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $mensajes.Add('Plan de energía: alto rendimiento.') }
    else { $mensajes.Add('Este equipo no ofrece el plan de alto rendimiento; se mantiene el plan actual.'); $plan = '' }

    $sesion = (Get-Process -Id $PID).SessionId
    $cerrados = 0
    foreach ($nombre in $Nombres) {
        if ($script:ProcesosCriticos -contains $nombre) { $mensajes.Add('BLOQUEADO por seguridad: ' + $nombre); continue }
        foreach ($p in (Get-Process -Name $nombre -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sesion })) {
            try {
                if ($p.MainWindowHandle -ne 0) { [void]$p.CloseMainWindow(); [void]$p.WaitForExit(4000) }   # cierre normal: la app puede pedir guardar
                else { Stop-Process -Id $p.Id -Force -ErrorAction Stop }
                $cerrados++
            }
            catch { }
        }
    }
    if ($Nombres) { $mensajes.Add(('Procesos a los que se pidió cerrar: {0}.' -f $cerrados)) }

    if (-not ('PCCare.Memoria' -as [type])) {
        Add-Type -Namespace PCCare -Name Memoria -MemberDefinition '[DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(System.IntPtr proceso);'
    }
    $recortados = 0
    foreach ($p in (Get-Process)) {
        if ($p.Id -eq $PID -or $p.Id -le 4) { continue }
        try { if ([PCCare.Memoria]::EmptyWorkingSet($p.Handle)) { $recortados++ } } catch { }
    }
    Start-Sleep -Milliseconds 800
    $liberado = [math]::Max(0, (Get-UsoCpuRam).RamLibre - $antes)
    $mensajes.Add(('Memoria de trabajo recortada en {0} procesos. RAM liberada: {1}.' -f $recortados, (Format-Tamano $liberado)))
    [pscustomobject]@{ Mensajes = $mensajes.ToArray(); PlanPrevio = $plan; LiberadoBytes = $liberado }
}

# Muestreo continuo para el monitor: corre en su propio hilo y deja los valores en una tabla compartida
$sbMuestreo = {
    param([string]$Ayuda, $Estado)
    . ([scriptblock]::Create($Ayuda))
    $previo = Get-BytesRed
    $reloj = [System.Diagnostics.Stopwatch]::StartNew()
    $vuelta = 0
    while ($Estado.Activo) {
        Start-Sleep -Milliseconds 1000
        try {
            $ahora = Get-BytesRed
            $seg = [math]::Max(0.2, $reloj.Elapsed.TotalSeconds)
            $reloj.Restart()
            $Estado.BajadaMbps = [math]::Max(0, ($ahora.Rx - $previo.Rx) * 8 / 1e6 / $seg)
            $Estado.SubidaMbps = [math]::Max(0, ($ahora.Tx - $previo.Tx) * 8 / 1e6 / $seg)
            $previo = $ahora
            $u = Get-UsoCpuRam
            $Estado.Cpu = $u.Cpu; $Estado.RamPct = $u.RamPct; $Estado.RamTotal = $u.RamTotal; $Estado.RamLibre = $u.RamLibre
            if ($vuelta % 10 -eq 0) { $Estado.Discos = @(Get-TemperaturaDiscos) }
            if ($vuelta % 6 -eq 0) { $Estado.Conexiones = @(Get-ConexionesPorProceso) }
            $Estado.Marca = $vuelta
        }
        catch { $Estado.Error = $_.Exception.Message }
        $vuelta++
    }
}

# ===========================================================================
# MOTOR v1.1: seguridad (solo lectura) y punto de restauracion
# ===========================================================================
$sbSeguridad = {
    param([string]$Ayuda)
    . ([scriptblock]::Create($Ayuda))
    function Fila { param($Estado, $Nombre, $Detalle) [pscustomobject]@{ Estado = $Estado; Nombre = $Nombre; Detalle = $Detalle } }

    try {
        $mp = Get-MpComputerStatus
        if ($mp.RealTimeProtectionEnabled) { Fila 'Al día' 'Microsoft Defender Antivirus' 'Protección en tiempo real activa.' }
        else { Fila 'Crítico' 'Microsoft Defender Antivirus' 'La protección en tiempo real está desactivada. Actívala en Seguridad de Windows.' }
        $edad = [int64]$mp.AntivirusSignatureAge
        if ($edad -gt 7) { Fila 'Alerta' 'Definiciones del antivirus' ('Tienen {0} días. Ejecuta Windows Update.' -f $edad) }
        else { Fila 'Al día' 'Definiciones del antivirus' ('Actualizadas hace {0} día(s).' -f $edad) }
    }
    catch { Fila 'Info' 'Microsoft Defender Antivirus' 'No se pudo leer el estado. Puede haber otro antivirus instalado y administrando la protección.' }

    try {
        $apagados = @(Get-NetFirewallProfile | Where-Object { [string]$_.Enabled -ne 'True' } | ForEach-Object { [string]$_.Name })
        if ($apagados.Count -eq 0) { Fila 'Al día' 'Firewall de Windows' 'Activo en los perfiles de dominio, privado y público.' }
        else { Fila 'Alerta' 'Firewall de Windows' ('Desactivado en: ' + ($apagados -join ', ')) }
    }
    catch { Fila 'Info' 'Firewall de Windows' 'No se pudo leer el estado.' }

    try {
        $pref = Get-MpPreference
        if ([int]$pref.EnableControlledFolderAccess -eq 0) { Fila 'Info' 'Acceso controlado a carpetas' 'No configurado. Es opcional: protege tus carpetas personales contra ransomware.' }
        else { Fila 'Al día' 'Acceso controlado a carpetas' 'Activo.' }
    }
    catch { }

    try {
        $v = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections).fDenyTSConnections
        if ([int]$v -eq 0) { Fila 'Alerta' 'Escritorio remoto (RDP)' 'Está habilitado. Si no lo usas, desactívalo; si lo usas, que no quede expuesto a internet.' }
        else { Fila 'Al día' 'Escritorio remoto (RDP)' 'Deshabilitado.' }
    }
    catch { }

    try {
        $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive
        if ([string]$bl.ProtectionStatus -eq 'On') { Fila 'Al día' ('Cifrado BitLocker en ' + $env:SystemDrive) 'Activo.' }
        else { Fila 'Alerta' ('Cifrado BitLocker en ' + $env:SystemDrive) 'El disco del sistema no está cifrado. Si el equipo se pierde, los datos quedan legibles.' }
    }
    catch { Fila 'Info' 'Cifrado BitLocker' 'No disponible en esta edición de Windows o sin permisos para leerlo.' }

    try {
        $smb = Get-SmbServerConfiguration
        if ($smb.EnableSMB1Protocol) { Fila 'Alerta' 'Protocolo SMB 1' 'Está habilitado. Es obsoleto e inseguro; conviene desactivarlo.' }
        else { Fila 'Al día' 'Protocolo SMB 1' 'Deshabilitado.' }
    }
    catch { }

    try {
        $uac = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA).EnableLUA
        if ([int]$uac -eq 1) { Fila 'Al día' 'Control de cuentas de usuario (UAC)' 'Activo.' }
        else { Fila 'Crítico' 'Control de cuentas de usuario (UAC)' 'Está desactivado. Actívalo en Configuración de Windows.' }
    }
    catch { }

    try {
        $esc = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalAddress -notmatch '^(127\.|::1)' })
        $procs = @($esc | ForEach-Object { try { (Get-Process -Id $_.OwningProcess -ErrorAction Stop).ProcessName } catch { 'sistema' } } | Group-Object | Sort-Object Count -Descending | Select-Object -First 6 | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Count })
        Fila 'Info' 'Puertos TCP en escucha' ('{0} puertos accesibles desde la red. Principales: {1}' -f $esc.Count, ($procs -join ', '))
    }
    catch { }
}

$sbRestauracion = {
    param([string]$Ayuda)
    try {
        $p = Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object SequenceNumber | Select-Object -Last 1
        if ($p) { [System.Management.ManagementDateTimeConverter]::ToDateTime($p.CreationTime).ToString('yyyy-MM-dd HH:mm') }
    }
    catch { }
}

# ===========================================================================
# MODULOS: cola persistente, actualizaciones, informe y red (carpeta "modulos")
# ===========================================================================
$RaizApp = $PSScriptRoot
foreach ($nombreMod in 'Cola.ps1', 'Actualizaciones.ps1', 'Ejecutores.ps1') {
    $rutaMod = Join-Path $RaizApp ('modulos\' + $nombreMod)
    if (-not (Test-Path -LiteralPath $rutaMod)) {
        [void][System.Windows.MessageBox]::Show((('Falta el archivo modulos\{0}.' -f $nombreMod) + "`n`nExtrae TODA la carpeta del ZIP (no solo PCCare.ps1) y vuelve a abrir PC Care."), 'PC Care')
        exit 1
    }
    . $rutaMod
}

# Tipo de cada tarea: decide la politica de reanudacion (ver modulos\Cola.ps1)
$script:MetaTarea = @{}
$script:Reanudadores = @{}
$mapaTipos = [ordered]@{
    Seguridad = $sbSeguridad; Restauracion = $sbRestauracion; AnalisisBasura = $sbAnalizarBasura; LimpiarBasura = $sbLimpiarBasura
    Grandes = $sbGrandes; Duplicados = $sbDuplicados; Papelera = $sbPapelera; AnalisisRegistro = $sbAnalizarRegistro
    LimpiarRegistro = $sbLimpiarRegistro; Inicio = $sbInicio; Diagnostico = $sbDiagnostico; AccionDiag = $sbAccionDiag
    Procesos = $sbProcesos; Turbo = $sbTurbo
    AnalisisApps = $sbAnalizarApps; ActualizarApp = $sbActualizarApp; InstalarHerramienta = $sbInstalarHerramienta
    Store = $sbStore; AnalisisDrivers = $sbAnalizarDrivers; InstalarDrivers = $sbInstalarDrivers
    Informe = $sbInformeAuditoria; RedDiagnostico = $sbRedDiagnostico; RedAplicar = $sbRedAplicar; RedReparar = $sbRedReparar
}
foreach ($k in $mapaTipos.Keys) { $script:MetaTarea[$mapaTipos[$k]] = [string]$k }

# Una sola ventana a la vez: dos instancias se pisarian la cola de tareas guardada
if (-not $AutoPrueba) {
    $script:mutexApp = New-Object System.Threading.Mutex($false, 'Local\PCCare_UnaSolaInstancia')
    if (-not $script:mutexApp.WaitOne(0)) {
        [void][System.Windows.MessageBox]::Show('PC Care ya está abierto en este equipo. Búscalo en la barra de tareas.', 'PC Care')
        exit 0
    }
}


# ===========================================================================
# INTERFAZ
# ===========================================================================
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PC Care" Width="1240" Height="820" MinWidth="1000" MinHeight="620"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13" Background="#F3F5F8" Foreground="#1C2733">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="#1565C0"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="borde" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="borde" Property="Opacity" Value="0.86"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="borde" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Btn2" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#1C2733"/>
      <Setter Property="BorderBrush" Value="#B8C2CC"/>
    </Style>
    <Style x:Key="BtnTurbo" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#F2A33A"/>
      <Setter Property="Foreground" Value="#1C2733"/>
    </Style>
    <Style x:Key="BtnFila" TargetType="Button" BasedOn="{StaticResource Btn2}">
      <Setter Property="Padding" Value="10,2"/>
      <Setter Property="Margin" Value="2"/>
    </Style>
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#C9D6E2"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="fondo" Background="Transparent" CornerRadius="7" Padding="14,10">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="fondo" Property="Background" Value="#17395A"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="fondo" Property="Background" Value="#1D4468"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="18"/>
      <Setter Property="Margin" Value="0,0,14,14"/>
      <Setter Property="BorderBrush" Value="#E3E7EC"/>
      <Setter Property="BorderThickness" Value="1"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="24"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
    </Style>
    <Style x:Key="Mut" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#55616E"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Num" TargetType="TextBlock">
      <Setter Property="FontSize" Value="24"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Margin" Value="0,2,0,2"/>
    </Style>
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/>
      <Setter Property="Foreground" Value="#1565C0"/>
      <Setter Property="Background" Value="#E4E9EF"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Margin" Value="0,2,18,4"/>
    </Style>
    <Style TargetType="DataGrid">
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#E6EAEE"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="RowBackground" Value="White"/>
      <Setter Property="RowHeight" Value="32"/>
      <Setter Property="SelectionMode" Value="Single"/>
      <Setter Property="Margin" Value="0,8,0,8"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#F3F5F8"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="6,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <DataTemplate x:Key="ChkSel">
      <CheckBox IsChecked="{Binding Sel, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </DataTemplate>
    <DataTemplate x:Key="TagEstado">
      <Border CornerRadius="9" Padding="8,2" HorizontalAlignment="Left" VerticalAlignment="Center">
        <Border.Style>
          <Style TargetType="Border">
            <Setter Property="Background" Value="#E1E8F0"/>
            <Style.Triggers>
              <DataTrigger Binding="{Binding Estado}" Value="Crítico"><Setter Property="Background" Value="#FADADA"/></DataTrigger>
              <DataTrigger Binding="{Binding Estado}" Value="Alerta"><Setter Property="Background" Value="#FCE9CF"/></DataTrigger>
              <DataTrigger Binding="{Binding Estado}" Value="Al día"><Setter Property="Background" Value="#DDF0E2"/></DataTrigger>
              <DataTrigger Binding="{Binding Estado}" Value="En curso"><Setter Property="Background" Value="#CFE3F8"/></DataTrigger>
              <DataTrigger Binding="{Binding Estado}" Value="Completada"><Setter Property="Background" Value="#DDF0E2"/></DataTrigger>
              <DataTrigger Binding="{Binding Estado}" Value="Error"><Setter Property="Background" Value="#FADADA"/></DataTrigger>
              <DataTrigger Binding="{Binding Estado}" Value="Interrumpida"><Setter Property="Background" Value="#FCE9CF"/></DataTrigger>
            </Style.Triggers>
          </Style>
        </Border.Style>
        <TextBlock Text="{Binding Estado}" FontSize="12" FontWeight="SemiBold" Foreground="#1C2733"/>
      </Border>
    </DataTemplate>
    <Style x:Key="FilaAct" TargetType="DataGridRow">
      <Setter Property="Background" Value="White"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding Estado}" Value="Actualizado"><Setter Property="Background" Value="#E6F5EA"/></DataTrigger>
        <DataTrigger Binding="{Binding Estado}" Value="En cola"><Setter Property="Background" Value="#EAF1FB"/></DataTrigger>
        <DataTrigger Binding="{Binding Estado}" Value="Ignorada"><Setter Property="Foreground" Value="#8A96A3"/></DataTrigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <DockPanel>
    <!-- Menu lateral -->
    <Border DockPanel.Dock="Left" Background="#0F2A43" Width="212" Padding="14,20">
      <DockPanel>
        <StackPanel DockPanel.Dock="Bottom">
          <TextBlock x:Name="txtVersion" Foreground="#AFC0D1" FontSize="11" Margin="6,10,0,0"/>
        </StackPanel>
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel>
          <TextBlock Text="PC Care" Foreground="White" FontSize="21" FontWeight="Bold" Margin="6,0,0,0"/>
          <TextBlock Text="Mantenimiento de Windows" Foreground="#AFC0D1" FontSize="12" Margin="6,0,0,18"/>
          <TextBlock Text="GENERAL" Foreground="#8AA0BB" FontSize="11" Margin="8,0,0,6"/>
          <RadioButton x:Name="navPanel" GroupName="nav" Style="{StaticResource Nav}" Content="Panel" IsChecked="True"/>
          <RadioButton x:Name="navLimpieza" GroupName="nav" Style="{StaticResource Nav}" Content="Limpieza"/>
          <RadioButton x:Name="navRend" GroupName="nav" Style="{StaticResource Nav}" Content="Rendimiento"/>
          <RadioButton x:Name="navMonitor" GroupName="nav" Style="{StaticResource Nav}" Content="Monitor"/>
          <TextBlock Text="MANTENIMIENTO" Foreground="#8AA0BB" FontSize="11" Margin="8,14,0,6"/>
          <RadioButton x:Name="navSeg" GroupName="nav" Style="{StaticResource Nav}" Content="Seguridad"/>
          <RadioButton x:Name="navAct" GroupName="nav" Style="{StaticResource Nav}" Content="Actualizaciones"/>
          <RadioButton x:Name="navRed" GroupName="nav" Style="{StaticResource Nav}" Content="Red"/>
          <RadioButton x:Name="navInforme" GroupName="nav" Style="{StaticResource Nav}" Content="Informe del equipo"/>
          <TextBlock Text="ACTIVIDAD" Foreground="#8AA0BB" FontSize="11" Margin="8,14,0,6"/>
          <RadioButton x:Name="navTareas" GroupName="nav" Style="{StaticResource Nav}" Content="Tareas"/>
          <RadioButton x:Name="navHist" GroupName="nav" Style="{StaticResource Nav}" Content="Historial"/>
        </StackPanel></ScrollViewer>
      </DockPanel>
    </Border>

    <!-- Barra superior -->
    <Border DockPanel.Dock="Top" Background="White" BorderBrush="#E3E7EC" BorderThickness="0,0,0,1" Padding="22,9">
      <DockPanel>
        <Border x:Name="cajaSim" DockPanel.Dock="Right" Background="#DDF0E2" CornerRadius="8" Padding="12,6" Margin="14,0,0,0">
          <CheckBox x:Name="chkSimulacion" Content="Simulación activa: no se modifica nada" IsChecked="True" VerticalAlignment="Center" FontWeight="SemiBold" Foreground="#12805A"/>
        </Border>
        <Border Background="#E5F5ED" CornerRadius="10" Padding="10,3" Margin="0,0,8,0" DockPanel.Dock="Right">
          <TextBlock x:Name="txtChipAdmin" Text="✓ Administrador" Foreground="#12805A" FontSize="12" FontWeight="SemiBold"/>
        </Border>
        <Border Background="#EEF1F6" CornerRadius="10" Padding="10,3" Margin="0,0,8,0" DockPanel.Dock="Right">
          <TextBlock x:Name="txtChipRestauracion" Text="Restauración: leyendo..." Foreground="#40526B" FontSize="12"/>
        </Border>
        <TextBlock x:Name="txtMigas" Text="PC Care  /  Panel" Foreground="#55616E" FontSize="13" VerticalAlignment="Center"/>
      </DockPanel>
    </Border>

    <!-- Barra inferior -->
    <Border DockPanel.Dock="Bottom" Background="White" BorderBrush="#E3E7EC" BorderThickness="0,1,0,0" Padding="16,6">
      <StackPanel>
        <DockPanel>
          <Button x:Name="btnCancelar" DockPanel.Dock="Right" Style="{StaticResource Btn2}" Content="Cancelar tarea" Margin="0" Padding="12,3" IsEnabled="False"/>
          <ProgressBar x:Name="barra" Width="130" Margin="0,0,10,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="txtEstado" Text="Listo" VerticalAlignment="Center"/>
        </DockPanel>
        <Expander x:Name="expLog" Header="Registro de actividad" Margin="0,4,0,0">
          <TextBox x:Name="txtLog" Height="130" IsReadOnly="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12" TextWrapping="NoWrap" BorderThickness="0"/>
        </Expander>
      </StackPanel>
    </Border>

    <Grid>
      <!-- ============ PANEL ============ -->
      <ScrollViewer x:Name="vPanel" VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="24,20,10,10">
          <TextBlock Text="Panel" Style="{StaticResource H1}"/>
          <TextBlock x:Name="txtEquipo" Style="{StaticResource Mut}" Margin="0,0,0,14"/>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="2*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border Style="{StaticResource Card}">
              <DockPanel>
                <Border DockPanel.Dock="Left" Width="112" Height="112" CornerRadius="56" BorderBrush="#1565C0" BorderThickness="9" Margin="0,0,20,0">
                  <StackPanel VerticalAlignment="Center">
                    <TextBlock x:Name="txtPuntaje" Text="--" FontSize="30" FontWeight="Bold" HorizontalAlignment="Center"/>
                    <TextBlock Text="controles en orden" Foreground="#55616E" FontSize="12" HorizontalAlignment="Center"/>
                  </StackPanel>
                </Border>
                <StackPanel VerticalAlignment="Center">
                  <TextBlock x:Name="txtEstadoTitulo" Text="Analizando el equipo..." Style="{StaticResource H2}"/>
                  <TextBlock x:Name="txtEstadoDesc" Style="{StaticResource Mut}" Margin="0,0,0,12" Text="Cuidado inteligente: limpia la basura marcada, vacía la caché DNS y optimiza la unidad. Siempre muestra el detalle antes de aplicar."/>
                  <StackPanel Orientation="Horizontal">
                    <Button x:Name="btnMant" Style="{StaticResource Btn}" Content="Cuidado inteligente"/>
                    <Button x:Name="btnAnalizarTodo" Style="{StaticResource Btn2}" Content="Analizar todo"/>
                  </StackPanel>
                </StackPanel>
              </DockPanel>
            </Border>
            <Border Grid.Column="1" Style="{StaticResource Card}" Background="#0F2A43">
              <StackPanel>
                <TextBlock Text="TurboPC" Style="{StaticResource H2}" Foreground="White"/>
                <TextBlock x:Name="txtTurbo" Foreground="#C9D6E2" TextWrapping="Wrap" Margin="0,0,0,12" Text="Libera memoria RAM, pasa a alto rendimiento y cierra solo los procesos que marques en Rendimiento. Se revierte al desactivarlo."/>
                <Button x:Name="btnTurbo" Style="{StaticResource BtnTurbo}" Content="Activar TurboPC" HorizontalAlignment="Left"/>
              </StackPanel>
            </Border>
          </Grid>
          <UniformGrid Columns="4">
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Text="Archivos basura" Style="{StaticResource Mut}"/>
              <TextBlock x:Name="txtTBasura" Text="--" Style="{StaticResource Num}"/>
              <TextBlock x:Name="txtTBasuraD" Style="{StaticResource Mut}" Text="Sin analizar"/>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Text="Grandes y duplicados" Style="{StaticResource Mut}"/>
              <TextBlock x:Name="txtTArch" Text="--" Style="{StaticResource Num}"/>
              <TextBlock x:Name="txtTArchD" Style="{StaticResource Mut}" Text="Se buscan desde Limpieza"/>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Text="Arranque" Style="{StaticResource Mut}"/>
              <TextBlock x:Name="txtTArranque" Text="--" Style="{StaticResource Num}"/>
              <TextBlock x:Name="txtTArranqueD" Style="{StaticResource Mut}" Text="Sin analizar"/>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Text="Problemas detectados" Style="{StaticResource Mut}"/>
              <TextBlock x:Name="txtTProblemas" Text="--" Style="{StaticResource Num}"/>
              <TextBlock x:Name="txtTProblemasD" Style="{StaticResource Mut}" Text="Sin analizar"/>
            </StackPanel></Border>
          </UniformGrid>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="En tiempo real" Style="{StaticResource H2}"/>
              <UniformGrid Columns="4" Margin="0,6,0,0">
                <StackPanel>
                  <TextBlock Text="CPU" Style="{StaticResource Mut}"/>
                  <TextBlock x:Name="txtCpu" Text="--" FontSize="20" FontWeight="SemiBold"/>
                  <ProgressBar x:Name="pbCpu"/>
                </StackPanel>
                <StackPanel>
                  <TextBlock Text="Memoria" Style="{StaticResource Mut}"/>
                  <TextBlock x:Name="txtRam" Text="--" FontSize="20" FontWeight="SemiBold"/>
                  <ProgressBar x:Name="pbRam"/>
                  <TextBlock x:Name="txtRamD" Style="{StaticResource Mut}"/>
                </StackPanel>
                <StackPanel>
                  <TextBlock Text="Temperatura del disco" Style="{StaticResource Mut}"/>
                  <TextBlock x:Name="txtTempP" Text="--" FontSize="20" FontWeight="SemiBold"/>
                  <ProgressBar x:Name="pbTemp" Foreground="#C2620A"/>
                </StackPanel>
                <StackPanel>
                  <TextBlock Text="Red" Style="{StaticResource Mut}"/>
                  <TextBlock x:Name="txtRedP" Text="--" FontSize="20" FontWeight="SemiBold"/>
                  <TextBlock x:Name="txtRedPD" Style="{StaticResource Mut}"/>
                </StackPanel>
              </UniformGrid>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- ============ LIMPIEZA ============ -->
      <ScrollViewer x:Name="vLimpieza" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="24,20,10,10">
          <TextBlock Text="Limpieza" Style="{StaticResource H1}" Margin="0,0,0,6"/>
          <TextBlock Style="{StaticResource Mut}" Margin="0,0,0,10" Text="Lista cerrada de carpetas. Nunca se toca Windows, Archivos de programa, ProgramData ni AppData. Tus archivos van a la Papelera, no se borran directo."/>
          <TabControl x:Name="tabLimpieza" BorderThickness="0" Background="Transparent" Padding="0">
          <TabItem Header="Basura" FontSize="14" FontWeight="SemiBold"><StackPanel Margin="0,10,0,0">
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Archivos basura" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Mut}" Text="Solo se borra dentro de carpetas temporales y de caché conocidas. Los archivos en uso se omiten. No toca cookies, contraseñas ni historial."/>
              <DataGrid x:Name="gridBasura">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Width="36" CellTemplate="{StaticResource ChkSel}"/>
                  <DataGridTextColumn Header="Categoría" Binding="{Binding Nombre}" Width="3*"/>
                  <DataGridTextColumn Header="Archivos" Binding="{Binding Archivos}" Width="*"/>
                  <DataGridTextColumn Header="Tamaño" Binding="{Binding Tamano}" SortMemberPath="Bytes" Width="*"/>
                </DataGrid.Columns>
              </DataGrid>
              <DockPanel>
                <Button x:Name="btnLimpiarBasura" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Limpiar seleccionados" Margin="0"/>
                <Button x:Name="btnAnalizarBasura" DockPanel.Dock="Right" Style="{StaticResource Btn2}" Content="Volver a analizar"/>
                <TextBlock x:Name="txtBasuraTotal" VerticalAlignment="Center" FontWeight="SemiBold"/>
              </DockPanel>
            </StackPanel>
          </Border>
          </StackPanel></TabItem>
          <TabItem Header="Grandes y duplicados" FontSize="14" FontWeight="SemiBold"><StackPanel Margin="0,10,0,0">
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Archivos grandes y duplicados en la unidad del sistema" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Mut}" Text="Busca en carpetas de usuario. No entra a Windows, Archivos de programa ni AppData. Los duplicados se comparan por contenido. Lo que elijas va a la Papelera, así se puede recuperar."/>
              <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                <TextBlock Text="Tamaño mínimo:" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <ComboBox x:Name="cmbMin" Width="100" SelectedIndex="1" VerticalAlignment="Center" Margin="0,0,12,0">
                  <ComboBoxItem Content="5 MB"/><ComboBoxItem Content="100 MB"/><ComboBoxItem Content="500 MB"/><ComboBoxItem Content="1 GB"/>
                </ComboBox>
                <Button x:Name="btnGrandes" Style="{StaticResource Btn2}" Content="Buscar archivos grandes"/>
                <Button x:Name="btnDuplicados" Style="{StaticResource Btn2}" Content="Buscar duplicados"/>
                <Button x:Name="btnMarcarCopias" Style="{StaticResource Btn2}" Content="Marcar copias (conserva la más reciente)"/>
              </StackPanel>
              <DataGrid x:Name="gridArch" Height="250">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Width="36" CellTemplate="{StaticResource ChkSel}"/>
                  <DataGridTextColumn Header="Grupo" Binding="{Binding Grupo}" Width="56"/>
                  <DataGridTextColumn Header="Archivo" Binding="{Binding Nombre}" Width="3*"/>
                  <DataGridTextColumn Header="Carpeta" Binding="{Binding Carpeta}" Width="4*"/>
                  <DataGridTextColumn Header="Tamaño" Binding="{Binding Tamano}" SortMemberPath="Bytes" Width="80"/>
                  <DataGridTextColumn Header="Modificado" Binding="{Binding Modificado}" Width="90"/>
                  <DataGridTextColumn Header="Nube" Binding="{Binding Nube}" Width="96"/>
                </DataGrid.Columns>
              </DataGrid>
              <DockPanel>
                <Button x:Name="btnPapelera" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Enviar a la Papelera" Margin="0"/>
                <TextBlock x:Name="txtArchSel" VerticalAlignment="Center" Style="{StaticResource Mut}" Text="Sin búsqueda todavía."/>
              </DockPanel>
            </StackPanel>
          </Border>
          </StackPanel></TabItem>
          <TabItem Header="Registro (avanzado)" FontSize="14" FontWeight="SemiBold"><StackPanel Margin="0,10,0,0">
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Registro de Windows (avanzado)" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Mut}" Text="Solo tres tipos de entrada comprobada: programas de inicio cuyo archivo ya no existe, rutas de aplicación rotas y desinstaladores huérfanos. Antes de borrar se exporta un respaldo .reg. No mejora la velocidad: sirve para ordenar."/>
              <DataGrid x:Name="gridReg" Height="150">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Width="36" CellTemplate="{StaticResource ChkSel}"/>
                  <DataGridTextColumn Header="Tipo" Binding="{Binding Tipo}" Width="150"/>
                  <DataGridTextColumn Header="Clave" Binding="{Binding RutaPS}" Width="3*"/>
                  <DataGridTextColumn Header="Valor" Binding="{Binding Valor}" Width="*"/>
                  <DataGridTextColumn Header="Motivo" Binding="{Binding Detalle}" Width="3*"/>
                </DataGrid.Columns>
              </DataGrid>
              <DockPanel>
                <Button x:Name="btnLimpiarReg" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Limpiar seleccionadas" Margin="0"/>
                <Button x:Name="btnAnalizarReg" DockPanel.Dock="Right" Style="{StaticResource Btn2}" Content="Analizar registro"/>
                <CheckBox x:Name="chkRegPunto" Content="Crear punto de restauración antes de limpiar" IsChecked="True" VerticalAlignment="Center"/>
              </DockPanel>
            </StackPanel>
          </Border>
          </StackPanel></TabItem>
          </TabControl>
        </StackPanel>
      </ScrollViewer>

      <!-- ============ RENDIMIENTO ============ -->
      <ScrollViewer x:Name="vRend" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="24,20,10,10">
          <TextBlock Text="Rendimiento" Style="{StaticResource H1}" Margin="0,0,0,10"/>
          <TabControl x:Name="tabRend" BorderThickness="0" Background="Transparent" Padding="0">
          <TabItem Header="TurboPC" FontSize="14" FontWeight="SemiBold"><StackPanel Margin="0,10,0,0">
          <Border Style="{StaticResource Card}" Background="#0F2A43">
            <DockPanel>
              <Button x:Name="btnTurbo2" DockPanel.Dock="Right" Style="{StaticResource BtnTurbo}" Content="Activar TurboPC" VerticalAlignment="Center" Margin="12,0,0,0"/>
              <StackPanel>
                <TextBlock Text="TurboPC" Style="{StaticResource H2}" Foreground="White"/>
                <TextBlock Foreground="#C9D6E2" TextWrapping="Wrap" Text="¿Word o Excel van lentos? TurboPC pasa el equipo a alto rendimiento y libera memoria RAM de los programas en segundo plano. Además cierra los procesos que marques abajo; por su cuenta no cierra ninguno. Nunca toca procesos de Windows ni el antivirus."/>
              </StackPanel>
            </DockPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <DockPanel>
                <Button x:Name="btnProcesos" DockPanel.Dock="Right" Style="{StaticResource Btn2}" Content="Actualizar lista" Margin="0"/>
                <TextBlock Text="Programas que más memoria usan (marca los que TurboPC debe cerrar)" Style="{StaticResource H2}"/>
              </DockPanel>
              <DataGrid x:Name="gridProc" Height="170">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Width="36" CellTemplate="{StaticResource ChkSel}"/>
                  <DataGridTextColumn Header="Programa" Binding="{Binding Proceso}" Width="3*"/>
                  <DataGridTextColumn Header="Instancias" Binding="{Binding Instancias}" Width="*"/>
                  <DataGridTextColumn Header="Memoria (MB)" Binding="{Binding MemoriaMB}" Width="*"/>
                  <DataGridTextColumn Header="Estado" Binding="{Binding Ventana}" Width="2*"/>
                </DataGrid.Columns>
              </DataGrid>
            </StackPanel>
          </Border>
          </StackPanel></TabItem>
          <TabItem Header="Arranque de Windows" FontSize="14" FontWeight="SemiBold"><StackPanel Margin="0,10,0,0">
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Arranque de Windows" Style="{StaticResource H2}"/>
              <TextBlock x:Name="txtArranque" Style="{StaticResource Mut}" Text="Desmarca lo que no necesitas que inicie con Windows. No se desinstala nada: es el mismo interruptor del Administrador de tareas."/>
              <DataGrid x:Name="gridInicio" Height="210">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Header="Inicia" Width="56" CellTemplate="{StaticResource ChkSel}"/>
                  <DataGridTextColumn Header="Programa" Binding="{Binding Nombre}" Width="2*"/>
                  <DataGridTextColumn Header="Comando" Binding="{Binding Comando}" Width="4*"/>
                  <DataGridTextColumn Header="Origen" Binding="{Binding Origen}" Width="150"/>
                </DataGrid.Columns>
              </DataGrid>
              <DockPanel>
                <Button x:Name="btnAplicarInicio" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Aplicar cambios" Margin="0"/>
                <TextBlock x:Name="txtInicioCambios" VerticalAlignment="Center" Style="{StaticResource Mut}"/>
              </DockPanel>
            </StackPanel>
          </Border>
          </StackPanel></TabItem>
          <TabItem Header="Diagnóstico" FontSize="14" FontWeight="SemiBold"><StackPanel Margin="0,10,0,0">
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <DockPanel>
                <Button x:Name="btnDiagnosticar" DockPanel.Dock="Right" Style="{StaticResource Btn2}" Content="Volver a diagnosticar" Margin="0"/>
                <TextBlock Text="Diagnóstico de problemas comunes" Style="{StaticResource H2}"/>
              </DockPanel>
              <DataGrid x:Name="gridDiag" Height="330">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Header="Estado" Width="90" CellTemplate="{StaticResource TagEstado}"/>
                  <DataGridTextColumn Header="Revisión" Binding="{Binding Titulo}" Width="2*"/>
                  <DataGridTextColumn Header="Detalle" Binding="{Binding Detalle}" Width="5*"/>
                  <DataGridTemplateColumn Header="" Width="150">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <Button Content="{Binding TextoAccion}">
                          <Button.Style>
                            <Style TargetType="Button" BasedOn="{StaticResource BtnFila}">
                              <Style.Triggers>
                                <DataTrigger Binding="{Binding Accion}" Value=""><Setter Property="Visibility" Value="Hidden"/></DataTrigger>
                              </Style.Triggers>
                            </Style>
                          </Button.Style>
                        </Button>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                </DataGrid.Columns>
              </DataGrid>
            </StackPanel>
          </Border>
          </StackPanel></TabItem>
          </TabControl>
        </StackPanel>
      </ScrollViewer>

      <!-- ============ MONITOR ============ -->
      <ScrollViewer x:Name="vMonitor" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="24,20,10,10">
          <TextBlock Text="Monitor" Style="{StaticResource H1}" Margin="0,0,0,14"/>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Temperatura del disco" Style="{StaticResource H2}"/>
                <StackPanel Orientation="Horizontal">
                  <TextBlock x:Name="txtTempM" Text="--" FontSize="40" FontWeight="Bold"/>
                  <TextBlock x:Name="txtTempMD" Style="{StaticResource Mut}" VerticalAlignment="Bottom" Margin="12,0,0,8"/>
                </StackPanel>
                <Border Background="#F3F5F8" CornerRadius="6" Height="90" Margin="0,6,0,6">
                  <Canvas x:Name="cvTemp" ClipToBounds="True"><Polyline x:Name="lnTemp" Stroke="#C2620A" StrokeThickness="2"/></Canvas>
                </Border>
                <TextBlock Style="{StaticResource Mut}" Text="Último minuto. Referencia general: hasta 55 °C normal, 55 a 70 °C atención, más de 70 °C crítico."/>
                <DataGrid x:Name="gridDiscos" Height="100">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="Disco" Binding="{Binding Disco}" Width="3*"/>
                    <DataGridTextColumn Header="Tipo" Binding="{Binding Tipo}" Width="*"/>
                    <DataGridTextColumn Header="°C" Binding="{Binding Temp}" Width="*"/>
                    <DataGridTextColumn Header="Salud" Binding="{Binding Salud}" Width="*"/>
                    <DataGridTextColumn Header="Desgaste %" Binding="{Binding Desgaste}" Width="*"/>
                    <DataGridTextColumn Header="Horas" Binding="{Binding Horas}" Width="*"/>
                  </DataGrid.Columns>
                </DataGrid>
              </StackPanel>
            </Border>
            <Border Grid.Column="1" Style="{StaticResource Card}">
              <StackPanel>
                <TextBlock Text="Velocidad de red en tiempo real" Style="{StaticResource H2}"/>
                <StackPanel Orientation="Horizontal">
                  <StackPanel Margin="0,0,30,0">
                    <TextBlock Text="Descarga" Style="{StaticResource Mut}"/>
                    <TextBlock x:Name="txtBajada" Text="--" FontSize="28" FontWeight="Bold" Foreground="#1565C0"/>
                  </StackPanel>
                  <StackPanel>
                    <TextBlock Text="Subida" Style="{StaticResource Mut}"/>
                    <TextBlock x:Name="txtSubida" Text="--" FontSize="28" FontWeight="Bold" Foreground="#8A4300"/>
                  </StackPanel>
                </StackPanel>
                <Border Background="#F3F5F8" CornerRadius="6" Height="110" Margin="0,6,0,6">
                  <Canvas x:Name="cvRed" ClipToBounds="True">
                    <Polyline x:Name="lnBajada" Stroke="#1565C0" StrokeThickness="2"/>
                    <Polyline x:Name="lnSubida" Stroke="#C2620A" StrokeThickness="2" StrokeDashArray="3 2"/>
                  </Canvas>
                </Border>
                <TextBlock x:Name="txtRedEscala" Style="{StaticResource Mut}" Text="Línea continua: descarga. Línea punteada: subida."/>
              </StackPanel>
            </Border>
          </Grid>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Programas conectados a la red" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Mut}" Text="Conexiones activas por programa, actualizado cada pocos segundos. Sirve para ubicar qué está usando la red en segundo plano. Esta versión no mide Mbps por programa."/>
              <DataGrid x:Name="gridRed" Height="230">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="Programa" Binding="{Binding Proceso}" Width="3*"/>
                  <DataGridTextColumn Header="Conexiones activas" Binding="{Binding Conexiones}" Width="*"/>
                  <DataGridTextColumn Header="Destinos distintos" Binding="{Binding Destinos}" Width="*"/>
                </DataGrid.Columns>
              </DataGrid>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- ============ SEGURIDAD ============ -->
      <ScrollViewer x:Name="vSeg" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="24,20,10,10">
          <TextBlock Text="Seguridad" Style="{StaticResource H1}" Margin="0,0,0,6"/>
          <TextBlock Style="{StaticResource Mut}" Margin="0,0,0,14" Text="Estado de las protecciones de Windows. PC Care solo informa: no cambia la configuración del antivirus ni del firewall."/>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <DockPanel>
                <Button x:Name="btnSegRevisar" DockPanel.Dock="Right" Style="{StaticResource Btn2}" Content="Volver a revisar" Margin="0"/>
                <Button x:Name="btnAbrirSeg" DockPanel.Dock="Right" Style="{StaticResource Btn2}" Content="Abrir Seguridad de Windows"/>
                <TextBlock Text="Protecciones y exposición" Style="{StaticResource H2}"/>
              </DockPanel>
              <DataGrid x:Name="gridSeg" Height="400">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Header="Estado" Width="90" CellTemplate="{StaticResource TagEstado}"/>
                  <DataGridTextColumn Header="Revisión" Binding="{Binding Titulo}" Width="2*"/>
                  <DataGridTextColumn Header="Detalle" Binding="{Binding Detalle}" Width="5*"/>
                </DataGrid.Columns>
              </DataGrid>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- ============ HISTORIAL ============ -->
      <ScrollViewer x:Name="vHist" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="24,20,10,10">
          <TextBlock Text="Historial" Style="{StaticResource H1}" Margin="0,0,0,6"/>
          <TextBlock x:Name="txtHistRuta" Style="{StaticResource Mut}" Margin="0,0,0,14"/>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <DockPanel>
                <Button x:Name="btnHistActualizar" DockPanel.Dock="Right" Style="{StaticResource Btn2}" Content="Actualizar" Margin="0"/>
                <Button x:Name="btnHistRespaldos" DockPanel.Dock="Right" Style="{StaticResource Btn2}" Content="Carpeta de respaldos"/>
                <TextBlock Text="Qué analizó y cambió PC Care (últimas 500 líneas)" Style="{StaticResource H2}"/>
              </DockPanel>
              <DataGrid x:Name="gridHist" Height="470">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="Fecha y hora" Binding="{Binding Fecha}" Width="150"/>
                  <DataGridTextColumn Header="Modo" Binding="{Binding Modo}" Width="90"/>
                  <DataGridTextColumn Header="Actividad" Binding="{Binding Actividad}" Width="*"/>
                </DataGrid.Columns>
              </DataGrid>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- ============ ACTUALIZACIONES ============ -->
      <ScrollViewer x:Name="vAct" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="24,20,10,10">
          <TextBlock Text="Actualizaciones" Style="{StaticResource H1}" Margin="0,0,0,6"/>
          <TextBlock Style="{StaticResource Mut}" Margin="0,0,0,14" TextWrapping="Wrap" Text="Aplicaciones con winget y drivers firmados de Windows Update. Todo pasa por la cola de tareas y respeta el modo simulación de la barra superior."/>
          <Border Style="{StaticResource Card}">
            <DockPanel>
              <Button x:Name="btnActAnalizar" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Analizar equipo" Margin="14,0,0,0"/>
              <TextBlock x:Name="txtActAviso" Style="{StaticResource Mut}" VerticalAlignment="Center" TextWrapping="Wrap" Text="Pulsa Analizar para buscar actualizaciones. Usa internet y la búsqueda de drivers puede tardar unos minutos."/>
            </DockPanel>
          </Border>
          <TabControl x:Name="tabAct" BorderThickness="0" Background="Transparent" Padding="0">
            <TabItem x:Name="tabApps" Header="Aplicaciones" FontSize="14" FontWeight="SemiBold"><StackPanel Margin="0,10,0,0">
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <WrapPanel>
                    <Button x:Name="btnAppsTodo" Style="{StaticResource Btn}" Content="Actualizar todas"/>
                    <Button x:Name="btnAppsSel" Style="{StaticResource Btn2}" Content="Actualizar seleccionadas"/>
                    <Button x:Name="btnAppsReinst" Style="{StaticResource Btn2}" Content="Reinstalar seleccionadas" ToolTip="Desinstala e instala la versión nueva. Para apps que winget no puede actualizar por cambio de instalador."/>
                    <Button x:Name="btnAppsIgnorar" Style="{StaticResource Btn2}" Content="Ignorar seleccionadas" ToolTip="Deja de ofrecer la actualización de esas apps en este equipo."/>
                    <Button x:Name="btnStore" Style="{StaticResource Btn2}" Content="Actualizar Microsoft Store" ToolTip="Pide a Microsoft Store que actualice sus aplicaciones en segundo plano."/>
                    <CheckBox x:Name="chkTerceros" Content="Solo terceros" IsChecked="True" VerticalAlignment="Center" Margin="8,0,0,0"/>
                    <CheckBox x:Name="chkSoloPend" Content="Solo pendientes" VerticalAlignment="Center" Margin="12,0,0,0"/>
                  </WrapPanel>
                  <TextBlock x:Name="txtResApps" Style="{StaticResource Mut}" Margin="0,8,0,0"/>
                  <DataGrid x:Name="gridApps" Height="380" RowStyle="{StaticResource FilaAct}">
                    <DataGrid.Columns>
                      <DataGridTemplateColumn Width="36">
                        <DataGridTemplateColumn.CellTemplate><DataTemplate>
                          <CheckBox IsChecked="{Binding Sel, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center" VerticalAlignment="Center">
                            <CheckBox.Style><Style TargetType="CheckBox"><Style.Triggers>
                              <DataTrigger Binding="{Binding Disponible}" Value=""><Setter Property="Visibility" Value="Hidden"/></DataTrigger>
                            </Style.Triggers></Style></CheckBox.Style>
                          </CheckBox>
                        </DataTemplate></DataGridTemplateColumn.CellTemplate>
                      </DataGridTemplateColumn>
                      <DataGridTextColumn Header="Aplicación" Binding="{Binding Nombre}" Width="3*"/>
                      <DataGridTextColumn Header="Id" Binding="{Binding Id}" Width="2*"/>
                      <DataGridTextColumn Header="Instalada" Binding="{Binding Version}" Width="*"/>
                      <DataGridTextColumn Header="Disponible" Binding="{Binding Disponible}" Width="*"/>
                      <DataGridTextColumn Header="Origen" Binding="{Binding Origen}" Width="70"/>
                      <DataGridTextColumn Header="Estado" Binding="{Binding Estado}" Width="150"/>
                      <DataGridTemplateColumn Width="100">
                        <DataGridTemplateColumn.CellTemplate><DataTemplate>
                          <Button Content="Actualizar" Margin="2" Padding="8,2">
                            <Button.Style><Style TargetType="Button" BasedOn="{StaticResource BtnFila}"><Style.Triggers>
                              <DataTrigger Binding="{Binding Disponible}" Value=""><Setter Property="Visibility" Value="Hidden"/></DataTrigger>
                            </Style.Triggers></Style></Button.Style>
                          </Button>
                        </DataTemplate></DataGridTemplateColumn.CellTemplate>
                      </DataGridTemplateColumn>
                    </DataGrid.Columns>
                  </DataGrid>
                </StackPanel>
              </Border>
            </StackPanel></TabItem>
            <TabItem x:Name="tabDrivers" Header="Drivers" FontSize="14" FontWeight="SemiBold"><StackPanel Margin="0,10,0,0">
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <WrapPanel>
                    <Button x:Name="btnDrvTodo" Style="{StaticResource Btn}" Content="Instalar todos"/>
                    <Button x:Name="btnDrvSel" Style="{StaticResource Btn2}" Content="Instalar seleccionados"/>
                    <CheckBox x:Name="chkDrvPunto" Content="Punto de restauración" IsChecked="True" VerticalAlignment="Center" Margin="8,0,0,0"/>
                    <CheckBox x:Name="chkDrvRespaldo" Content="Respaldar drivers actuales" IsChecked="True" VerticalAlignment="Center" Margin="12,0,0,0"/>
                  </WrapPanel>
                  <TextBlock x:Name="txtResDrv" Style="{StaticResource Mut}" Margin="0,8,0,0"/>
                  <TextBlock x:Name="txtFabricante" Style="{StaticResource Mut}" TextWrapping="Wrap" Margin="0,6,0,4"/>
                  <WrapPanel x:Name="panelHerr"/>
                  <TextBlock Text="Actualizaciones de drivers disponibles" Style="{StaticResource H2}" Margin="0,10,0,0"/>
                  <DataGrid x:Name="gridDrvPend" Height="210" RowStyle="{StaticResource FilaAct}">
                    <DataGrid.Columns>
                      <DataGridTemplateColumn Width="36" CellTemplate="{StaticResource ChkSel}"/>
                      <DataGridTextColumn Header="Actualización" Binding="{Binding Titulo}" Width="3*"/>
                      <DataGridTextColumn Header="Dispositivo" Binding="{Binding Dispositivo}" Width="2*"/>
                      <DataGridTextColumn Header="Clase" Binding="{Binding Clase}" Width="*"/>
                      <DataGridTextColumn Header="Proveedor" Binding="{Binding Proveedor}" Width="*"/>
                      <DataGridTextColumn Header="Fecha" Binding="{Binding Fecha}" Width="90"/>
                      <DataGridTextColumn Header="MB" Binding="{Binding TamanoMB}" Width="60"/>
                      <DataGridTextColumn Header="Estado" Binding="{Binding Estado}" Width="110"/>
                      <DataGridTemplateColumn Width="90">
                        <DataGridTemplateColumn.CellTemplate><DataTemplate>
                          <Button Content="Instalar" Margin="2" Padding="8,2" Style="{StaticResource BtnFila}"/>
                        </DataTemplate></DataGridTemplateColumn.CellTemplate>
                      </DataGridTemplateColumn>
                    </DataGrid.Columns>
                  </DataGrid>
                  <TextBlock Text="Drivers de terceros instalados" Style="{StaticResource H2}" Margin="0,6,0,0"/>
                  <TextBlock Style="{StaticResource Mut}" TextWrapping="Wrap" Text="Los antiguos que Windows Update no ofrece se revisan con la herramienta o la web del fabricante."/>
                  <DataGrid x:Name="gridDrvInst" Height="250">
                    <DataGrid.Columns>
                      <DataGridTextColumn Header="Dispositivo" Binding="{Binding Dispositivo}" Width="3*"/>
                      <DataGridTextColumn Header="Clase" Binding="{Binding Clase}" Width="*"/>
                      <DataGridTextColumn Header="Proveedor" Binding="{Binding Proveedor}" Width="2*"/>
                      <DataGridTextColumn Header="Versión" Binding="{Binding Version}" Width="*"/>
                      <DataGridTextColumn Header="Fecha" Binding="{Binding Fecha}" Width="90"/>
                      <DataGridTextColumn Header="Nota" Binding="{Binding Nota}" Width="140"/>
                    </DataGrid.Columns>
                  </DataGrid>
                </StackPanel>
              </Border>
            </StackPanel></TabItem>
          </TabControl>
        </StackPanel>
      </ScrollViewer>

      <!-- ============ RED ============ -->
      <ScrollViewer x:Name="vRed" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="24,20,10,10">
          <TextBlock Text="Red" Style="{StaticResource H1}" Margin="0,0,0,6"/>
          <TextBlock Style="{StaticResource Mut}" Margin="0,0,0,14" TextWrapping="Wrap" Text="Diagnóstico de la conexión: adaptadores, latencia, pérdida de paquetes, MTU, DNS, proxy y configuración de Windows. Sirve para Wi-Fi, cable y compartir internet del celular por USB."/>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Diagnóstico" Style="{StaticResource H2}"/>
              <WrapPanel>
                <Button x:Name="btnRedDiag" Style="{StaticResource Btn}" Content="Diagnosticar la conexión"/>
                <Button x:Name="btnRedCarpeta" Style="{StaticResource Btn2}" Content="Carpeta de informes de red"/>
                <CheckBox x:Name="chkRedDescarga" Content="Medir también la velocidad de descarga (usa unos 9 MB de datos)" VerticalAlignment="Center" Margin="8,0,0,0"/>
              </WrapPanel>
              <TextBox x:Name="txtRedInforme" Height="320" IsReadOnly="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12" TextWrapping="NoWrap" Margin="0,10,0,0" Text="Pulsa Diagnosticar. Con un plan de datos limitado, deja sin marcar la medición de velocidad."/>
            </StackPanel>
          </Border>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Mejoras propuestas" Style="{StaticResource H2}"/>
              <TextBlock x:Name="txtRedAviso" Style="{StaticResource Mut}" TextWrapping="Wrap" Text="Aparecen después de diagnosticar. Cada cambio se puede revertir con el archivo que se guarda en la carpeta de informes."/>
              <DataGrid x:Name="gridRedCambios" Height="170">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Width="36" CellTemplate="{StaticResource ChkSel}"/>
                  <DataGridTextColumn Header="Cambio" Binding="{Binding Nombre}" Width="2*"/>
                  <DataGridTextColumn Header="Efecto" Binding="{Binding Efecto}" Width="4*"/>
                </DataGrid.Columns>
              </DataGrid>
              <DockPanel>
                <Button x:Name="btnRedReparar" DockPanel.Dock="Right" Style="{StaticResource Btn2}" Content="Reparar la pila de red (avanzado)" Margin="0" ToolTip="Reinicia Winsock y la pila IP. No se puede revertir y exige reiniciar el equipo."/>
                <Button x:Name="btnRedAplicar" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Aplicar mejoras marcadas"/>
                <TextBlock x:Name="txtRedRevertir" VerticalAlignment="Center" TextWrapping="Wrap"/>
              </DockPanel>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- ============ INFORME ============ -->
      <ScrollViewer x:Name="vInforme" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="24,20,10,10">
          <TextBlock Text="Informe del equipo" Style="{StaticResource H1}" Margin="0,0,0,6"/>
          <TextBlock Style="{StaticResource Mut}" Margin="0,0,0,14" TextWrapping="Wrap" Text="Auditoría de solo lectura. No modifica nada en el equipo."/>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <TextBlock Text="Informe completo en HTML" Style="{StaticResource H2}"/>
              <TextBlock Style="{StaticResource Mut}" TextWrapping="Wrap" Text="Revisa seguridad (antivirus, Defender, BitLocker, TPM, Secure Boot, SMBv1), parches de Windows pendientes, software instalado y por actualizar, rendimiento y programas de inicio. Genera un Informe.html y varios archivos CSV que se pueden compartir."/>
              <CheckBox x:Name="chkInfSinWU" Content="Omitir la búsqueda de parches de Windows (más rápido)" Margin="0,10,0,10"/>
              <WrapPanel>
                <Button x:Name="btnInfGenerar" Style="{StaticResource Btn}" Content="Generar informe"/>
                <Button x:Name="btnInfAbrir" Style="{StaticResource Btn2}" Content="Abrir el último informe" IsEnabled="False"/>
                <Button x:Name="btnInfCarpeta" Style="{StaticResource Btn2}" Content="Carpeta de informes"/>
              </WrapPanel>
              <TextBlock x:Name="txtInfEstado" Style="{StaticResource Mut}" TextWrapping="Wrap" Margin="0,10,0,0"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- ============ TAREAS ============ -->
      <ScrollViewer x:Name="vTareas" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
        <StackPanel Margin="24,20,10,10">
          <TextBlock Text="Tareas" Style="{StaticResource H1}" Margin="0,0,0,6"/>
          <TextBlock x:Name="txtTareasRuta" Style="{StaticResource Mut}" Margin="0,0,0,14" TextWrapping="Wrap"/>
          <Border x:Name="cajaInterrumpidas" Style="{StaticResource Card}" Background="#FFF6E5" Visibility="Collapsed">
            <StackPanel>
              <TextBlock Text="Tareas que quedaron a medias" Style="{StaticResource H2}"/>
              <TextBlock x:Name="txtInterrumpidas" Style="{StaticResource Mut}" TextWrapping="Wrap" Text="PC Care se cerró antes de terminar estas tareas. Marca las que quieres continuar."/>
              <DataGrid x:Name="gridInterr" Height="170">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Width="36" CellTemplate="{StaticResource ChkSel}"/>
                  <DataGridTextColumn Header="Tarea" Binding="{Binding Nombre}" Width="2*"/>
                  <DataGridTextColumn Header="Opciones marcadas" Binding="{Binding Opciones}" Width="3*"/>
                  <DataGridTextColumn Header="Estaba" Binding="{Binding Previo}" Width="90"/>
                  <DataGridTextColumn Header="Nota" Binding="{Binding Nota}" Width="3*"/>
                </DataGrid.Columns>
              </DataGrid>
              <DockPanel>
                <Button x:Name="btnDescartar" DockPanel.Dock="Right" Style="{StaticResource Btn2}" Content="Descartar todas" Margin="0"/>
                <Button x:Name="btnReanudar" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Reanudar marcadas"/>
                <TextBlock x:Name="txtInterrNota" VerticalAlignment="Center" TextWrapping="Wrap"/>
              </DockPanel>
            </StackPanel>
          </Border>
          <UniformGrid Columns="2">
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Text="En ejecución ahora" Style="{StaticResource H2}"/>
              <TextBlock x:Name="txtAhora" TextWrapping="Wrap" Text="Nada en ejecución."/>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Text="Marcado ahora, sin ejecutar" Style="{StaticResource H2}"/>
              <TextBlock x:Name="txtSeleccion" TextWrapping="Wrap" Text="No hay nada marcado."/>
            </StackPanel></Border>
          </UniformGrid>
          <Border Style="{StaticResource Card}">
            <StackPanel>
              <DockPanel>
                <Button x:Name="btnQuitarPend" DockPanel.Dock="Right" Style="{StaticResource Btn2}" Content="Quitar pendientes" Margin="0" ToolTip="Saca de la cola lo que aún no empezó. No cancela la tarea en curso."/>
                <Button x:Name="btnPausar" DockPanel.Dock="Right" Style="{StaticResource Btn2}" Content="Pausar cola" ToolTip="La tarea en curso termina; las siguientes esperan hasta que reanudes."/>
                <TextBlock Text="Cola y actividad (se guarda en disco)" Style="{StaticResource H2}"/>
              </DockPanel>
              <DataGrid x:Name="gridTareas" Height="340">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Header="Estado" Width="110" CellTemplate="{StaticResource TagEstado}"/>
                  <DataGridTextColumn Header="Tarea" Binding="{Binding Nombre}" Width="2*"/>
                  <DataGridTextColumn Header="Opciones marcadas" Binding="{Binding Opciones}" Width="3*"/>
                  <DataGridTextColumn Header="Modo" Binding="{Binding Modo}" Width="90"/>
                  <DataGridTextColumn Header="Inicio" Binding="{Binding Inicio}" Width="140"/>
                  <DataGridTextColumn Header="Duración" Binding="{Binding Duracion}" Width="80"/>
                  <DataGridTextColumn Header="Detalle" Binding="{Binding Detalle}" Width="2*"/>
                </DataGrid.Columns>
              </DataGrid>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>
    </Grid>
  </DockPanel>
</Window>
'@

function New-Ventana { return [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml)) }

$textoAyuda = $ayuda.ToString() + "`r`n" + $ayudaActualizaciones.ToString()
. $ayuda   # las mismas funciones quedan disponibles en el hilo de la interfaz
. $ayudaActualizaciones

# ===========================================================================
# AUTOPRUEBA: ejecuta todos los analisis en solo lectura y deja un informe
# ===========================================================================
if ($AutoPrueba) {
    $rutaLog = Join-Path $PSScriptRoot ('PCCare_autoprueba_{0}.log' -f $env:COMPUTERNAME)
    $lineas = New-Object System.Collections.Generic.List[string]
    $script:fallas = 0
    function Test-Paso {
        param([string]$Nombre, [scriptblock]$Bloque)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $r = & $Bloque
            $lineas.Add(('OK     {0,-40} {1,7:N1} s   {2}' -f $Nombre, $sw.Elapsed.TotalSeconds, $r))
        }
        catch {
            $script:fallas++
            $lineas.Add(('ERROR  {0,-40} {1}  [línea {2}]' -f $Nombre, $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber))
        }
    }
    function Assert-Igual { param($Valor, $Esperado, [string]$Que) if ($Valor -ne $Esperado) { throw ('Guarda incorrecta: ' + $Que) } }

    $lineas.Add(('PC Care {0} - autoprueba en {1} - {2}' -f $VersionApp, $env:COMPUTERNAME, (Get-Date).ToString('yyyy-MM-dd HH:mm')))
    $lineas.Add(('Windows: {0} | PowerShell {1}' -f (Get-CimInstance Win32_OperatingSystem).Caption, $PSVersionTable.PSVersion))
    $lineas.Add('')

    Test-Paso 'Guardas de seguridad' {
        $tw = "$env:windir\Temp"
        Assert-Igual (Test-RutaPermitida "$env:windir\System32\kernel32.dll" @($tw)) $false 'System32 fuera de Temp'
        Assert-Igual (Test-RutaPermitida "$tw\a\..\..\System32\x.dll" @($tw)) $false 'escape con ..'
        Assert-Igual (Test-RutaPermitida "$tw\a.tmp" @($tw)) $true 'archivo dentro de Temp'
        Assert-Igual (Test-RutaPermitida "$tw" @($tw)) $false 'la raíz misma'
        Assert-Igual (Test-RutaPermitida 'C:\a.txt' @('C:\')) $false 'raíz demasiado corta'
        $ru = Get-RaicesUsuario
        Assert-Igual (Test-ArchivoUsuarioSeguro "$env:windir\explorer.exe" $ru) $false 'explorer.exe'
        Assert-Igual (Test-ArchivoUsuarioSeguro "$env:ProgramFiles\x\y.dll" $ru) $false 'Program Files'
        Assert-Igual (Test-ArchivoUsuarioSeguro "$env:LOCALAPPDATA\x.bin" $ru) $false 'AppData'
        Assert-Igual (Test-ArchivoUsuarioSeguro "$env:USERPROFILE\Downloads\x.iso" $ru) $true 'Descargas'
        Assert-Igual (Test-ClaveRegistroPermitida 'Inicio' 'HKLM:\SYSTEM\CurrentControlSet\Services') $false 'clave de servicios'
        Assert-Igual (Test-ClaveRegistroPermitida 'Desinstalador huérfano' 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall') $false 'raíz de Uninstall'
        Assert-Igual (Test-FaltaEnDiscoFijo 'Z:\no\existe.exe') $false 'unidad inexistente'
        Assert-Igual ($null -eq (Get-RutaDeComando 'MsiExec.exe /X{0000}')) $true 'comando sin ruta absoluta'
        '13 comprobaciones'
    }
    Test-Paso 'Interfaz (XAML)' {
        $v = New-Ventana
        $claves = 'gridDiag', 'gridSeg', 'gridHist', 'btnCancelar', 'chkSimulacion', 'cajaSim', 'tabLimpieza', 'tabRend', 'txtMigas',
        'navAct', 'navRed', 'navInforme', 'navTareas', 'vAct', 'vRed', 'vInforme', 'vTareas', 'gridTareas', 'gridInterr', 'cajaInterrumpidas',
        'btnReanudar', 'btnDescartar', 'btnPausar', 'btnQuitarPend', 'txtAhora', 'txtSeleccion', 'txtTareasRuta', 'txtInterrNota', 'txtInterrumpidas',
        'gridApps', 'gridDrvPend', 'gridDrvInst', 'tabApps', 'tabDrivers', 'btnActAnalizar', 'txtActAviso', 'btnAppsTodo', 'btnAppsSel', 'btnAppsReinst',
        'btnAppsIgnorar', 'btnStore', 'chkTerceros', 'chkSoloPend', 'txtResApps', 'txtResDrv', 'txtFabricante', 'panelHerr', 'btnDrvTodo', 'btnDrvSel',
        'chkDrvPunto', 'chkDrvRespaldo', 'chkInfSinWU', 'btnInfGenerar', 'btnInfAbrir', 'btnInfCarpeta', 'txtInfEstado',
        'chkRedDescarga', 'btnRedDiag', 'btnRedCarpeta', 'txtRedInforme', 'gridRedCambios', 'btnRedAplicar', 'btnRedReparar', 'txtRedAviso', 'txtRedRevertir'
        foreach ($n in $claves) { if (-not $v.FindName($n)) { throw ('falta el control ' + $n) } }
        'carga correcta, {0} controles clave' -f @($claves).Count
    }
    Test-Paso 'Seguridad (solo lectura)' { $r = @(& $sbSeguridad -Ayuda $textoAyuda); '{0} controles: {1}' -f $r.Count, (($r | Group-Object Estado | ForEach-Object { '{0} {1}' -f $_.Count, $_.Name }) -join ', ') }
    Test-Paso 'Punto de restauración (lectura)' { $r = @(& $sbRestauracion -Ayuda $textoAyuda); if ($r.Count -gt 0 -and $r[0]) { 'último: ' + $r[0] } else { 'sin puntos de restauración' } }
    Test-Paso 'Basura: análisis' { $r = @(& $sbAnalizarBasura -Ayuda $textoAyuda); '{0} categorías, {1}' -f $r.Count, (Format-Tamano (($r | Measure-Object Bytes -Sum).Sum)) }
    Test-Paso 'Basura: limpieza simulada' { $r = & $sbLimpiarBasura -Ayuda $textoAyuda -Ids @('TempUsuario', 'TempWindows', 'WUCache', 'Navegadores', 'Errores', 'Papelera') -Simular $true; 'liberaría {0}' -f (Format-Tamano $r.Bytes) }
    Test-Paso 'Archivos grandes (500 MB o más)' { $r = @(& $sbGrandes -Ayuda $textoAyuda -MinMB 500); '{0} archivos' -f $r.Count }
    Test-Paso 'Duplicados (300 MB o más)' { $r = @(& $sbDuplicados -Ayuda $textoAyuda -MinMB 300); '{0} archivos en grupos' -f $r.Count }
    Test-Paso 'Papelera simulada (ruta de sistema)' { $r = & $sbPapelera -Ayuda $textoAyuda -Rutas @("$env:windir\explorer.exe") -Simular $true; if ($r.Hechos.Count -ne 0) { throw 'no bloqueó explorer.exe' }; 'bloqueada correctamente' }
    Test-Paso 'Registro: análisis' { $r = @(& $sbAnalizarRegistro -Ayuda $textoAyuda); '{0} entradas inválidas' -f $r.Count }
    Test-Paso 'Registro: limpieza simulada' { $r = & $sbLimpiarRegistro -Ayuda $textoAyuda -Items @('Inicio|HKLM:\SYSTEM\CurrentControlSet\Services|x') -Punto $false -Carpeta $CarpetaDatos -Simular $true; if ($r.Hechos.Count -ne 0) { throw 'no bloqueó una clave prohibida' }; 'clave prohibida bloqueada' }
    Test-Paso 'Arranque' { $r = & $sbInicio -Ayuda $textoAyuda; '{0} programas, último arranque: {1} s' -f @($r.Items).Count, $r.ArranqueSeg }
    Test-Paso 'Diagnóstico' { $r = @(& $sbDiagnostico -Ayuda $textoAyuda); '{0} revisiones: {1}' -f $r.Count, (($r | Group-Object Estado | ForEach-Object { '{0} {1}' -f $_.Count, $_.Name }) -join ', ') }
    Test-Paso 'Acción de diagnóstico simulada' { & $sbAccionDiag -Ayuda $textoAyuda -Id 'Optimizar' -Simular $true }
    Test-Paso 'Procesos' { $r = @(& $sbProcesos -Ayuda $textoAyuda); '{0} programas de 100 MB o más' -f $r.Count }
    Test-Paso 'TurboPC simulado' { $r = & $sbTurbo -Ayuda $textoAyuda -Activar $true -PlanPrevio '' -Nombres @() -Simular $true; 'plan actual: ' + $r.PlanPrevio }
    Test-Paso 'Monitor: CPU y memoria' { $u = Get-UsoCpuRam; 'CPU {0}%, RAM {1}%' -f $u.Cpu, $u.RamPct }
    Test-Paso 'Monitor: red' { $a = Get-BytesRed; Start-Sleep -Seconds 1; $b = Get-BytesRed; 'bajada {0:N2} Mbps' -f (($b.Rx - $a.Rx) * 8 / 1e6) }
    Test-Paso 'Monitor: temperatura de discos' { $d = @(Get-TemperaturaDiscos); if ($d.Count -eq 0) { throw 'sin discos' }; ($d | ForEach-Object { '{0} {1} °C' -f $_.Disco, $_.Temp }) -join '; ' }
    Test-Paso 'Monitor: conexiones por programa' { $c = @(Get-ConexionesPorProceso); '{0} programas conectados' -f $c.Count }

    Test-Paso 'Módulos (sintaxis)' {
        $n = 0
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $RaizApp 'modulos') -Filter '*.ps1') {
            $err = $null; $tok = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$err)
            if ($err -and $err.Count -gt 0) { throw ('{0}: {1} (línea {2})' -f $f.Name, $err[0].Message, $err[0].Extent.StartLineNumber) }
            $n++
        }
        '{0} archivos sin errores de sintaxis' -f $n
    }
    Test-Paso 'Cola persistente (guardar y recuperar)' {
        $orig = $script:RutaCola
        $script:RutaCola = Join-Path $env:TEMP ('PCCare_cola_prueba_{0}.json' -f $PID)
        try {
            $a = New-RegistroTarea -Nombre 'Prueba limpieza' -Tipo 'LimpiarBasura' -Opciones 'x, y' -Parametros @{ Ids = [string[]]@('x', 'y'); Simular = $false; Ayuda = 'no se guarda' } -Modo 'Real' -Clave 'k1'
            $b = New-RegistroTarea -Nombre 'Prueba app' -Tipo 'ActualizarApp' -Opciones 'App' -Parametros @{ Id = 'Vendor.App'; Reinstalar = $false; Simular = $false } -Modo 'Real' -Clave 'k2'
            $c = New-RegistroTarea -Nombre 'Prueba analisis' -Tipo 'Seguridad' -Opciones '' -Parametros @{} -Modo 'Solo lectura' -Clave 'k3'
            $d = New-RegistroTarea -Nombre 'Prueba turbo' -Tipo 'Turbo' -Opciones '' -Parametros @{ Activar = $true } -Modo 'Real' -Clave 'k4'
            $a.Estado = 'Pendiente'; $b.Estado = 'En curso'; $c.Estado = 'En curso'; $d.Estado = 'En curso'
            $l = New-Object System.Collections.Generic.List[object]
            foreach ($r in $a, $b, $c, $d) { $l.Add($r) }
            if (-not (Save-Cola $l)) { throw ('no se pudo guardar la cola en ' + $script:RutaCola + ' -> ' + $script:UltimoErrorCola) }
            $l2 = Import-Cola
            Assert-Igual $l2.Count 4 'registros leídos'
            Assert-Igual (@($l2[0].Parametros['Ids']).Count) 2 'lista de Ids tras leer'
            Assert-Igual ([bool]$l2[0].Parametros.Contains('Ayuda')) $false 'la ayuda no se guarda'
            $n = Set-TareasInterrumpidas $l2
            Assert-Igual $n 3 'tareas interrumpidas'
            Assert-Igual ([string]$l2[0].Estado) 'Interrumpida' 'pendiente pasa a interrumpida'
            Assert-Igual ([string]$l2[2].Estado) 'Descartada' 'análisis de solo lectura se descarta'
            Assert-Igual (Get-ReanudarPorDefecto $l2[0]) $true 'limpieza segura se marca para reanudar'
            Assert-Igual (Get-ReanudarPorDefecto $l2[1]) $false 'actualización a medias NO se marca'
            Assert-Igual (Get-ReanudarPorDefecto $l2[3]) $false 'TurboPC nunca se reanuda sola'
            Set-Content -LiteralPath $script:RutaCola -Value '{ esto no es json' -Encoding UTF8
            $l3 = Import-Cola
            Assert-Igual $l3.Count 0 'archivo dañado se aparta y se empieza de cero'
            'guardar, leer, interrumpir y archivo dañado: correcto'
        }
        finally {
            Remove-Item -LiteralPath $script:RutaCola, ($script:RutaCola + '.danado'), ($script:RutaCola + '.tmp') -Force -ErrorAction SilentlyContinue
            $script:RutaCola = $orig
        }
    }
    Test-Paso 'Todas las tareas tienen política' {
        $nombres = 'sbSeguridad', 'sbRestauracion', 'sbAnalizarBasura', 'sbLimpiarBasura', 'sbGrandes', 'sbDuplicados', 'sbPapelera', 'sbAnalizarRegistro',
        'sbLimpiarRegistro', 'sbInicio', 'sbDiagnostico', 'sbAccionDiag', 'sbProcesos', 'sbTurbo', 'sbAnalizarApps', 'sbActualizarApp',
        'sbInstalarHerramienta', 'sbStore', 'sbAnalizarDrivers', 'sbInstalarDrivers', 'sbInformeAuditoria', 'sbRedDiagnostico', 'sbRedAplicar', 'sbRedReparar'
        foreach ($nom in $nombres) {
            $b = Get-Variable -Name $nom -ValueOnly
            if (-not $script:MetaTarea.ContainsKey($b)) { throw ('sin tipo: ' + $nom) }
            if (-not $script:PoliticaTipos.ContainsKey([string]$script:MetaTarea[$b])) { throw ('sin política: ' + $nom) }
        }
        '{0} tareas con tipo y política' -f @($nombres).Count
    }
    Test-Paso 'Aplicaciones (winget, solo lectura)' { $r = @(& $sbAnalizarApps -Ayuda $textoAyuda); '{0} apps, {1} con actualización' -f $r.Count, @($r | Where-Object { $_.Disponible }).Count }
    if ($Completa) {
        Test-Paso 'Drivers (Windows Update, solo lectura)' { $r = @(& $sbAnalizarDrivers -Ayuda $textoAyuda)[0]; '{0} pendientes, {1} instalados de terceros' -f @($r.Pendientes).Count, @($r.Instalados).Count }
        Test-Paso 'Informe del equipo (solo lectura)' {
            $r = @(& $sbInformeAuditoria -Ayuda $textoAyuda -Script (Join-Path $RaizApp 'modulos\AuditoriaPC.ps1') -Salida (Join-Path $env:TEMP 'PCCare_prueba_informe') -OmitirWU $true)[0]
            if (-not $r.Informe -or -not (Test-Path -LiteralPath $r.Informe)) { throw 'no se generó el informe' }
            'informe generado, {0} críticos' -f $r.Criticos
        }
        Test-Paso 'Diagnóstico de red (sin descarga)' {
            $r = @(& $sbRedDiagnostico -Ayuda $textoAyuda -Script (Join-Path $RaizApp 'modulos\OptimizarRed.ps1') -Carpeta (Join-Path $env:TEMP 'PCCare_prueba_red') -SinDescarga $true -MB 8)[0]
            if (-not $r.Informe) { throw 'informe de red vacío' }
            '{0} líneas, {1} mejoras propuestas' -f @($r.Informe -split "`n").Count, @($r.Cambios).Count
        }
    }

    $lineas.Add('')
    $lineas.Add(('RESULTADO: {0} errores. Ninguna prueba modifica el equipo (solo se escribe en la carpeta temporal).' -f $script:fallas))
    try { Set-Content -LiteralPath $rutaLog -Value $lineas -Encoding UTF8 }
    catch { $rutaLog = Join-Path $env:TEMP ('PCCare_autoprueba_{0}.log' -f $env:COMPUTERNAME); Set-Content -LiteralPath $rutaLog -Value $lineas -Encoding UTF8 }
    $lineas | ForEach-Object { Write-Host $_ }
    Write-Host ''
    Write-Host ('Informe guardado en ' + $rutaLog)
    Start-Sleep -Seconds 6
    exit $script:fallas
}

# ===========================================================================
# VENTANA Y DATOS
# ===========================================================================
$ventana = New-Ventana
$ui = @{}
foreach ($nodo in $xaml.SelectNodes("//*[@*[local-name()='Name']]")) {
    $nombre = $nodo.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    if ($nombre) { $c = $ventana.FindName($nombre); if ($c) { $ui[$nombre] = $c } }
}
$so = Get-CimInstance Win32_OperatingSystem
$equipo = Get-CimInstance Win32_ComputerSystem
$ui.txtEquipo.Text = '{0}  |  {1} {2}  |  {3}' -f $env:COMPUTERNAME, $equipo.Manufacturer, $equipo.Model, $so.Caption
$ui.txtVersion.Text = 'Versión ' + $VersionApp

function New-Tabla {
    param([string[]]$Columnas)
    $t = New-Object System.Data.DataTable
    [void]$t.Columns.Add('Sel', [bool])
    foreach ($c in $Columnas) {
        if ($c -eq 'Bytes') { $col = $t.Columns.Add($c, [double]); $col.DefaultValue = 0 }
        else { $col = $t.Columns.Add($c, [string]); $col.DefaultValue = '' }
    }
    return , $t
}
$tBasura = New-Tabla 'Id', 'Nombre', 'Archivos', 'Tamano', 'Bytes'
$tArch = New-Tabla 'Grupo', 'Nombre', 'Carpeta', 'Tamano', 'Bytes', 'Modificado', 'Nube', 'Ruta'
$tReg = New-Tabla 'Tipo', 'RutaPS', 'Valor', 'Detalle'
$tProc = New-Tabla 'Proceso', 'Instancias', 'MemoriaMB', 'Ventana'
$tInicio = New-Tabla 'Nombre', 'Comando', 'Origen', 'Aprobado', 'Original'
$tDiag = New-Tabla 'Id', 'Estado', 'Titulo', 'Detalle', 'Accion', 'TextoAccion'
$tDiscos = New-Tabla 'Disco', 'Tipo', 'Temp', 'Salud', 'Desgaste', 'Horas'
$tRed = New-Tabla 'Proceso', 'Conexiones', 'Destinos'
$tSeg = New-Tabla 'Estado', 'Titulo', 'Detalle'
$tHist = New-Tabla 'Fecha', 'Modo', 'Actividad'
$ui.gridBasura.ItemsSource = $tBasura.DefaultView
$ui.gridArch.ItemsSource = $tArch.DefaultView
$ui.gridReg.ItemsSource = $tReg.DefaultView
$ui.gridProc.ItemsSource = $tProc.DefaultView
$ui.gridInicio.ItemsSource = $tInicio.DefaultView
$ui.gridDiag.ItemsSource = $tDiag.DefaultView
$ui.gridDiscos.ItemsSource = $tDiscos.DefaultView
$ui.gridRed.ItemsSource = $tRed.DefaultView
$ui.gridSeg.ItemsSource = $tSeg.DefaultView
$ui.gridHist.ItemsSource = $tHist.DefaultView

$rutaHistorial = Join-Path $CarpetaDatos 'Historial.log'
try {
    # el historial no crece sin limite: si pasa de 1 MB se conservan las ultimas 2000 lineas
    if ((Test-Path -LiteralPath $rutaHistorial) -and ((Get-Item -LiteralPath $rutaHistorial).Length -gt 1MB)) {
        $resto = @(Get-Content -LiteralPath $rutaHistorial -Tail 2000 -Encoding UTF8)
        Set-Content -LiteralPath $rutaHistorial -Value $resto -Encoding UTF8
    }
}
catch { }
function Write-Registro {
    param([string]$Texto)
    $ui.txtLog.AppendText(('[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $Texto) + "`r`n")
    $ui.txtLog.ScrollToEnd()
    try {
        if (-not (Test-Path -LiteralPath $CarpetaDatos)) { New-Item -ItemType Directory -Path $CarpetaDatos -Force | Out-Null }
        $modo = 'REAL'
        if (Test-Simulacion) { $modo = 'SIM' }
        $limpio = ($Texto -replace '[\r\n|]+', ' ').Trim()
        Add-Content -LiteralPath $rutaHistorial -Value ('{0}|{1}|{2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $modo, $limpio) -Encoding UTF8
    }
    catch { }
}
function Update-Historial {
    $tHist.Rows.Clear()
    $ui.txtHistRuta.Text = 'Se guarda en ' + $rutaHistorial + '. Modo SIM = simulación, REAL = se aplicó en el equipo.'
    if (-not (Test-Path -LiteralPath $rutaHistorial)) { return }
    $lineas = @(Get-Content -LiteralPath $rutaHistorial -Tail 500 -Encoding UTF8)
    [array]::Reverse($lineas)
    foreach ($l in $lineas) {
        $p = $l -split '\|', 3
        if ($p.Count -eq 3) {
            $m = 'Real'
            if ($p[1] -eq 'SIM') { $m = 'Simulación' }
            [void]$tHist.Rows.Add($false, $p[0], $m, $p[2])
        }
    }
}
function Get-Marcadas {
    param([System.Data.DataTable]$Tabla)
    foreach ($f in $Tabla.Rows) { if ($f['Sel'] -eq $true) { $f } }
}
function Test-Simulacion { return [bool]$ui.chkSimulacion.IsChecked }
function Confirm-Accion {
    param([string]$Texto, [string]$Titulo = 'PC Care')
    if (Test-Simulacion) { $Texto = "MODO SIMULACIÓN: no se modificará nada, solo se mostrará el resultado esperado.`n`n" + $Texto }
    return ([System.Windows.MessageBox]::Show($Texto, $Titulo, 'YesNo', 'Question') -eq 'Yes')
}

# Configuracion por equipo: la simulacion queda activa hasta que el usuario la quite en ESE equipo
$rutaConfig = Join-Path $env:LOCALAPPDATA 'PCCare\config.json'
try {
    if (Test-Path -LiteralPath $rutaConfig) {
        $cfg = Get-Content -LiteralPath $rutaConfig -Raw | ConvertFrom-Json
        if ($cfg.Simulacion -eq $false) { $ui.chkSimulacion.IsChecked = $false }
    }
}
catch { }
function Update-ModoSim {
    $conv = New-Object System.Windows.Media.BrushConverter
    if (Test-Simulacion) {
        $ui.cajaSim.Background = $conv.ConvertFromString('#DDF0E2')
        $ui.chkSimulacion.Foreground = $conv.ConvertFromString('#12805A')
        $ui.chkSimulacion.Content = 'Simulación activa: no se modifica nada'
    }
    else {
        $ui.cajaSim.Background = $conv.ConvertFromString('#FCE9CF')
        $ui.chkSimulacion.Foreground = $conv.ConvertFromString('#8A4300')
        $ui.chkSimulacion.Content = 'MODO REAL: los cambios se aplican'
    }
}
Update-ModoSim
function Save-Config {
    try {
        New-Item -ItemType Directory -Path (Split-Path $rutaConfig) -Force | Out-Null
        @{ Simulacion = (Test-Simulacion) } | ConvertTo-Json | Set-Content -LiteralPath $rutaConfig -Encoding UTF8
    }
    catch { }
}

# ===========================================================================
# COLA DE TAREAS EN SEGUNDO PLANO
# ===========================================================================
$script:registros = Import-Cola
$script:interrumpidasAlAbrir = Set-TareasInterrumpidas $script:registros
[void](Save-Cola $script:registros)
$script:cola = New-Object System.Collections.Generic.List[object]
$script:actual = $null
$script:pausada = $false
$script:tablaSucia = $true
$script:ticks = 0
$tTareas = New-Tabla 'Id', 'Estado', 'Nombre', 'Opciones', 'Modo', 'Inicio', 'Duracion', 'Detalle'
$tInterr = New-Tabla 'Id', 'Nombre', 'Opciones', 'Previo', 'Nota'
$ui.gridTareas.ItemsSource = $tTareas.DefaultView
$ui.gridInterr.ItemsSource = $tInterr.DefaultView
$ui.txtTareasRuta.Text = 'Cada tarea queda registrada con las opciones que marcaste. Se guarda en ' + $script:RutaCola + '. Si PC Care se cierra a mitad de una tarea, al abrirlo de nuevo puedes reanudarla desde aquí.'

function Get-AhoraTexto { return (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }

function Get-TextoEspera {
    # Texto para mostrar en una pagina justo despues de encolar: si hay tareas delante, avisa que esta en espera.
    param([string]$Mientras)
    $delante = [int]$script:cola.Count - 1
    $ahora = ''
    if ($script:actual) { $delante++; $ahora = [string]$script:actual.Reg.Nombre }
    if ($delante -le 0) { return $Mientras }
    return ('EN COLA: esperan {0} tareas antes. Ahora se está ejecutando: {1}.{2}Cuando terminen empieza esta. Puedes verlo en la página Tareas.' -f $delante, $ahora, "`r`n")
}

function Add-Tarea {
    param([string]$Nombre, [scriptblock]$Codigo, [hashtable]$Parametros = @{}, [scriptblock]$AlTerminar, $Contexto, [string]$Opciones = '', [scriptblock]$AlIniciar)
    $tipo = ''
    if ($script:MetaTarea.ContainsKey($Codigo)) { $tipo = [string]$script:MetaTarea[$Codigo] }
    $modo = 'Solo lectura'
    if ($Parametros.ContainsKey('Simular')) {
        if ([bool]$Parametros['Simular']) { $modo = 'Simulación' } else { $modo = 'Real' }
    }
    $clave = Get-ClaveTarea -Nombre $Nombre -Tipo $tipo -Opciones $Opciones -Parametros $Parametros
    # no se encola dos veces la misma tarea con las mismas opciones si ya es la ultima de la cola
    $ultima = $null
    if ($script:cola.Count -gt 0) { $ultima = $script:cola[$script:cola.Count - 1] }
    elseif ($script:actual) { $ultima = $script:actual }
    if ($ultima -and $ultima.Reg.Clave -eq $clave) { return }
    $reg = New-RegistroTarea -Nombre $Nombre -Tipo $tipo -Opciones $Opciones -Parametros $Parametros -Modo $modo -Clave $clave
    $script:registros.Add($reg)
    while ($script:registros.Count -gt $script:MaxRegistros -and @('Pendiente', 'En curso', 'Interrumpida') -notcontains [string]$script:registros[0].Estado) { $script:registros.RemoveAt(0) }
    $Parametros['Ayuda'] = $textoAyuda
    $script:cola.Add(@{ Reg = $reg; Codigo = $Codigo; Parametros = $Parametros; AlTerminar = $AlTerminar; AlIniciar = $AlIniciar; Contexto = $Contexto; Cancelada = $false })
    [void](Save-Cola $script:registros)
    $script:tablaSucia = $true
}

function Complete-TareaActual {
    $t = $script:actual
    $script:actual = $null
    $resultado = $null
    $fallo = $null
    try { $resultado = @($t.PS.EndInvoke($t.Mango)) } catch { $fallo = $_.Exception.Message }
    foreach ($err in $t.PS.Streams.Error) { Write-Registro ('AVISO en "{0}": {1}' -f $t.Reg.Nombre, [string]$err) }
    $t.PS.Dispose()
    $reg = $t.Reg
    $reg.Fin = Get-AhoraTexto
    if ($fallo -and $t.Cancelada) {
        $reg.Estado = 'Cancelada'
        $reg.Detalle = 'Cancelada por el usuario'
        Write-Registro ('Tarea cancelada por el usuario: ' + $reg.Nombre)
    }
    elseif ($fallo) {
        $reg.Estado = 'Error'
        $reg.Detalle = Get-TextoCorto $fallo 200
        Write-Registro ('ERROR en "{0}": {1}' -f $reg.Nombre, $fallo)
        $ui.expLog.IsExpanded = $true
    }
    else { $reg.Estado = 'Completada' }
    [void](Save-Cola $script:registros)
    $script:tablaSucia = $true
    if ($t.AlTerminar) {
        try { & $t.AlTerminar $resultado $t.Contexto $fallo }
        catch { Write-Registro ('ERROR al mostrar el resultado de "{0}": {1}' -f $reg.Nombre, $_.Exception.Message) }
    }
}

function Update-NavTareas {
    $n = $script:cola.Count
    if ($script:actual) { $n++ }
    $txt = 'Tareas'
    if ($n -gt 0) { $txt = 'Tareas ({0})' -f $n }
    if ([string]$ui.navTareas.Content -ne $txt) { $ui.navTareas.Content = $txt }
}

function Update-TablaTareas {
    $script:tablaSucia = $false
    $tTareas.Rows.Clear()
    $n = 0
    for ($i = $script:registros.Count - 1; $i -ge 0 -and $n -lt 200; $i--) {
        $r = $script:registros[$i]
        $dur = ''
        if (@('En curso', 'Completada', 'Error', 'Cancelada') -contains [string]$r.Estado) { $dur = Get-TextoDuracion ([string]$r.Inicio) ([string]$r.Fin) }
        [void]$tTareas.Rows.Add($false, [string]$r.Id, [string]$r.Estado, [string]$r.Nombre, [string]$r.Opciones, [string]$r.Modo, [string]$r.Inicio, $dur, [string]$r.Detalle)
        $n++
    }
    if ($script:actual) {
        $r = $script:actual.Reg
        $txt = '{0}' -f $r.Nombre
        $txt += "`nModo: {0}. Lleva {1}." -f $r.Modo, (Get-TextoDuracion ([string]$r.Inicio) '')
        if ($r.Opciones) { $txt += "`nOpciones: " + $r.Opciones }
        if ($script:cola.Count -gt 0) { $txt += "`nEn espera ({0}): {1}" -f $script:cola.Count, (($script:cola | ForEach-Object { $_.Reg.Nombre }) -join '; ') }
        $ui.txtAhora.Text = $txt
    }
    elseif ($script:cola.Count -gt 0) {
        $ui.txtAhora.Text = 'Cola en pausa. Esperan {0} tareas: {1}' -f $script:cola.Count, (($script:cola | ForEach-Object { $_.Reg.Nombre }) -join '; ')
    }
    else { $ui.txtAhora.Text = 'Nada en ejecución.' }
}

function Update-ResumenSeleccion {
    $l = New-Object System.Collections.Generic.List[string]
    $f = @(Get-Marcadas $tBasura)
    if ($f.Count -gt 0) { $l.Add('Limpieza de basura: ' + (($f | ForEach-Object { [string]$_['Nombre'] }) -join ', ')) }
    $f = @(Get-Marcadas $tArch)
    if ($f.Count -gt 0) { $l.Add('Archivos para la Papelera: {0}' -f $f.Count) }
    $f = @(Get-Marcadas $tReg)
    if ($f.Count -gt 0) { $l.Add('Entradas de registro por limpiar: {0}' -f $f.Count) }
    $f = @(Get-Marcadas $tProc)
    if ($f.Count -gt 0) { $l.Add('Programas que cerraría TurboPC: ' + (($f | ForEach-Object { [string]$_['Proceso'] }) -join ', ')) }
    $cambios = @(foreach ($r in $tInicio.Rows) { if ([string][bool]$r['Sel'] -ne [string]$r['Original']) { $r } })
    if ($cambios.Count -gt 0) { $l.Add('Cambios de arranque sin aplicar: {0}' -f $cambios.Count) }
    $f = @(Get-Marcadas $tApps)
    if ($f.Count -gt 0) { $l.Add('Aplicaciones marcadas: ' + (($f | ForEach-Object { [string]$_['Nombre'] }) -join ', ')) }
    $f = @(Get-Marcadas $tDrvPend)
    if ($f.Count -gt 0) { $l.Add('Drivers marcados: ' + (($f | ForEach-Object { [string]$_['Titulo'] }) -join ', ')) }
    $f = @(Get-Marcadas $tCambiosRed)
    if ($f.Count -gt 0) { $l.Add('Mejoras de red marcadas: ' + (($f | ForEach-Object { [string]$_['Nombre'] }) -join ', ')) }
    if ($l.Count -eq 0) { $ui.txtSeleccion.Text = 'No hay nada marcado. Lo que marques en las páginas queda aquí hasta que pulses el botón que lo ejecuta.' }
    else { $ui.txtSeleccion.Text = ($l -join "`n") }
}

function Update-Interrumpidas {
    $tInterr.Rows.Clear()
    foreach ($r in $script:registros) {
        if ([string]$r.Estado -ne 'Interrumpida') { continue }
        switch ([string]$r.Politica) {
            'No' { $nota = 'No se reanuda sola: repítela a mano si la necesitas.' }
            'Confirmar' {
                if ([string]$r.EstadoPrevio -eq 'En curso') { $nota = 'Estaba a medias. Revisa el resultado antes de repetirla.' }
                else { $nota = 'No llegó a empezar.' }
            }
            default { $nota = 'Se puede repetir sin riesgo.' }
        }
        if ([string]$r.Modo -eq 'Simulación') { $nota = 'Era una simulación. ' + $nota }
        [void]$tInterr.Rows.Add((Get-ReanudarPorDefecto $r), [string]$r.Id, [string]$r.Nombre, [string]$r.Opciones, [string]$r.EstadoPrevio, $nota)
    }
    if ($tInterr.Rows.Count -gt 0) { $ui.cajaInterrumpidas.Visibility = 'Visible' } else { $ui.cajaInterrumpidas.Visibility = 'Collapsed' }
}

function Clear-ColaPendiente {
    foreach ($t in @($script:cola)) {
        $t.Reg.Estado = 'Cancelada'
        $t.Reg.Detalle = 'Quitada de la cola'
        $t.Reg.Fin = Get-AhoraTexto
    }
    $script:cola.Clear()
    [void](Save-Cola $script:registros)
    $script:tablaSucia = $true
}

function Invoke-ReanudarTareas {
    $marcadas = @(Get-Marcadas $tInterr)
    $n = 0
    foreach ($f in $marcadas) {
        $reg = $script:registros | Where-Object { [string]$_.Id -eq [string]$f['Id'] } | Select-Object -First 1
        if (-not $reg) { continue }
        $tipo = [string]$reg.Tipo
        if ([string]$reg.Politica -eq 'No' -or -not $script:Reanudadores.ContainsKey($tipo)) {
            $reg.Estado = 'Descartada'
            $reg.Detalle = 'No se reanuda sola; repítela a mano'
            continue
        }
        if ([string]$reg.Modo -eq 'Simulación' -and -not (Test-Simulacion)) {
            $reg.Estado = 'Descartada'
            $reg.Detalle = 'Era una simulación; no se repite en modo real'
            continue
        }
        try {
            $reg.Estado = 'Reanudada'
            $reg.Detalle = 'Reanudada desde la página Tareas'
            & $script:Reanudadores[$tipo] $reg.Parametros $reg
            $n++
        }
        catch { Write-Registro ('No se pudo reanudar "{0}": {1}' -f $reg.Nombre, $_.Exception.Message) }
    }
    [void](Save-Cola $script:registros)
    Update-Interrumpidas
    $script:tablaSucia = $true
    Write-Registro ('Tareas reanudadas: {0}' -f $n)
}

function Invoke-DescartarInterrumpidas {
    foreach ($r in $script:registros) {
        if ([string]$r.Estado -eq 'Interrumpida') {
            $r.Estado = 'Descartada'
            $r.Detalle = 'Descartada por el usuario'
        }
    }
    [void](Save-Cola $script:registros)
    Update-Interrumpidas
    $script:tablaSucia = $true
}

$reloj = New-Object System.Windows.Threading.DispatcherTimer
$reloj.Interval = [TimeSpan]::FromMilliseconds(300)
$reloj.Add_Tick({
        try {
            $script:ticks++
            if ($script:actual -and $script:actual.Mango.IsCompleted) { Complete-TareaActual }
            if (-not $script:actual -and $script:cola.Count -gt 0 -and -not $script:pausada) {
                $t = $script:cola[0]
                $script:cola.RemoveAt(0)
                $ps = [powershell]::Create()
                [void]$ps.AddScript($t.Codigo.ToString())
                [void]$ps.AddParameters($t.Parametros)
                $t.PS = $ps
                $t.Reg.Estado = 'En curso'
                $t.Reg.Inicio = Get-AhoraTexto
                [void](Save-Cola $script:registros)
                $t.Mango = $ps.BeginInvoke()
                $script:actual = $t
                $script:tablaSucia = $true
                Write-Registro ('Inicio: ' + $t.Reg.Nombre)
                if ($t.AlIniciar) { try { & $t.AlIniciar } catch { } }
            }
            $ocupado = [bool]$script:actual
            $tipoActual = ''
            if ($ocupado) { $tipoActual = [string]$script:actual.Reg.Tipo }
            $ui.btnCancelar.IsEnabled = (($ocupado -and $tipoActual -ne 'Turbo' -and -not $script:actual.Cancelada) -or ($script:cola.Count -gt 0))
            $ui.barra.IsIndeterminate = $ocupado
            if ($ocupado) {
                $resto = ''
                if ($script:cola.Count -gt 0) { $resto = ' (en cola: {0})' -f $script:cola.Count }
                $ui.txtEstado.Text = $script:actual.Reg.Nombre + $resto
            }
            elseif ($script:pausada -and $script:cola.Count -gt 0) { $ui.txtEstado.Text = 'Cola en pausa: {0} tareas esperando' -f $script:cola.Count }
            else { $ui.txtEstado.Text = 'Listo' }
            Update-NavTareas
            if ($ui.vTareas.Visibility -eq 'Visible' -and ($script:tablaSucia -or ($ocupado -and ($script:ticks % 7) -eq 0))) { Update-TablaTareas }
        }
        catch { Write-Registro ('ERROR interno: ' + $_.Exception.Message) }
    })

$relojSel = New-Object System.Windows.Threading.DispatcherTimer
$relojSel.Interval = [TimeSpan]::FromSeconds(2)
$relojSel.Add_Tick({ try { if ($ui.vTareas.Visibility -eq 'Visible') { Update-ResumenSeleccion } } catch { } })


# ===========================================================================
# PANEL
# ===========================================================================
$script:basuraBytes = [double]0
function Update-Puntaje {
    if ($tDiag.Rows.Count -eq 0) { return }
    $ok = 0; $tot = 0; $crit = 0; $aler = 0
    $pend = New-Object System.Collections.Generic.List[string]
    foreach ($tabla in @($tDiag, $tSeg)) {
        foreach ($f in $tabla.Rows) {
            $e = [string]$f['Estado']
            if ($e -eq 'Al día') { $ok++; $tot++ }
            elseif ($e -eq 'Crítico') { $crit++; $tot++; $pend.Add([string]$f['Titulo']) }
            elseif ($e -eq 'Alerta') { $aler++; $tot++; $pend.Add([string]$f['Titulo']) }
        }
    }
    $ui.txtPuntaje.Text = '{0}/{1}' -f $ok, $tot
    if ($crit -gt 0) { $ui.txtEstadoTitulo.Text = 'El equipo requiere atención' }
    elseif ($aler -gt 0) { $ui.txtEstadoTitulo.Text = 'El equipo es mejorable' }
    else { $ui.txtEstadoTitulo.Text = 'El equipo está en buen estado' }
    if ($pend.Count -gt 0) { $ui.txtEstadoDesc.Text = 'Por revisar: ' + (($pend | Select-Object -First 5) -join ', ') + '. Se cuentan los controles de Rendimiento (diagnóstico) y de Seguridad.' }
    else { $ui.txtEstadoDesc.Text = 'Todos los controles de diagnóstico y seguridad están en orden.' }
    $ui.txtTProblemas.Text = [string]($crit + $aler)
    $ui.txtTProblemasD.Text = '{0} críticos, {1} alertas. Detalle en Rendimiento y Seguridad.' -f $crit, $aler
}

function Start-Seguridad {
    Add-Tarea 'Revisando la seguridad de Windows' $sbSeguridad @{} {
        param($res, $ctx, $fallo)
        if ($fallo) { return }
        $tSeg.Rows.Clear()
        foreach ($s in $res) { [void]$tSeg.Rows.Add($false, [string]$s.Estado, [string]$s.Nombre, [string]$s.Detalle) }
        Update-Puntaje
    }
}
function Start-LecturaRestauracion {
    Add-Tarea 'Leyendo puntos de restauración' $sbRestauracion @{} {
        param($res, $ctx, $fallo)
        if ($res -and $res[0]) { $ui.txtChipRestauracion.Text = 'Restauración: ' + [string]$res[0] }
        else { $ui.txtChipRestauracion.Text = 'Sin puntos de restauración' }
    }
}

# ===========================================================================
# LIMPIEZA
# ===========================================================================
function Update-TotalBasura {
    $sel = [double]0
    foreach ($f in (Get-Marcadas $tBasura)) { $sel += [double]$f['Bytes'] }
    $ui.txtBasuraTotal.Text = 'Seleccionado: ' + (Format-Tamano $sel)
}
function Start-AnalisisBasura {
    Add-Tarea 'Analizando archivos basura' $sbAnalizarBasura @{} {
        param($res, $ctx, $fallo)
        if ($fallo) { return }
        $script:cargando = $true
        $tBasura.Rows.Clear()
        $total = [double]0
        foreach ($c in $res) {
            $marcar = ($c.Bytes -gt 0 -and $c.Id -ne 'Papelera')
            [void]$tBasura.Rows.Add($marcar, $c.Id, $c.Nombre, [string]$c.Archivos, (Format-Tamano $c.Bytes), [double]$c.Bytes)
            $total += $c.Bytes
        }
        $script:cargando = $false
        $script:basuraBytes = $total
        $ui.txtTBasura.Text = Format-Tamano $total
        $ui.txtTBasuraD.Text = 'Temporales, cachés, informes de error y Papelera'
        Update-TotalBasura
        Update-Puntaje
    }
}
function Add-TareaLimpiezaBasura {
    param([string[]]$Ids, [string]$Opciones)
    Add-Tarea 'Limpiando archivos basura' $sbLimpiarBasura @{ Ids = [string[]]$Ids; Simular = (Test-Simulacion) } {
        param($res, $ctx, $fallo)
        if ($fallo -or -not $res) { return }
        foreach ($m in $res[0].Mensajes) { Write-Registro ('   ' + $m) }
        if ($res[0].Simulado) { Write-Registro ('SIMULACIÓN: se liberarían ' + (Format-Tamano $res[0].Bytes)) }
        else { Write-Registro ('Espacio liberado: ' + (Format-Tamano $res[0].Bytes)) }
        $ui.expLog.IsExpanded = $true
    } -Opciones $Opciones
}
function Start-LimpiezaBasura {
    param([switch]$SinConfirmar)
    $filas = @(Get-Marcadas $tBasura)
    if ($filas.Count -eq 0) { return }
    $ids = @($filas | ForEach-Object { [string]$_['Id'] })
    $nombres = ($filas | ForEach-Object { [string]$_['Nombre'] }) -join ', '
    if (-not $SinConfirmar) {
        $lista = ($filas | ForEach-Object { '  - {0}: {1}' -f $_['Nombre'], $_['Tamano'] }) -join "`n"
        if (-not (Confirm-Accion ("Se eliminarán de forma definitiva:`n`n{0}`n`n¿Continuar?" -f $lista) 'Limpiar archivos basura')) { return }
    }
    Add-TareaLimpiezaBasura -Ids ([string[]]$ids) -Opciones $nombres
    Start-AnalisisBasura
}

function Update-SeleccionArch {
    $n = 0; $b = [double]0
    foreach ($f in (Get-Marcadas $tArch)) { $n++; $b += [double]$f['Bytes'] }
    $ui.txtArchSel.Text = '{0} archivos en lista. Seleccionados: {1} ({2}).' -f $tArch.Rows.Count, $n, (Format-Tamano $b)
}
function Get-MinMB {
    switch ($ui.cmbMin.SelectedIndex) { 0 { return 5 } 2 { return 500 } 3 { return 1024 } default { return 100 } }
}
$alLlenarArchivos = {
    param($res, $tipo, $fallo)
    if ($fallo) { return }
    $script:cargando = $true
    $tArch.Rows.Clear()
    $total = [double]0
    foreach ($a in $res) {
        [void]$tArch.Rows.Add($false, $a.Grupo, $a.Nombre, $a.Carpeta, (Format-Tamano $a.Bytes), [double]$a.Bytes, $a.Modificado, $a.Nube, $a.Ruta)
        $total += $a.Bytes
    }
    $script:cargando = $false
    $ui.txtTArch.Text = Format-Tamano $total
    $ui.txtTArchD.Text = '{0}: {1} archivos' -f $tipo, $tArch.Rows.Count
    Update-SeleccionArch
    Write-Registro ('{0}: {1} archivos, {2}.' -f $tipo, $tArch.Rows.Count, (Format-Tamano $total))
}

function Start-AnalisisRegistro {
    Add-Tarea 'Analizando registro' $sbAnalizarRegistro @{} {
        param($res, $ctx, $fallo)
        if ($fallo) { return }
        $tReg.Rows.Clear()
        foreach ($r in $res) { [void]$tReg.Rows.Add($false, $r.Tipo, $r.RutaPS, $r.Valor, $r.Detalle) }
        Write-Registro ('Registro: {0} entradas inválidas comprobadas.' -f $tReg.Rows.Count)
    }
}

# ===========================================================================
# RENDIMIENTO
# ===========================================================================
function Start-AnalisisInicio {
    Add-Tarea 'Analizando programas de inicio' $sbInicio @{} {
        param($res, $ctx, $fallo)
        if ($fallo -or -not $res) { return }
        $tInicio.Rows.Clear()
        $activos = 0
        foreach ($i in $res[0].Items) {
            if ($i.Activo) { $activos++ }
            [void]$tInicio.Rows.Add([bool]$i.Activo, $i.Nombre, $i.Comando, $i.Origen, $i.Aprobado, [string][bool]$i.Activo)
        }
        if ($res[0].ArranqueSeg) { $ui.txtTArranque.Text = '{0} s' -f $res[0].ArranqueSeg } else { $ui.txtTArranque.Text = [string]$activos }
        $ui.txtTArranqueD.Text = '{0} programas inician con Windows' -f $activos
    }
}
function Set-InicioActivo {
    param([string]$ClaveAprobado, [string]$Nombre, [bool]$Activo)
    if ($ClaveAprobado -notmatch '\\Explorer\\StartupApproved\\(Run|Run32|StartupFolder)$') { throw 'Clave no permitida: ' + $ClaveAprobado }
    if (-not (Test-Path -LiteralPath $ClaveAprobado)) { New-Item -Path $ClaveAprobado -Force | Out-Null }
    $b = New-Object byte[] 12
    if ($Activo) { $b[0] = 2 }
    else { $b[0] = 3; [System.BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()).CopyTo($b, 4) }
    Set-ItemProperty -LiteralPath $ClaveAprobado -Name $Nombre -Value $b -Type Binary
}

function Start-Diagnostico {
    Add-Tarea 'Diagnosticando problemas comunes' $sbDiagnostico @{} {
        param($res, $ctx, $fallo)
        if ($fallo) { return }
        $tDiag.Rows.Clear()
        $mapa = @{ CRITICO = 'Crítico'; ALERTA = 'Alerta'; OK = 'Al día'; INFO = 'Info' }
        foreach ($d in $res) { [void]$tDiag.Rows.Add($false, $d.Id, $mapa[[string]$d.Estado], $d.Titulo, $d.Detalle, $d.Accion, $d.TextoAccion) }
        Update-Puntaje
    }
}
function Add-TareaAccion {
    param([string]$Id, [string]$Nombre, [string]$Opciones)
    Add-Tarea $Nombre $sbAccionDiag @{ Id = $Id; Simular = (Test-Simulacion) } {
        param($res, $ctx, $fallo)
        if ($res) { Write-Registro ('   ' + [string]$res[0]) }
        $ui.expLog.IsExpanded = $true
    } -Opciones $Opciones
}
function Start-Procesos {
    Add-Tarea 'Listando programas en memoria' $sbProcesos @{} {
        param($res, $ctx, $fallo)
        if ($fallo) { return }
        $tProc.Rows.Clear()
        foreach ($p in $res) { [void]$tProc.Rows.Add($false, $p.Proceso, [string]$p.Instancias, [string]$p.MemoriaMB, $p.Ventana) }
    }
}

$script:turboActivo = $false
$script:planPrevio = ''
function Switch-Turbo {
    if ($script:turboActivo) {
        Add-Tarea 'Desactivando TurboPC' $sbTurbo @{ Activar = $false; PlanPrevio = $script:planPrevio; Nombres = [string[]]@(); Simular = (Test-Simulacion) } {
            param($res, $ctx, $fallo)
            $script:turboActivo = $false
            $script:planPrevio = ''
            $ui.btnTurbo.Content = 'Activar TurboPC'; $ui.btnTurbo2.Content = 'Activar TurboPC'
            if ($res) { foreach ($m in $res[0].Mensajes) { Write-Registro ('   ' + $m) } }
            $ui.txtTurbo.Text = 'TurboPC desactivado.'
        } -Opciones 'Volver al plan de energía anterior'
        return
    }
    $nombres = @(Get-Marcadas $tProc | ForEach-Object { [string]$_['Proceso'] })
    $texto = 'TurboPC pasará el equipo a alto rendimiento y liberará memoria RAM.'
    if ($nombres.Count -gt 0) { $texto += "`n`nAdemás cerrará estos programas (guarda tu trabajo antes):`n  - " + ($nombres -join "`n  - ") }
    else { $texto += "`n`nNo cerrará ningún programa. Si quieres que cierre alguno, márcalo antes en Rendimiento." }
    if (-not (Confirm-Accion ($texto + "`n`n¿Activar?") 'TurboPC')) { return }
    Add-Tarea 'Activando TurboPC' $sbTurbo @{ Activar = $true; PlanPrevio = ''; Nombres = [string[]]$nombres; Simular = (Test-Simulacion) } {
        param($res, $ctx, $fallo)
        if ($fallo -or -not $res) { return }
        foreach ($m in $res[0].Mensajes) { Write-Registro ('   ' + $m) }
        if (Test-Simulacion) { $ui.txtTurbo.Text = 'Simulación de TurboPC completada. Revisa el registro de actividad.'; $ui.expLog.IsExpanded = $true; return }
        $script:turboActivo = $true
        $script:planPrevio = [string]$res[0].PlanPrevio
        $ui.btnTurbo.Content = 'Desactivar TurboPC'; $ui.btnTurbo2.Content = 'Desactivar TurboPC'
        $ui.txtTurbo.Text = 'TurboPC activo. RAM liberada: ' + (Format-Tamano $res[0].LiberadoBytes)
    } -Opciones $(if ($nombres.Count -gt 0) { 'Cerrar: ' + ($nombres -join ', ') } else { 'Alto rendimiento y liberar RAM' })
    Start-Procesos
}

# ===========================================================================
# MONITOR: hilo de muestreo + refresco de la interfaz cada segundo
# ===========================================================================
$estado = [hashtable]::Synchronized(@{ Activo = $true; Cpu = 0; RamPct = 0; RamTotal = [double]0; RamLibre = [double]0; BajadaMbps = [double]0; SubidaMbps = [double]0; Discos = @(); Conexiones = @(); Marca = -1; Error = '' })
$psMuestreo = [powershell]::Create()
[void]$psMuestreo.AddScript($sbMuestreo.ToString())
[void]$psMuestreo.AddParameters(@{ Ayuda = $textoAyuda; Estado = $estado })
$hBajada = New-Object 'System.Collections.Generic.List[double]'
$hSubida = New-Object 'System.Collections.Generic.List[double]'
$hTemp = New-Object 'System.Collections.Generic.List[double]'
$script:ultimaMarca = -1

function Set-Linea {
    param($Linea, $Lienzo, $Valores, [double]$Maximo)
    $w = $Lienzo.ActualWidth; $h = $Lienzo.ActualHeight
    if ($w -le 0 -or $h -le 0 -or $Valores.Count -lt 2) { return }
    if ($Maximo -le 0) { $Maximo = 1 }
    $pts = New-Object System.Windows.Media.PointCollection
    for ($i = 0; $i -lt $Valores.Count; $i++) {
        $x = $w * $i / 59
        $y = $h - 3 - (($h - 6) * [math]::Min(1, [double]$Valores[$i] / $Maximo))
        $pts.Add((New-Object System.Windows.Point($x, $y)))
    }
    $Linea.Points = $pts
}
function Add-Muestra {
    param($Lista, [double]$Valor)
    $Lista.Add($Valor)
    while ($Lista.Count -gt 60) { $Lista.RemoveAt(0) }
}
function Format-Mbps {
    param([double]$Mbps)
    if ($Mbps -ge 1) { return ('{0:N1} Mbps' -f $Mbps) }
    return ('{0:N0} Kbps' -f ($Mbps * 1000))
}

$relojMonitor = New-Object System.Windows.Threading.DispatcherTimer
$relojMonitor.Interval = [TimeSpan]::FromSeconds(1)
$relojMonitor.Add_Tick({
        try {
            if ([int]$estado.Marca -eq $script:ultimaMarca) { return }
            $script:ultimaMarca = [int]$estado.Marca
            $ui.txtCpu.Text = '{0}%' -f $estado.Cpu
            $ui.pbCpu.Value = [double]$estado.Cpu
            $ui.txtRam.Text = '{0}%' -f $estado.RamPct
            $ui.pbRam.Value = [double]$estado.RamPct
            $ui.txtRamD.Text = '{0} de {1} en uso' -f (Format-Tamano ($estado.RamTotal - $estado.RamLibre)), (Format-Tamano $estado.RamTotal)
            $bajada = [double]$estado.BajadaMbps; $subida = [double]$estado.SubidaMbps
            $ui.txtRedP.Text = '↓ ' + (Format-Mbps $bajada)
            $ui.txtRedPD.Text = '↑ ' + (Format-Mbps $subida)
            $ui.txtBajada.Text = '↓ ' + (Format-Mbps $bajada)
            $ui.txtSubida.Text = '↑ ' + (Format-Mbps $subida)
            Add-Muestra $hBajada $bajada
            Add-Muestra $hSubida $subida
            $max = [math]::Max(0.1, [math]::Max(($hBajada | Measure-Object -Maximum).Maximum, ($hSubida | Measure-Object -Maximum).Maximum))
            Set-Linea $ui.lnBajada $ui.cvRed $hBajada $max
            Set-Linea $ui.lnSubida $ui.cvRed $hSubida $max
            $ui.txtRedEscala.Text = 'Último minuto, escala hasta {0}. Línea continua: descarga. Línea punteada: subida.' -f (Format-Mbps $max)

            $discos = @($estado.Discos)
            $conTemp = @($discos | Where-Object { $null -ne $_.Temp })
            if ($conTemp.Count -gt 0) {
                $t = [double]($conTemp | Measure-Object Temp -Maximum).Maximum
                $ui.txtTempP.Text = '{0} °C' -f $t
                $ui.pbTemp.Value = [math]::Min(100, $t)
                $ui.txtTempM.Text = '{0} °C' -f $t
                if ($t -ge 70) { $ui.txtTempMD.Text = 'Crítico: revisa ventilación y carga del equipo' }
                elseif ($t -ge 55) { $ui.txtTempMD.Text = 'Atención: temperatura elevada' }
                else { $ui.txtTempMD.Text = 'Rango normal' }
                Add-Muestra $hTemp $t
                Set-Linea $ui.lnTemp $ui.cvTemp $hTemp 90
            }
            elseif ($discos.Count -gt 0) {
                $ui.txtTempP.Text = 'No disponible'
                $ui.txtTempM.Text = 'No disponible'
                $ui.txtTempMD.Text = 'Este disco no informa su temperatura a Windows'
            }
            if ($discos.Count -ne $tDiscos.Rows.Count -or ($script:ultimaMarca % 10) -eq 0) {
                $tDiscos.Rows.Clear()
                foreach ($d in $discos) { [void]$tDiscos.Rows.Add($false, $d.Disco, $d.Tipo, [string]$d.Temp, $d.Salud, [string]$d.Desgaste, [string]$d.Horas) }
            }
            if (($script:ultimaMarca % 6) -eq 0 -and $ui.vMonitor.Visibility -eq 'Visible') {
                $tRed.Rows.Clear()
                foreach ($c in @($estado.Conexiones)) { [void]$tRed.Rows.Add($false, $c.Proceso, [string]$c.Conexiones, [string]$c.Destinos) }
            }
        }
        catch { }
    })

# ===========================================================================
# PAGINAS ACTUALIZACIONES, INFORME Y RED (archivos en "modulos")
# ===========================================================================
foreach ($nombreMod in 'UI_Actualizaciones.ps1', 'UI_InformeRed.ps1') {
    $rutaMod = Join-Path $RaizApp ('modulos\' + $nombreMod)
    if (-not (Test-Path -LiteralPath $rutaMod)) {
        [void][System.Windows.MessageBox]::Show(('Falta el archivo modulos\{0}.' -f $nombreMod), 'PC Care')
        exit 1
    }
    . $rutaMod
}

# ===========================================================================
# EVENTOS
# ===========================================================================
function Show-Vista {
    param([string]$Nombre)
    foreach ($v in 'vPanel', 'vLimpieza', 'vRend', 'vMonitor', 'vSeg', 'vAct', 'vRed', 'vInforme', 'vTareas', 'vHist') {
        if ($v -eq $Nombre) { $ui[$v].Visibility = 'Visible' } else { $ui[$v].Visibility = 'Collapsed' }
    }
    $titulos = @{ vPanel = 'Panel'; vLimpieza = 'Limpieza'; vRend = 'Rendimiento'; vMonitor = 'Monitor'; vSeg = 'Seguridad'; vAct = 'Actualizaciones'; vRed = 'Red'; vInforme = 'Informe del equipo'; vTareas = 'Tareas'; vHist = 'Historial' }
    $ui.txtMigas.Text = 'PC Care  /  ' + $titulos[$Nombre]
    if ($Nombre -eq 'vHist') { Update-Historial }
    if ($Nombre -eq 'vTareas') { Update-TablaTareas; Update-ResumenSeleccion; Update-Interrumpidas }
}
$ui.navPanel.Add_Checked({ Show-Vista 'vPanel' })
$ui.navLimpieza.Add_Checked({ Show-Vista 'vLimpieza' })
$ui.navRend.Add_Checked({ Show-Vista 'vRend' })
$ui.navMonitor.Add_Checked({ Show-Vista 'vMonitor' })
$ui.navSeg.Add_Checked({ Show-Vista 'vSeg' })
$ui.navAct.Add_Checked({ Show-Vista 'vAct' })
$ui.navRed.Add_Checked({ Show-Vista 'vRed' })
$ui.navInforme.Add_Checked({ Show-Vista 'vInforme' })
$ui.navTareas.Add_Checked({ Show-Vista 'vTareas' })
$ui.navHist.Add_Checked({ Show-Vista 'vHist' })

# Pagina Tareas
$ui.btnReanudar.Add_Click({ Invoke-ReanudarTareas })
$ui.btnDescartar.Add_Click({ Invoke-DescartarInterrumpidas })
$ui.btnPausar.Add_Click({
        $script:pausada = -not $script:pausada
        if ($script:pausada) { $ui.btnPausar.Content = 'Reanudar cola'; Write-Registro 'Cola en pausa: la tarea en curso termina y las siguientes esperan.' }
        else { $ui.btnPausar.Content = 'Pausar cola'; Write-Registro 'Cola reanudada.' }
        $script:tablaSucia = $true
    })
$ui.btnQuitarPend.Add_Click({
        if ($script:cola.Count -eq 0) { return }
        $r = [System.Windows.MessageBox]::Show(('Se quitarán {0} tareas que aún no empezaron. La tarea en curso no se toca. ¿Continuar?' -f $script:cola.Count), 'PC Care', 'YesNo', 'Question')
        if ($r -eq 'Yes') { Clear-ColaPendiente }
    })

# Que se puede reanudar despues de un cierre inesperado (las demas se repiten a mano)
$script:Reanudadores['LimpiarBasura'] = {
    param($p, $reg)
    Add-TareaLimpiezaBasura -Ids ([string[]]@($p['Ids'])) -Opciones ([string]$reg.Opciones)
    Start-AnalisisBasura
}
$script:Reanudadores['Papelera'] = { param($p, $reg) Add-TareaPapelera -Rutas ([string[]]@($p['Rutas'])) }
$script:Reanudadores['AccionDiag'] = { param($p, $reg) Add-TareaAccion -Id ([string]$p['Id']) -Nombre ([string]$reg.Nombre) -Opciones ([string]$reg.Opciones) }

$ui.chkSimulacion.Add_Click({
        if (-not (Test-Simulacion)) {
            $r = [System.Windows.MessageBox]::Show("Al quitar el modo simulación, las acciones de limpieza y optimización se aplicarán de verdad en este equipo.`n`n¿Quitar el modo simulación?", 'PC Care', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { $ui.chkSimulacion.IsChecked = $true }
        }
        Update-ModoSim
        Save-Config
        Write-Registro ('Modo de trabajo cambiado a: ' + $(if (Test-Simulacion) { 'simulación' } else { 'REAL' }))
    })

$ui.btnCancelar.Add_Click({
        if (-not $script:actual -and $script:cola.Count -eq 0) { return }
        $r = [System.Windows.MessageBox]::Show("Se cancelará la tarea en curso y se vaciará la cola.`n`nLo que ya se procesó no se deshace (por ejemplo, archivos ya enviados a la Papelera). ¿Cancelar?", 'PC Care', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { return }
        Clear-ColaPendiente
        if ($script:actual -and ([string]$script:actual.Reg.Tipo -ne 'Turbo')) {
            $script:actual.Cancelada = $true
            try { [void]$script:actual.PS.BeginStop($null, $null) } catch { }
        }
    })

$ui.btnSegRevisar.Add_Click({ Start-Seguridad })
$ui.btnAbrirSeg.Add_Click({ try { Start-Process 'windowsdefender:' } catch { Write-Registro 'No se pudo abrir Seguridad de Windows.' } })
$ui.btnHistActualizar.Add_Click({ Update-Historial })
$ui.btnHistRespaldos.Add_Click({
        $dir = Join-Path $CarpetaDatos 'RespaldoRegistro'
        if (-not (Test-Path -LiteralPath $dir)) { $dir = $CarpetaDatos }
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $dir)
    })

function Start-AnalisisGeneral {
    Start-AnalisisBasura
    Start-Seguridad
    Start-AnalisisInicio
    Start-Diagnostico
    Start-Procesos
    Start-AnalisisRegistro
}
$ui.btnAnalizarTodo.Add_Click({ Start-AnalisisGeneral })
$ui.btnMant.Add_Click({
        $ids = @(Get-Marcadas $tBasura)
        $txt = "El cuidado inteligente hará esto:`n`n  1. Limpiar las categorías de basura marcadas en Limpieza ({0}).`n  2. Vaciar la caché DNS.`n  3. Optimizar la unidad del sistema (TRIM en SSD).`n`nNo toca el registro, los programas de inicio ni tus archivos personales.`n`n¿Continuar?" -f $ids.Count
        if (-not (Confirm-Accion $txt 'Cuidado inteligente')) { return }
        Start-LimpiezaBasura -SinConfirmar
        foreach ($id in 'DNS', 'Optimizar') { Add-TareaAccion -Id $id -Nombre ('Mantenimiento: ' + $id) -Opciones $id }
        Start-Diagnostico
        $ui.expLog.IsExpanded = $true
    })
$ui.btnTurbo.Add_Click({ Switch-Turbo })
$ui.btnTurbo2.Add_Click({ Switch-Turbo })

$script:cargando = $false
$tBasura.Add_ColumnChanged({ param($o, $e) if (-not $script:cargando -and $e.Column.ColumnName -eq 'Sel') { Update-TotalBasura } })
$tArch.Add_ColumnChanged({ param($o, $e) if (-not $script:cargando -and $e.Column.ColumnName -eq 'Sel') { Update-SeleccionArch } })
$ui.btnAnalizarBasura.Add_Click({ Start-AnalisisBasura })
$ui.btnLimpiarBasura.Add_Click({ Start-LimpiezaBasura })
$ui.btnGrandes.Add_Click({
        Add-Tarea 'Buscando archivos grandes (puede tardar unos minutos)' $sbGrandes @{ MinMB = (Get-MinMB) } $alLlenarArchivos 'Archivos grandes' -Opciones ('{0} MB o más' -f (Get-MinMB))
    })
$ui.btnDuplicados.Add_Click({
        Add-Tarea 'Buscando duplicados por contenido (puede tardar varios minutos)' $sbDuplicados @{ MinMB = (Get-MinMB) } $alLlenarArchivos 'Duplicados' -Opciones ('{0} MB o más' -f (Get-MinMB))
    })
$ui.btnMarcarCopias.Add_Click({
        $vistos = @{}
        $script:cargando = $true
        foreach ($f in $tArch.Rows) {
            $g = [string]$f['Grupo']
            if (-not $g) { continue }
            if (-not $vistos.ContainsKey($g)) { $vistos[$g] = $true; $f['Sel'] = $false }
            else { $f['Sel'] = ([string]$f['Nube'] -eq '') }
        }
        $script:cargando = $false
        Update-SeleccionArch
    })
function Add-TareaPapelera {
    param([string[]]$Rutas)
    $rutas = [string[]]@($Rutas)
    $nombres = (@($rutas | Select-Object -First 3 | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')
    if ($rutas.Count -gt 3) { $nombres += (' y {0} más' -f ($rutas.Count - 3)) }
    Add-Tarea 'Enviando archivos a la Papelera' $sbPapelera @{ Rutas = $rutas; Simular = (Test-Simulacion) } {
        param($res, $ctx, $fallo)
        if ($fallo -or -not $res) { return }
        foreach ($m in $res[0].Mensajes) { Write-Registro ('   ' + $m) }
        if (-not $res[0].Simulado) {
            foreach ($ruta in $res[0].Hechos) {
                foreach ($f in @($tArch.Rows)) { if ([string]$f['Ruta'] -eq $ruta) { $tArch.Rows.Remove($f); break } }
            }
        }
        Update-SeleccionArch
        $ui.expLog.IsExpanded = $true
    } -Opciones ('{0} archivos: {1}' -f $rutas.Count, $nombres)
}
$ui.btnPapelera.Add_Click({
        $filas = @(Get-Marcadas $tArch)
        if ($filas.Count -eq 0) { return }
        $bytes = [double]0
        foreach ($f in $filas) { $bytes += [double]$f['Bytes'] }
        $txt = 'Se enviarán {0} archivos ({1}) a la Papelera de reciclaje.' -f $filas.Count, (Format-Tamano $bytes)
        $enNube = @($filas | Where-Object { [string]$_['Nube'] -ne '' }).Count
        if ($enNube -gt 0) { $txt += "`n`nATENCIÓN: {0} están en carpetas sincronizadas con OneDrive o SharePoint. Al quitarlos aquí también se quitan de la nube y de los demás equipos." -f $enNube }
        if (-not (Confirm-Accion ($txt + "`n`n¿Continuar?") 'Enviar a la Papelera')) { return }
        Add-TareaPapelera -Rutas ([string[]]@($filas | ForEach-Object { [string]$_['Ruta'] }))
    })
$ui.btnAnalizarReg.Add_Click({ Start-AnalisisRegistro })
$ui.btnLimpiarReg.Add_Click({
        $filas = @(Get-Marcadas $tReg)
        if ($filas.Count -eq 0) { return }
        $txt = "Se eliminarán {0} entradas del registro. Antes se exporta un respaldo .reg de cada una en:`n{1}`n`n¿Continuar?" -f $filas.Count, (Join-Path $CarpetaDatos 'RespaldoRegistro')
        if (-not (Confirm-Accion $txt 'Limpiar registro')) { return }
        $items = [string[]]@($filas | ForEach-Object { '{0}|{1}|{2}' -f $_['Tipo'], $_['RutaPS'], $_['Valor'] })
        Add-Tarea 'Limpiando registro' $sbLimpiarRegistro @{ Items = $items; Punto = [bool]$ui.chkRegPunto.IsChecked; Carpeta = $CarpetaDatos; Simular = (Test-Simulacion) } {
            param($res, $ctx, $fallo)
            if ($fallo -or -not $res) { return }
            foreach ($m in $res[0].Mensajes) { Write-Registro ('   ' + $m) }
            $ui.expLog.IsExpanded = $true
            if (-not $res[0].Simulado) { Start-AnalisisRegistro }
        } -Opciones ('{0} entradas del registro' -f $filas.Count)
    })

$ui.btnProcesos.Add_Click({ Start-Procesos })
$ui.btnDiagnosticar.Add_Click({ Start-Diagnostico })
$ui.btnAplicarInicio.Add_Click({
        $cambios = @(foreach ($f in $tInicio.Rows) { if ([string][bool]$f['Sel'] -ne [string]$f['Original']) { $f } })
        if ($cambios.Count -eq 0) { $ui.txtInicioCambios.Text = 'No hay cambios por aplicar.'; return }
        $lista = ($cambios | ForEach-Object { '  - {0}: {1}' -f $_['Nombre'], $(if ($_['Sel'] -eq $true) { 'iniciará con Windows' } else { 'dejará de iniciar con Windows' }) }) -join "`n"
        if (-not (Confirm-Accion ("Cambios en el arranque:`n`n{0}`n`nSe puede revertir aquí mismo o en el Administrador de tareas. ¿Aplicar?" -f $lista) 'Arranque de Windows')) { return }
        $hechos = 0
        foreach ($f in $cambios) {
            try {
                if (Test-Simulacion) { Write-Registro ('SIMULACIÓN: {0} -> inicia = {1}' -f $f['Nombre'], [bool]$f['Sel']) }
                else {
                    Set-InicioActivo ([string]$f['Aprobado']) ([string]$f['Nombre']) ([bool]$f['Sel'])
                    $f['Original'] = [string][bool]$f['Sel']
                    Write-Registro ('Arranque: {0} -> inicia = {1}' -f $f['Nombre'], [bool]$f['Sel'])
                }
                $hechos++
            }
            catch { Write-Registro ('No se pudo cambiar {0}: {1}' -f $f['Nombre'], $_.Exception.Message) }
        }
        $ui.txtInicioCambios.Text = '{0} cambios aplicados. Rigen desde el próximo inicio de sesión.' -f $hechos
        if (Test-Simulacion) { $ui.txtInicioCambios.Text = 'Simulación: {0} cambios registrados, ninguno aplicado.' -f $hechos }
    })

# Boton de accion por fila en el diagnostico
$clicDiag = [System.Windows.RoutedEventHandler] {
    param($origen, $e)
    $b = $e.OriginalSource
    if ($b -isnot [System.Windows.Controls.Button] -or $b.DataContext -isnot [System.Data.DataRowView]) { return }
    $fila = $b.DataContext.Row
    $id = [string]$fila['Accion']
    if (-not $id) { return }
    $txt = '{0}: {1}' -f $fila['Titulo'], $fila['TextoAccion']
    if ($id -eq 'Reparar') { $txt += "`n`nEjecuta DISM y SFC. Tarda entre 15 y 40 minutos; el resto de tareas espera en cola." }
    if (-not (Confirm-Accion ($txt + "`n`n¿Continuar?") 'Diagnóstico')) { return }
    Add-TareaAccion -Id $id -Nombre ('Diagnóstico: ' + $fila['TextoAccion']) -Opciones ([string]$fila['TextoAccion'])
    Start-Diagnostico
}
$ui.gridDiag.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $clicDiag)

$ventana.Add_ContentRendered({
        $reloj.Start()
        $relojSel.Start()
        [void]$psMuestreo.BeginInvoke()
        $relojMonitor.Start()
        if (Test-Simulacion) { Write-Registro 'Modo simulación activo: ninguna acción modifica el equipo hasta que lo desactives arriba a la derecha.' }
        if ($script:interrumpidasAlAbrir -gt 0) {
            Write-Registro ('Quedaron {0} tareas a medias la última vez. Revísalas en la página Tareas.' -f $script:interrumpidasAlAbrir)
            Update-Interrumpidas
            $ui.navTareas.IsChecked = $true
        }
        Start-LecturaRestauracion
        Start-AnalisisGeneral
    })
$ventana.Add_Closing({
        param($origen, $e)
        if ($script:actual -or $script:cola.Count -gt 0) {
            $r = [System.Windows.MessageBox]::Show("Hay tareas en curso o en espera.`n`nSi cierras ahora se guarda lo que falta y podrás reanudarlo al abrir PC Care (página Tareas). Lo que ya se hizo no se deshace, y un programa externo ya lanzado (por ejemplo winget) puede seguir unos segundos.`n`n¿Cerrar de todos modos?", 'PC Care', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { $e.Cancel = $true; return }
        }
        [void](Save-Cola $script:registros)
        $estado.Activo = $false
        $reloj.Stop()
        $relojSel.Stop()
        $relojMonitor.Stop()
        if ($script:turboActivo -and $script:planPrevio) { try { & powercfg.exe /setactive $script:planPrevio 2>&1 | Out-Null } catch { } }
    })

try { [void]$ventana.ShowDialog() }
catch { [void][System.Windows.MessageBox]::Show(('Error: ' + $_.Exception.Message), 'PC Care') }
