#Requires -Version 5.1
<#
.SYNOPSIS
    Auditoria de seguridad, inventario de software, actualizaciones pendientes y rendimiento para Windows 11.

.DESCRIPTION
    Script de solo lectura por defecto. No instala nada ni modifica el registro.
    Genera en la carpeta de salida:
      - Informe.html                     Informe ejecutivo con hallazgos y recomendaciones
      - hallazgos.csv                    Controles de seguridad y rendimiento evaluados
      - aplicaciones.csv                 Inventario de software instalado (registro)
      - aplicaciones_store.csv           Aplicaciones Appx / Microsoft Store del usuario
      - actualizaciones_apps.csv         Aplicaciones con actualizacion disponible (winget)
      - actualizaciones_windows.csv      Parches de Windows Update pendientes
      - procesos.csv                     Consumo de memoria y CPU por proceso
      - inicio.csv                       Programas que arrancan con Windows
      - inventario.json                  Resumen consolidable entre varios equipos

    Las acciones que SI modifican el equipo son opcionales y piden confirmacion:
      -ActualizarApps      Ejecuta winget upgrade --all
      -LimpiarTemporales   Borra temporales con mas de 7 dias

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\AuditoriaPC.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\AuditoriaPC.ps1 -Salida D:\Auditorias -OmitirWindowsUpdate -NoAbrir

.NOTES
    Ejecutar como Administrador para obtener BitLocker, TPM, Secure Boot y SMBv1.
    Licencia MIT. Compatible con Windows PowerShell 5.1 y PowerShell 7.
#>
[CmdletBinding()]
param(
    [string]$Salida = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'AuditoriaPC'),
    [ValidateRange(2, 60)][int]$SegundosMuestreo = 5,
    [switch]$OmitirWindowsUpdate,
    [switch]$ActualizarApps,
    [switch]$LimpiarTemporales,
    [switch]$NoAbrir
)

$ErrorActionPreference = 'Stop'
$inicioEjecucion = Get-Date

# ---------------------------------------------------------------------------
# Utilitarios
# ---------------------------------------------------------------------------
$hallazgos = New-Object System.Collections.Generic.List[object]

function Add-Hallazgo {
    param(
        [string]$Area,
        [string]$Control,
        [ValidateSet('OK', 'ALERTA', 'CRITICO', 'INFO')][string]$Estado,
        [string]$Detalle,
        [string]$Recomendacion = ''
    )
    $hallazgos.Add([pscustomobject]@{
            Area          = $Area
            Control       = $Control
            Estado        = $Estado
            Detalle       = $Detalle
            Recomendacion = $Recomendacion
        })
}

function Get-ValorReg {
    param([string]$Ruta, [string]$Nombre)
    try { return (Get-ItemProperty -LiteralPath $Ruta -Name $Nombre -ErrorAction Stop).$Nombre }
    catch { return $null }
}

function Get-TamanoCarpetaMB {
    param([string]$Ruta)
    try {
        $suma = (Get-ChildItem -LiteralPath $Ruta -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($null -eq $suma) { return 0 }
        return [math]::Round($suma / 1MB, 1)
    }
    catch { return $null }
}

function ConvertTo-TextoHtml {
    param($Texto)
    return [System.Net.WebUtility]::HtmlEncode([string]$Texto)
}

function ConvertTo-Tabla {
    param($Datos, [string[]]$Columnas)
    $filas = @($Datos | Where-Object { $null -ne $_ })
    if ($filas.Count -eq 0) { return '<p class="vacio">Sin datos.</p>' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<table><thead><tr>')
    foreach ($c in $Columnas) { [void]$sb.Append('<th>' + (ConvertTo-TextoHtml $c) + '</th>') }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($f in $filas) {
        [void]$sb.Append('<tr>')
        foreach ($c in $Columnas) {
            $v = ConvertTo-TextoHtml $f.$c
            if ($c -eq 'Estado') { $v = '<span class="tag ' + $v + '">' + $v + '</span>' }
            [void]$sb.Append('<td>' + $v + '</td>')
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    return $sb.ToString()
}

function Get-Campo {
    param([string]$Linea, [int[]]$Inicios, [int]$Indice)
    if ($Inicios[$Indice] -ge $Linea.Length) { return '' }
    if ($Indice + 1 -lt $Inicios.Count) { $fin = [math]::Min($Inicios[$Indice + 1], $Linea.Length) }
    else { $fin = $Linea.Length }
    return $Linea.Substring($Inicios[$Indice], $fin - $Inicios[$Indice]).Trim()
}

function Get-ActualizacionesWinget {
    # Devuelve $null si winget no esta disponible; lista (posiblemente vacia) si se pudo consultar.
    $ErrorActionPreference = 'Continue'
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { return $null }

    $codificacionPrevia = $null
    try { $codificacionPrevia = [Console]::OutputEncoding; [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    try {
        $crudo = & winget.exe upgrade --include-unknown --accept-source-agreements --disable-interactivity 2>$null
    }
    finally {
        if ($codificacionPrevia) { try { [Console]::OutputEncoding = $codificacionPrevia } catch { } }
    }

    $lineas = @($crudo | ForEach-Object { (([string]$_) -split "`r")[-1] })
    $resultado = New-Object System.Collections.Generic.List[object]
    $inicios = $null
    for ($i = 0; $i -lt $lineas.Count; $i++) {
        $linea = $lineas[$i]
        if ($linea -match '^-{10,}\s*$' -and $i -gt 0) {
            # La fila anterior es la cabecera: sus palabras marcan el inicio de cada columna
            $inicios = @([regex]::Matches($lineas[$i - 1], '\S+') | ForEach-Object { $_.Index })
            continue
        }
        if ([string]::IsNullOrWhiteSpace($linea)) { $inicios = $null; continue }
        if ($null -eq $inicios -or $inicios.Count -lt 4) { continue }

        $id = Get-Campo $linea $inicios 1
        $actual = Get-Campo $linea $inicios 2
        $nueva = Get-Campo $linea $inicios 3
        if ($id -notmatch '^\S+$' -or -not $actual -or -not $nueva) { continue }
        $origen = ''
        if ($inicios.Count -ge 5) { $origen = Get-Campo $linea $inicios 4 }
        $resultado.Add([pscustomobject]@{
                Nombre     = Get-Campo $linea $inicios 0
                Id         = $id
                Instalada  = $actual
                Disponible = $nueva
                Origen     = $origen
            })
    }
    return , $resultado.ToArray()
}

# ---------------------------------------------------------------------------
# Preparacion
# ---------------------------------------------------------------------------
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

$carpeta = Join-Path $Salida ('{0}_{1}' -f $env:COMPUTERNAME, $inicioEjecucion.ToString('yyyyMMdd_HHmm'))
New-Item -ItemType Directory -Path $carpeta -Force | Out-Null

Write-Host ''
Write-Host '=== Auditoria de equipo Windows ===' -ForegroundColor Cyan
Write-Host ('Equipo: {0}   Usuario: {1}   Administrador: {2}' -f $env:COMPUTERNAME, $env:USERNAME, $esAdmin)
if (-not $esAdmin) {
    Write-Warning 'Sin privilegios de administrador: BitLocker, TPM, Secure Boot y SMBv1 pueden quedar sin evaluar.'
}

# ---------------------------------------------------------------------------
# 1. Sistema
# ---------------------------------------------------------------------------
Write-Host '[1/6] Sistema y hardware...'
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$rutaNT = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$version = Get-ValorReg $rutaNT 'DisplayVersion'
$ubr = Get-ValorReg $rutaNT 'UBR'
$uptime = (Get-Date) - $os.LastBootUpTime
$ramTotalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
$ramLibreGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
$ramUsoPct = [math]::Round((1 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize)) * 100, 0)

$sistema = [ordered]@{
    'Equipo'            = $env:COMPUTERNAME
    'Fabricante/Modelo' = ('{0} {1}' -f $cs.Manufacturer, $cs.Model)
    'Numero de serie'   = $bios.SerialNumber
    'Sistema operativo' = ('{0} {1} (compilacion {2}.{3})' -f $os.Caption, $version, $os.BuildNumber, $ubr)
    'Procesador'        = ('{0} ({1} nucleos / {2} hilos)' -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)
    'Memoria RAM'       = ('{0} GB instalados, {1} GB libres ({2}% en uso)' -f $ramTotalGB, $ramLibreGB, $ramUsoPct)
    'Dominio/Grupo'     = $cs.Domain
    'Ultimo arranque'   = ('{0} (hace {1} dias {2} h)' -f $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm'), $uptime.Days, $uptime.Hours)
    'Fecha de auditoria' = $inicioEjecucion.ToString('yyyy-MM-dd HH:mm')
}

# ---------------------------------------------------------------------------
# 2. Seguridad
# ---------------------------------------------------------------------------
Write-Host '[2/6] Controles de seguridad...'

# Antivirus registrados en el Centro de seguridad
$avTerceroActivo = $false
try {
    $productos = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct)
    foreach ($p in $productos) {
        $hex = '{0:X6}' -f [int]$p.productState
        $activo = $hex.Substring(2, 2) -in @('10', '11')
        $alDia = $hex.Substring(4, 2) -eq '00'
        if ($activo -and $p.displayName -notmatch 'Defender') { $avTerceroActivo = $true }
        if ($activo -and $alDia) { $estado = 'OK' } elseif ($activo) { $estado = 'ALERTA' } else { $estado = 'INFO' }
        Add-Hallazgo 'Seguridad' ('Antivirus registrado: ' + $p.displayName) $estado `
        ('Activo: {0}. Firmas al dia: {1}.' -f $activo, $alDia) `
        $(if ($activo -and -not $alDia) { 'Actualizar las firmas del antivirus.' } else { '' })
    }
    if ($productos.Count -eq 0) {
        Add-Hallazgo 'Seguridad' 'Antivirus registrado' 'CRITICO' 'No hay ningun antivirus registrado en el Centro de seguridad.' 'Habilitar Microsoft Defender o instalar un antivirus.'
    }
}
catch { Add-Hallazgo 'Seguridad' 'Antivirus registrado' 'INFO' 'No se pudo consultar el Centro de seguridad (normal en Windows Server).' }

# Microsoft Defender
try {
    $mp = Get-MpComputerStatus
    if ($mp.AntivirusEnabled -and $mp.RealTimeProtectionEnabled) {
        Add-Hallazgo 'Seguridad' 'Defender: proteccion en tiempo real' 'OK' 'Activa.'
    }
    elseif ($avTerceroActivo) {
        Add-Hallazgo 'Seguridad' 'Defender: proteccion en tiempo real' 'INFO' 'Inactiva porque hay un antivirus de terceros activo.'
    }
    else {
        Add-Hallazgo 'Seguridad' 'Defender: proteccion en tiempo real' 'CRITICO' 'Inactiva y sin antivirus de terceros activo.' 'Activar la proteccion en tiempo real en Seguridad de Windows.'
    }
    if ($mp.AntivirusEnabled) {
        $edad = [int64]$mp.AntivirusSignatureAge
        if ($edad -le 3) { Add-Hallazgo 'Seguridad' 'Defender: firmas' 'OK' ('Antiguedad: {0} dias.' -f $edad) }
        else { Add-Hallazgo 'Seguridad' 'Defender: firmas' 'ALERTA' ('Antiguedad: {0} dias.' -f $edad) 'Ejecutar Update-MpSignature o revisar Windows Update.' }
        if ($mp.IsTamperProtected) { Add-Hallazgo 'Seguridad' 'Defender: proteccion contra alteraciones' 'OK' 'Activa.' }
        else { Add-Hallazgo 'Seguridad' 'Defender: proteccion contra alteraciones' 'ALERTA' 'Inactiva.' 'Activar Tamper Protection en Seguridad de Windows.' }
        $diasScan = $mp.QuickScanAge
        if ($null -ne $diasScan -and [int64]$diasScan -gt 14) {
            Add-Hallazgo 'Seguridad' 'Defender: ultimo examen rapido' 'ALERTA' ('Hace {0} dias o nunca.' -f $diasScan) 'Ejecutar Start-MpScan -ScanType QuickScan.'
        }
    }
}
catch { Add-Hallazgo 'Seguridad' 'Microsoft Defender' 'INFO' 'No se pudo consultar el estado de Defender.' }

# Firewall
try {
    foreach ($perfil in Get-NetFirewallProfile) {
        if ([string]$perfil.Enabled -eq 'True') {
            Add-Hallazgo 'Seguridad' ('Firewall perfil ' + $perfil.Name) 'OK' 'Habilitado.'
        }
        else {
            Add-Hallazgo 'Seguridad' ('Firewall perfil ' + $perfil.Name) 'CRITICO' 'Deshabilitado.' 'Habilitar el firewall de Windows en este perfil.'
        }
    }
}
catch { Add-Hallazgo 'Seguridad' 'Firewall de Windows' 'INFO' 'No se pudo consultar.' }

# UAC
$lua = Get-ValorReg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA'
if ($lua -eq 1) { Add-Hallazgo 'Seguridad' 'Control de cuentas (UAC)' 'OK' 'Habilitado.' }
else { Add-Hallazgo 'Seguridad' 'Control de cuentas (UAC)' 'CRITICO' 'Deshabilitado.' 'Habilitar UAC (EnableLUA = 1) y reiniciar.' }

# BitLocker
try {
    $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive
    if ([string]$bl.ProtectionStatus -eq 'On') {
        Add-Hallazgo 'Seguridad' 'Cifrado de disco (BitLocker)' 'OK' ('Unidad {0} protegida ({1}).' -f $env:SystemDrive, $bl.EncryptionMethod)
    }
    else {
        Add-Hallazgo 'Seguridad' 'Cifrado de disco (BitLocker)' 'ALERTA' ('Unidad {0} sin proteccion activa.' -f $env:SystemDrive) 'Activar BitLocker y resguardar la clave de recuperacion, sobre todo en laptops.'
    }
}
catch { Add-Hallazgo 'Seguridad' 'Cifrado de disco (BitLocker)' 'INFO' 'No evaluado (requiere administrador o la edicion no incluye BitLocker).' }

# Secure Boot y TPM
try {
    if (Confirm-SecureBootUEFI) { Add-Hallazgo 'Seguridad' 'Arranque seguro (Secure Boot)' 'OK' 'Habilitado.' }
    else { Add-Hallazgo 'Seguridad' 'Arranque seguro (Secure Boot)' 'ALERTA' 'Deshabilitado.' 'Habilitar Secure Boot en la UEFI.' }
}
catch { Add-Hallazgo 'Seguridad' 'Arranque seguro (Secure Boot)' 'INFO' 'No evaluado (requiere administrador o el equipo arranca en modo BIOS heredado).' }
try {
    $tpm = Get-Tpm
    if ($tpm.TpmPresent -and $tpm.TpmReady) { Add-Hallazgo 'Seguridad' 'TPM' 'OK' 'Presente y listo.' }
    else { Add-Hallazgo 'Seguridad' 'TPM' 'ALERTA' ('Presente: {0}. Listo: {1}.' -f $tpm.TpmPresent, $tpm.TpmReady) 'Habilitar el TPM en la UEFI.' }
}
catch { Add-Hallazgo 'Seguridad' 'TPM' 'INFO' 'No evaluado (requiere administrador).' }

# SMBv1
try {
    if ((Get-SmbServerConfiguration).EnableSMB1Protocol) {
        Add-Hallazgo 'Seguridad' 'Protocolo SMBv1' 'CRITICO' 'Habilitado en el servidor SMB.' 'Deshabilitar: Set-SmbServerConfiguration -EnableSMB1Protocol $false'
    }
    else { Add-Hallazgo 'Seguridad' 'Protocolo SMBv1' 'OK' 'Deshabilitado.' }
}
catch { Add-Hallazgo 'Seguridad' 'Protocolo SMBv1' 'INFO' 'No evaluado (requiere administrador).' }

# Escritorio remoto
$rdpDenegado = Get-ValorReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections'
if ($rdpDenegado -eq 0) {
    $nla = Get-ValorReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication'
    if ($nla -eq 1) {
        Add-Hallazgo 'Seguridad' 'Escritorio remoto (RDP)' 'ALERTA' 'Habilitado con NLA.' 'Confirmar que el puerto 3389 no este publicado a Internet; usar VPN.'
    }
    else {
        Add-Hallazgo 'Seguridad' 'Escritorio remoto (RDP)' 'CRITICO' 'Habilitado sin autenticacion a nivel de red (NLA).' 'Exigir NLA y restringir el acceso por VPN.'
    }
}
else { Add-Hallazgo 'Seguridad' 'Escritorio remoto (RDP)' 'OK' 'Deshabilitado.' }

# Cuentas locales
try {
    $admins = @(Get-LocalGroupMember -SID 'S-1-5-32-544' | ForEach-Object { $_.Name })
    if ($admins.Count -gt 2) { $estado = 'ALERTA'; $rec = 'Reducir administradores locales al minimo necesario.' } else { $estado = 'OK'; $rec = '' }
    Add-Hallazgo 'Seguridad' 'Administradores locales' $estado ('{0}: {1}' -f $admins.Count, ($admins -join ', ')) $rec
}
catch { Add-Hallazgo 'Seguridad' 'Administradores locales' 'INFO' 'No se pudo enumerar el grupo.' }
try {
    $invitado = Get-LocalUser | Where-Object { $_.SID.Value -like '*-501' }
    if ($invitado -and $invitado.Enabled) { Add-Hallazgo 'Seguridad' 'Cuenta Invitado' 'CRITICO' 'Habilitada.' 'Deshabilitar la cuenta Invitado.' }
    else { Add-Hallazgo 'Seguridad' 'Cuenta Invitado' 'OK' 'Deshabilitada.' }
}
catch { }
if ((Get-ValorReg "$rutaNT\Winlogon" 'AutoAdminLogon') -eq '1') {
    Add-Hallazgo 'Seguridad' 'Inicio de sesion automatico' 'CRITICO' 'Habilitado: la credencial puede estar almacenada en el registro.' 'Deshabilitar AutoAdminLogon.'
}
if ((Get-ValorReg 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL') -in @(1, 2)) {
    Add-Hallazgo 'Seguridad' 'Proteccion LSA' 'OK' 'Habilitada.'
}
else {
    Add-Hallazgo 'Seguridad' 'Proteccion LSA' 'INFO' 'No habilitada por registro.' 'Evaluar habilitar RunAsPPL para dificultar el robo de credenciales.'
}

# Reinicio pendiente
$reinicio = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
if ($reinicio) { Add-Hallazgo 'Actualizaciones' 'Reinicio pendiente' 'ALERTA' 'Hay parches instalados que no aplican hasta reiniciar.' 'Reiniciar el equipo.' }
else { Add-Hallazgo 'Actualizaciones' 'Reinicio pendiente' 'OK' 'No.' }

# ---------------------------------------------------------------------------
# 3. Windows Update
# ---------------------------------------------------------------------------
Write-Host '[3/6] Windows Update...'
try {
    $ultimo = Get-HotFix | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if ($ultimo) {
        $dias = [int]((Get-Date) - $ultimo.InstalledOn).TotalDays
        if ($dias -le 45) { $estado = 'OK'; $rec = '' } else { $estado = 'ALERTA'; $rec = 'Revisar por que el equipo no recibe parches mensuales.' }
        Add-Hallazgo 'Actualizaciones' 'Ultimo parche de Windows' $estado ('{0} instalado hace {1} dias.' -f $ultimo.HotFixID, $dias) $rec
    }
}
catch { }

$parchesWindows = @()
if ($OmitirWindowsUpdate) {
    Add-Hallazgo 'Actualizaciones' 'Parches de Windows pendientes' 'INFO' 'Consulta omitida por parametro.'
}
else {
    Write-Host '      Consultando parches pendientes (puede tardar 1 a 3 minutos)...'
    try {
        $sesionWU = New-Object -ComObject Microsoft.Update.Session
        $busqueda = $sesionWU.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0')
        $parchesWindows = @(foreach ($u in $busqueda.Updates) {
                [pscustomobject]@{
                    Titulo    = $u.Title
                    Severidad = $(if ($u.MsrcSeverity) { $u.MsrcSeverity } else { 'No clasificada' })
                    KB        = (@($u.KBArticleIDs) | ForEach-Object { 'KB' + $_ }) -join ', '
                    TamanoMB  = [math]::Round($u.MaxDownloadSize / 1MB, 1)
                }
            })
        if ($parchesWindows.Count -eq 0) {
            Add-Hallazgo 'Actualizaciones' 'Parches de Windows pendientes' 'OK' 'Ninguno.'
        }
        else {
            $graves = @($parchesWindows | Where-Object { $_.Severidad -in @('Critical', 'Important') }).Count
            if ($graves -gt 0) { $estado = 'CRITICO' } else { $estado = 'ALERTA' }
            Add-Hallazgo 'Actualizaciones' 'Parches de Windows pendientes' $estado ('{0} pendientes ({1} criticos o importantes).' -f $parchesWindows.Count, $graves) 'Instalar desde Configuracion > Windows Update.'
        }
    }
    catch { Add-Hallazgo 'Actualizaciones' 'Parches de Windows pendientes' 'INFO' ('No se pudo consultar: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------------------
# 4. Inventario de software
# ---------------------------------------------------------------------------
Write-Host '[4/6] Inventario de aplicaciones...'
$origenes = @(
    @{ Ruta = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Ambito = 'Equipo (64 bits)' },
    @{ Ruta = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Ambito = 'Equipo (32 bits)' },
    @{ Ruta = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Ambito = 'Usuario' }
)
$apps = foreach ($o in $origenes) {
    if (-not (Test-Path $o.Ruta)) { continue }
    foreach ($clave in (Get-ChildItem -LiteralPath $o.Ruta -ErrorAction SilentlyContinue)) {
        try {
            $nombre = $clave.GetValue('DisplayName')
            if (-not $nombre) { continue }
            if ($clave.GetValue('SystemComponent') -eq 1) { continue }
            if ($clave.GetValue('ParentKeyName')) { continue }
            $tamano = $clave.GetValue('EstimatedSize')
            [pscustomobject]@{
                Nombre           = [string]$nombre
                Version          = [string]$clave.GetValue('DisplayVersion')
                Editor           = [string]$clave.GetValue('Publisher')
                FechaInstalacion = [string]$clave.GetValue('InstallDate')
                TamanoMB         = $(if ($tamano) { [math]::Round([double]$tamano / 1024, 1) } else { $null })
                Ambito           = $o.Ambito
            }
        }
        catch { }
    }
}
$apps = @($apps | Sort-Object Nombre, Version -Unique)

$appsStore = @()
try {
    $appsStore = @(Get-AppxPackage | Where-Object { -not $_.IsFramework -and $_.SignatureKind -ne 'System' } |
            Select-Object Name, @{ n = 'Version'; e = { [string]$_.Version } }, Publisher | Sort-Object Name)
}
catch { }

Write-Host '      Consultando actualizaciones de aplicaciones con winget...'
$appsDesactualizadas = Get-ActualizacionesWinget
if ($null -eq $appsDesactualizadas) {
    Add-Hallazgo 'Actualizaciones' 'Aplicaciones desactualizadas' 'INFO' 'winget no esta disponible en este equipo.' 'Instalar "Instalador de aplicacion" desde Microsoft Store.'
    $appsDesactualizadas = @()
}
elseif ($appsDesactualizadas.Count -eq 0) {
    Add-Hallazgo 'Actualizaciones' 'Aplicaciones desactualizadas' 'OK' 'winget no reporta actualizaciones pendientes.'
}
else {
    if ($appsDesactualizadas.Count -ge 10) { $estado = 'CRITICO' } else { $estado = 'ALERTA' }
    Add-Hallazgo 'Actualizaciones' 'Aplicaciones desactualizadas' $estado ('{0} aplicaciones con version nueva disponible.' -f $appsDesactualizadas.Count) 'Priorizar navegadores, Java, lectores PDF, VPN y herramientas de acceso remoto. Ejecutar el script con -ActualizarApps.'
}

# ---------------------------------------------------------------------------
# 5. Rendimiento
# ---------------------------------------------------------------------------
Write-Host ('[5/6] Rendimiento (muestreo de {0} s)...' -f $SegundosMuestreo)
$hilos = [Environment]::ProcessorCount
$muestra = @{}
foreach ($p in Get-Process) { if ($null -ne $p.CPU) { $muestra[$p.Id] = $p.CPU } }
Start-Sleep -Seconds $SegundosMuestreo
$cpuCarga = [math]::Round((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average, 0)

$procesos = @(Get-Process | Group-Object ProcessName | ForEach-Object {
        $delta = 0.0
        foreach ($p in $_.Group) {
            if ($null -ne $p.CPU -and $muestra.ContainsKey($p.Id)) { $delta += [math]::Max(0, $p.CPU - $muestra[$p.Id]) }
        }
        [pscustomobject]@{
            Proceso    = $_.Name
            Instancias = $_.Count
            MemoriaMB  = [math]::Round((($_.Group | Measure-Object -Property WorkingSet64 -Sum).Sum) / 1MB, 1)
            CPUPct     = [math]::Round($delta / ($SegundosMuestreo * $hilos) * 100, 1)
        }
    })
$topMemoria = @($procesos | Sort-Object MemoriaMB -Descending | Select-Object -First 15)
$topCpu = @($procesos | Where-Object { $_.Proceso -ne 'Idle' } | Sort-Object CPUPct -Descending | Select-Object -First 10)

$inicioAuto = @()
try {
    $inicioAuto = @(Get-CimInstance Win32_StartupCommand | Select-Object @{ n = 'Nombre'; e = { $_.Name } },
        @{ n = 'Comando'; e = { $_.Command } }, @{ n = 'Ubicacion'; e = { $_.Location } }, @{ n = 'Usuario'; e = { $_.User } })
}
catch { }

$discos = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        [pscustomobject]@{
            Unidad   = $_.DeviceID
            TamanoGB = [math]::Round($_.Size / 1GB, 1)
            LibreGB  = [math]::Round($_.FreeSpace / 1GB, 1)
            LibrePct = $(if ($_.Size) { [math]::Round($_.FreeSpace / $_.Size * 100, 0) } else { 0 })
        }
    })
$discosFisicos = @()
try {
    $discosFisicos = @(Get-PhysicalDisk | Select-Object @{ n = 'Disco'; e = { $_.FriendlyName } },
        @{ n = 'Tipo'; e = { [string]$_.MediaType } }, @{ n = 'Salud'; e = { [string]$_.HealthStatus } },
        @{ n = 'TamanoGB'; e = { [math]::Round($_.Size / 1GB, 0) } })
}
catch { }

$tempUsuarioMB = Get-TamanoCarpetaMB $env:TEMP
$tempSistemaMB = Get-TamanoCarpetaMB (Join-Path $env:windir 'Temp')
$planEnergia = ''
try { $planEnergia = ((& powercfg.exe /getactivescheme) -join ' ') -replace '^.*\((.+)\).*$', '$1' } catch { }

# Evaluacion de rendimiento
if ($ramUsoPct -ge 85) {
    $culpables = ($topMemoria | Select-Object -First 3 | ForEach-Object { '{0} ({1} MB)' -f $_.Proceso, $_.MemoriaMB }) -join ', '
    Add-Hallazgo 'Rendimiento' 'Uso de memoria' 'ALERTA' ('{0}% en uso. Mayores consumidores: {1}.' -f $ramUsoPct, $culpables) 'Cerrar o desinstalar lo que no se usa; si el uso es habitual, ampliar RAM.'
}
else { Add-Hallazgo 'Rendimiento' 'Uso de memoria' 'OK' ('{0}% en uso de {1} GB.' -f $ramUsoPct, $ramTotalGB) }
if ($ramTotalGB -lt 8) {
    Add-Hallazgo 'Rendimiento' 'Memoria instalada' 'ALERTA' ('{0} GB.' -f $ramTotalGB) 'Windows 11 con ofimatica y navegador rinde mejor con 16 GB.'
}
if ($cpuCarga -ge 80) {
    $culpables = ($topCpu | Select-Object -First 3 | ForEach-Object { '{0} ({1}%)' -f $_.Proceso, $_.CPUPct }) -join ', '
    Add-Hallazgo 'Rendimiento' 'Carga de CPU' 'ALERTA' ('{0}% durante el muestreo. Procesos: {1}.' -f $cpuCarga, $culpables) 'Revisar esos procesos; si es sostenido sin motivo, analizar con antivirus.'
}
else { Add-Hallazgo 'Rendimiento' 'Carga de CPU' 'OK' ('{0}% durante el muestreo.' -f $cpuCarga) }
if ($inicioAuto.Count -gt 10) {
    Add-Hallazgo 'Rendimiento' 'Programas de inicio' 'ALERTA' ('{0} entradas arrancan con Windows.' -f $inicioAuto.Count) 'Deshabilitar las innecesarias en Administrador de tareas > Aplicaciones de arranque.'
}
else { Add-Hallazgo 'Rendimiento' 'Programas de inicio' 'OK' ('{0} entradas.' -f $inicioAuto.Count) }
foreach ($d in $discos) {
    if ($d.LibrePct -lt 10) { Add-Hallazgo 'Rendimiento' ('Espacio en ' + $d.Unidad) 'CRITICO' ('{0}% libre ({1} GB).' -f $d.LibrePct, $d.LibreGB) 'Liberar espacio: Windows Update puede fallar por falta de disco.' }
    elseif ($d.LibrePct -lt 20) { Add-Hallazgo 'Rendimiento' ('Espacio en ' + $d.Unidad) 'ALERTA' ('{0}% libre ({1} GB).' -f $d.LibrePct, $d.LibreGB) 'Liberar espacio con Sensor de almacenamiento.' }
    else { Add-Hallazgo 'Rendimiento' ('Espacio en ' + $d.Unidad) 'OK' ('{0}% libre ({1} GB).' -f $d.LibrePct, $d.LibreGB) }
}
foreach ($d in $discosFisicos) {
    if ($d.Salud -ne 'Healthy') { Add-Hallazgo 'Rendimiento' ('Salud del disco ' + $d.Disco) 'CRITICO' ('Estado: {0}.' -f $d.Salud) 'Respaldar la informacion y reemplazar el disco.' }
    if ($d.Tipo -eq 'HDD') { Add-Hallazgo 'Rendimiento' ('Tipo de disco ' + $d.Disco) 'ALERTA' 'Disco mecanico (HDD).' 'Migrar a SSD: es la mejora de rendimiento con mayor retorno.' }
}
if ($uptime.TotalDays -gt 14) {
    Add-Hallazgo 'Rendimiento' 'Tiempo encendido' 'ALERTA' ('{0} dias sin reiniciar.' -f $uptime.Days) 'Reiniciar para aplicar parches y liberar memoria.'
}
$tempTotal = [double]$tempUsuarioMB + [double]$tempSistemaMB
if ($tempTotal -gt 2048) {
    Add-Hallazgo 'Rendimiento' 'Archivos temporales' 'ALERTA' ('{0} MB entre temporales de usuario y de sistema.' -f $tempTotal) 'Ejecutar el script con -LimpiarTemporales o usar Sensor de almacenamiento.'
}
else { Add-Hallazgo 'Rendimiento' 'Archivos temporales' 'OK' ('{0} MB.' -f $tempTotal) }
if ($planEnergia) { Add-Hallazgo 'Rendimiento' 'Plan de energia' 'INFO' $planEnergia }

# ---------------------------------------------------------------------------
# 6. Salidas
# ---------------------------------------------------------------------------
Write-Host '[6/6] Generando informe...'
$nCritico = @($hallazgos | Where-Object { $_.Estado -eq 'CRITICO' }).Count
$nAlerta = @($hallazgos | Where-Object { $_.Estado -eq 'ALERTA' }).Count
$nOk = @($hallazgos | Where-Object { $_.Estado -eq 'OK' }).Count
$evaluados = $nCritico + $nAlerta + $nOk
$puntaje = 0
if ($evaluados -gt 0) { $puntaje = [math]::Round($nOk / $evaluados * 100, 0) }

$csv = @{ NoTypeInformation = $true; Encoding = 'UTF8'; UseCulture = $true }
$hallazgos | Export-Csv -Path (Join-Path $carpeta 'hallazgos.csv') @csv
$apps | Export-Csv -Path (Join-Path $carpeta 'aplicaciones.csv') @csv
if ($appsStore.Count) { $appsStore | Export-Csv -Path (Join-Path $carpeta 'aplicaciones_store.csv') @csv }
if ($appsDesactualizadas.Count) { $appsDesactualizadas | Export-Csv -Path (Join-Path $carpeta 'actualizaciones_apps.csv') @csv }
if ($parchesWindows.Count) { $parchesWindows | Export-Csv -Path (Join-Path $carpeta 'actualizaciones_windows.csv') @csv }
$procesos | Sort-Object MemoriaMB -Descending | Export-Csv -Path (Join-Path $carpeta 'procesos.csv') @csv
if ($inicioAuto.Count) { $inicioAuto | Export-Csv -Path (Join-Path $carpeta 'inicio.csv') @csv }

[ordered]@{
    Equipo               = $env:COMPUTERNAME
    Fecha                = $inicioEjecucion.ToString('s')
    EjecutadoComoAdmin   = $esAdmin
    Sistema              = $sistema
    Puntaje              = $puntaje
    Criticos             = $nCritico
    Alertas              = $nAlerta
    AppsInstaladas       = $apps.Count
    AppsDesactualizadas  = $appsDesactualizadas.Count
    ParchesPendientes    = $parchesWindows.Count
    UsoMemoriaPct        = $ramUsoPct
    CargaCpuPct          = $cpuCarga
    Hallazgos            = $hallazgos
} | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $carpeta 'inventario.json') -Encoding UTF8

$css = @'
body{font-family:Segoe UI,Arial,sans-serif;margin:0;background:#f3f5f8;color:#1c2733;font-size:14px}
header{background:#12324f;color:#fff;padding:22px 32px}
header h1{margin:0 0 4px;font-size:22px}
header p{margin:0;opacity:.85}
main{padding:24px 32px;max-width:1200px;margin:auto}
h2{font-size:17px;margin:28px 0 10px;border-bottom:2px solid #12324f;padding-bottom:4px}
.tarjetas{display:flex;flex-wrap:wrap;gap:12px}
.tarjeta{background:#fff;border-radius:6px;padding:14px 18px;min-width:150px;flex:1;box-shadow:0 1px 2px rgba(0,0,0,.08)}
.tarjeta b{display:block;font-size:26px}
.tarjeta span{color:#5b6875}
table{border-collapse:collapse;width:100%;background:#fff;box-shadow:0 1px 2px rgba(0,0,0,.08)}
th{background:#e4e9ef;text-align:left;padding:7px 10px;font-size:13px}
td{padding:6px 10px;border-top:1px solid #e8ecf0;vertical-align:top;word-break:break-word}
.tag{display:inline-block;padding:2px 8px;border-radius:10px;font-size:12px;font-weight:600;color:#fff}
.OK{background:#2e7d32}.ALERTA{background:#e08600}.CRITICO{background:#c62828}.INFO{background:#6b7785}
.vacio{color:#6b7785;font-style:italic}
details{margin-top:8px}summary{cursor:pointer;font-weight:600;padding:6px 0}
footer{padding:18px 32px;color:#6b7785;font-size:12px}
'@

$filasSistema = foreach ($k in $sistema.Keys) { [pscustomobject]@{ Dato = $k; Valor = $sistema[$k] } }
$orden = @{ CRITICO = 0; ALERTA = 1; INFO = 2; OK = 3 }
$hallazgosOrdenados = $hallazgos | Sort-Object @{ e = { $orden[$_.Estado] } }, Area, Control

$html = New-Object System.Text.StringBuilder
[void]$html.Append('<!DOCTYPE html><html lang="es"><head><meta charset="utf-8"><title>Auditoria ' + (ConvertTo-TextoHtml $env:COMPUTERNAME) + '</title><style>' + $css + '</style></head><body>')
[void]$html.Append('<header><h1>Auditoria de equipo: ' + (ConvertTo-TextoHtml $env:COMPUTERNAME) + '</h1><p>' + $inicioEjecucion.ToString('yyyy-MM-dd HH:mm') + ' | Ejecutado como administrador: ' + $(if ($esAdmin) { 'Si' } else { 'No (resultado parcial)' }) + '</p></header><main>')
[void]$html.Append('<div class="tarjetas">')
[void]$html.Append('<div class="tarjeta"><b>' + $puntaje + '%</b><span>Controles conformes</span></div>')
[void]$html.Append('<div class="tarjeta"><b style="color:#c62828">' + $nCritico + '</b><span>Criticos</span></div>')
[void]$html.Append('<div class="tarjeta"><b style="color:#e08600">' + $nAlerta + '</b><span>Alertas</span></div>')
[void]$html.Append('<div class="tarjeta"><b>' + $appsDesactualizadas.Count + '</b><span>Apps por actualizar</span></div>')
[void]$html.Append('<div class="tarjeta"><b>' + $parchesWindows.Count + '</b><span>Parches de Windows</span></div>')
[void]$html.Append('<div class="tarjeta"><b>' + $ramUsoPct + '%</b><span>Memoria en uso</span></div>')
[void]$html.Append('<div class="tarjeta"><b>' + $cpuCarga + '%</b><span>Carga de CPU</span></div>')
[void]$html.Append('</div>')
[void]$html.Append('<h2>Hallazgos y recomendaciones</h2>' + (ConvertTo-Tabla $hallazgosOrdenados @('Estado', 'Area', 'Control', 'Detalle', 'Recomendacion')))
[void]$html.Append('<h2>Sistema</h2>' + (ConvertTo-Tabla $filasSistema @('Dato', 'Valor')))
[void]$html.Append('<h2>Aplicaciones con actualizacion disponible (' + $appsDesactualizadas.Count + ')</h2>' + (ConvertTo-Tabla $appsDesactualizadas @('Nombre', 'Id', 'Instalada', 'Disponible', 'Origen')))
[void]$html.Append('<h2>Parches de Windows pendientes (' + $parchesWindows.Count + ')</h2>' + (ConvertTo-Tabla $parchesWindows @('Titulo', 'Severidad', 'KB', 'TamanoMB')))
[void]$html.Append('<h2>Consumo de memoria: 15 procesos principales</h2>' + (ConvertTo-Tabla $topMemoria @('Proceso', 'Instancias', 'MemoriaMB', 'CPUPct')))
[void]$html.Append('<h2>Consumo de CPU: 10 procesos principales</h2>' + (ConvertTo-Tabla $topCpu @('Proceso', 'Instancias', 'CPUPct', 'MemoriaMB')))
[void]$html.Append('<h2>Programas de inicio (' + $inicioAuto.Count + ')</h2>' + (ConvertTo-Tabla $inicioAuto @('Nombre', 'Comando', 'Ubicacion', 'Usuario')))
[void]$html.Append('<h2>Almacenamiento</h2>' + (ConvertTo-Tabla $discos @('Unidad', 'TamanoGB', 'LibreGB', 'LibrePct')) + '<br>' + (ConvertTo-Tabla $discosFisicos @('Disco', 'Tipo', 'Salud', 'TamanoGB')))
[void]$html.Append('<h2>Inventario de software (' + $apps.Count + ')</h2><details><summary>Mostrar aplicaciones instaladas</summary>' + (ConvertTo-Tabla $apps @('Nombre', 'Version', 'Editor', 'FechaInstalacion', 'TamanoMB', 'Ambito')) + '</details>')
[void]$html.Append('<details><summary>Mostrar aplicaciones de Microsoft Store (' + $appsStore.Count + ')</summary>' + (ConvertTo-Tabla $appsStore @('Name', 'Version', 'Publisher')) + '</details>')
[void]$html.Append('</main><footer>Generado por AuditoriaPC.ps1. Auditoria de solo lectura: no se modifico el equipo.</footer></body></html>')

$rutaInforme = Join-Path $carpeta 'Informe.html'
Set-Content -Path $rutaInforme -Value $html.ToString() -Encoding UTF8

Write-Host ''
Write-Host ('Resultado: {0}% conforme | {1} criticos | {2} alertas | {3} apps por actualizar | {4} parches de Windows' -f $puntaje, $nCritico, $nAlerta, $appsDesactualizadas.Count, $parchesWindows.Count) -ForegroundColor Cyan
Write-Host ('Informe:   {0}' -f $rutaInforme)
if (-not $NoAbrir) { try { Start-Process $rutaInforme } catch { } }

# ---------------------------------------------------------------------------
# Acciones opcionales (modifican el equipo, piden confirmacion)
# ---------------------------------------------------------------------------
if ($ActualizarApps) {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Write-Warning 'winget no esta disponible: no se puede actualizar.'
    }
    elseif ($appsDesactualizadas.Count -eq 0) {
        Write-Host 'No hay aplicaciones por actualizar.'
    }
    else {
        $appsDesactualizadas | Format-Table Nombre, Instalada, Disponible -AutoSize | Out-Host
        $r = Read-Host ('Se actualizaran {0} aplicaciones con winget. Las que esten abiertas pueden cerrarse. Continuar? (S/N)' -f $appsDesactualizadas.Count)
        if ($r -match '^[sS]') {
            $ErrorActionPreference = 'Continue'
            & winget.exe upgrade --all --include-unknown --accept-source-agreements --accept-package-agreements 2>&1 |
                Tee-Object -FilePath (Join-Path $carpeta 'winget_upgrade.log')
            $ErrorActionPreference = 'Stop'
        }
    }
}

if ($LimpiarTemporales) {
    $rutas = @($env:TEMP)
    if ($esAdmin) { $rutas += (Join-Path $env:windir 'Temp') }
    $r = Read-Host ('Se borraran archivos con mas de 7 dias en: {0}. Continuar? (S/N)' -f ($rutas -join ', '))
    if ($r -match '^[sS]') {
        $limite = (Get-Date).AddDays(-7)
        $liberado = 0
        foreach ($ruta in $rutas) {
            $viejos = Get-ChildItem -LiteralPath $ruta -Recurse -Force -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $limite }
            foreach ($a in $viejos) {
                try { $t = $a.Length; Remove-Item -LiteralPath $a.FullName -Force -ErrorAction Stop; $liberado += $t } catch { }
            }
        }
        Write-Host ('Espacio liberado: {0} MB' -f [math]::Round($liberado / 1MB, 1))
    }
}