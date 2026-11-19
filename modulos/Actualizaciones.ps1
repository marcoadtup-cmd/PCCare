# Actualizaciones.ps1
# Motor en segundo plano del modulo "Actualizaciones": aplicaciones (winget) y drivers (Windows Update).
# Se carga con "punto" desde PCCare.ps1. Cada tarea corre en su propio hilo y recibe las funciones de
# $ayudaActualizaciones a traves del parametro -Ayuda. Las tareas que modifican el equipo aceptan -Simular.
# No usa repositorios de drivers de terceros: solo winget y Windows Update / Microsoft Update (firmados WHQL).

$ayudaActualizaciones = {
    function Invoke-Exe {
        param([string]$Archivo, [string]$Argumentos)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Archivo
        $psi.Arguments = $Argumentos
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $p = [System.Diagnostics.Process]::Start($psi)
        $tareaError = $p.StandardError.ReadToEndAsync()
        $salida = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        # Quita las animaciones de progreso: de cada linea queda lo ultimo escrito tras un retorno de carro
        $lineas = @($salida -split "`n" | ForEach-Object { (($_ -split "`r") | Where-Object { $_.Trim() } | Select-Object -Last 1) } | Where-Object { $_ })
        [pscustomobject]@{ Codigo = $p.ExitCode; Lineas = $lineas; Error = $tareaError.Result }
    }

    function Get-RutaWinget {
        $c = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
        return $null
    }

    function Get-Campo {
        param([string]$Linea, [int[]]$Inicios, [int]$Indice)
        if ($Indice -ge $Inicios.Count -or $Inicios[$Indice] -ge $Linea.Length) { return '' }
        if ($Indice + 1 -lt $Inicios.Count) { $fin = [math]::Min($Inicios[$Indice + 1], $Linea.Length) }
        else { $fin = $Linea.Length }
        return $Linea.Substring($Inicios[$Indice], $fin - $Inicios[$Indice]).Trim()
    }

    function Get-BusquedaDrivers {
        # Drivers pendientes en Microsoft Update, incluidos los "opcionales" que Windows no instala solo.
        # Si Microsoft Update no responde, usa el origen por defecto del equipo.
        $sesion = New-Object -ComObject Microsoft.Update.Session
        $criterios = @(
            "IsInstalled=0 and Type='Driver' and IsHidden=0",
            "IsInstalled=0 and Type='Driver' and IsHidden=0 and DeploymentAction='OptionalInstallation'"
        )
        $idMU = '7971f918-a847-4430-9279-4a52d1efe18d'
        $vistos = @{}
        $lista = New-Object System.Collections.ArrayList
        $origen = ''
        $errores = New-Object System.Collections.Generic.List[string]
        foreach ($modo in @('Microsoft Update', 'Windows Update (origen por defecto)')) {
            foreach ($c in $criterios) {
                try {
                    $buscador = $sesion.CreateUpdateSearcher()
                    if ($modo -eq 'Microsoft Update') {
                        try { [void](New-Object -ComObject Microsoft.Update.ServiceManager).AddService2($idMU, 7, '') } catch { }
                        $buscador.ServerSelection = 3
                        $buscador.ServiceID = $idMU
                    }
                    $r = $buscador.Search($c)
                    foreach ($u in $r.Updates) {
                        $id = [string]$u.Identity.UpdateID
                        if (-not $vistos.ContainsKey($id)) { $vistos[$id] = $true; [void]$lista.Add($u) }
                    }
                    if (-not $origen) { $origen = $modo }
                }
                catch { $errores.Add($_.Exception.Message) }
            }
            if ($origen) { break }
        }
        if (-not $origen) { throw ('Windows Update no respondio: ' + ($errores -join ' / ')) }
        [pscustomobject]@{ Sesion = $sesion; Updates = $lista; Origen = $origen }
    }
}

$sbAnalizarApps = {
    param([string]$Ayuda)
    . ([scriptblock]::Create($Ayuda))
    $winget = Get-RutaWinget
    if (-not $winget) { throw 'winget no esta disponible. Instala "Instalador de aplicacion" desde Microsoft Store.' }
    $r = Invoke-Exe $winget 'list --accept-source-agreements --disable-interactivity'
    $inicios = $null
    for ($i = 0; $i -lt $r.Lineas.Count; $i++) {
        $linea = [string]$r.Lineas[$i]
        if ($linea -match '^-{10,}\s*$' -and $i -gt 0) {
            $inicios = @([regex]::Matches([string]$r.Lineas[$i - 1], '\S+') | ForEach-Object { $_.Index })
            continue
        }
        if ($null -eq $inicios -or $inicios.Count -lt 3) { continue }
        $id = Get-Campo $linea $inicios 1
        $version = Get-Campo $linea $inicios 2
        if (-not $id -or -not $version) { continue }
        $disponible = ''
        $origen = ''
        if ($inicios.Count -ge 5) { $disponible = Get-Campo $linea $inicios 3; $origen = Get-Campo $linea $inicios 4 }
        elseif ($inicios.Count -eq 4) { $origen = Get-Campo $linea $inicios 3 }
        [pscustomobject]@{
            Nombre     = Get-Campo $linea $inicios 0
            Id         = $id
            Version    = $version
            Disponible = $disponible
            Origen     = $origen
        }
    }
}

$sbActualizarApp = {
    param([string]$Ayuda, [string]$Id, [bool]$Reinstalar, [bool]$Simular)
    . ([scriptblock]::Create($Ayuda))
    if ($Simular) {
        $accion = 'actualizaría'
        if ($Reinstalar) { $accion = 'desinstalaría y volvería a instalar' }
        return [pscustomobject]@{ Codigo = 0; Simulado = $true; Lineas = @('SIMULACIÓN: se {0} {1} con winget. No se cambió nada.' -f $accion, $Id) }
    }
    $winget = Get-RutaWinget
    if (-not $winget) { throw 'winget no esta disponible.' }
    $comunes = '--id "{0}" --exact --silent --accept-source-agreements --disable-interactivity' -f $Id
    if (-not $Reinstalar) {
        return Invoke-Exe $winget ('upgrade ' + $comunes + ' --include-unknown --accept-package-agreements')
    }
    $d = Invoke-Exe $winget ('uninstall ' + $comunes)
    if ($d.Codigo -ne 0) {
        return [pscustomobject]@{ Codigo = $d.Codigo; Lineas = @('No se pudo desinstalar; la version actual sigue instalada.') + $d.Lineas }
    }
    $i = Invoke-Exe $winget ('install ' + $comunes + ' --accept-package-agreements')
    $lineas = @($d.Lineas) + @($i.Lineas)
    if ($i.Codigo -ne 0) { $lineas += ('ATENCION: se desinstalo pero la instalacion fallo. Instala manualmente: winget install --id "{0}" --exact' -f $Id) }
    [pscustomobject]@{ Codigo = $i.Codigo; Lineas = $lineas }
}

$sbInstalarHerramienta = {
    param([string]$Ayuda, [string]$Id, [bool]$Simular)
    . ([scriptblock]::Create($Ayuda))
    if ($Simular) { return [pscustomobject]@{ Codigo = 0; Simulado = $true; Lineas = @('SIMULACIÓN: se instalaría {0} con winget. No se cambió nada.' -f $Id) } }
    $winget = Get-RutaWinget
    if (-not $winget) { throw 'winget no esta disponible.' }
    Invoke-Exe $winget ('install --id "{0}" --exact --silent --accept-source-agreements --accept-package-agreements --disable-interactivity' -f $Id)
}

$sbStore = {
    param([string]$Ayuda, [bool]$Simular)
    if ($Simular) { return 'simulado' }
    Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' -ErrorAction Stop |
        Invoke-CimMethod -MethodName UpdateScanMethod -ErrorAction Stop | Out-Null
    'ok'
}

$sbAnalizarDrivers = {
    param([string]$Ayuda)
    . ([scriptblock]::Create($Ayuda))
    $hoy = Get-Date
    $instalados = @(Get-CimInstance Win32_PnPSignedDriver |
            Where-Object { $_.DeviceName -and $_.DriverProviderName -and $_.DriverProviderName -ne 'Microsoft' } |
            Sort-Object DeviceClass, DeviceName, DriverVersion -Unique |
            ForEach-Object {
                $fecha = ''
                $nota = ''
                if ($_.DriverDate) {
                    $f = [datetime]$_.DriverDate
                    $fecha = $f.ToString('yyyy-MM-dd')
                    $anios = [int][math]::Floor(($hoy - $f).TotalDays / 365)
                    if ($f.Year -lt 2006) { $nota = 'Fecha no fiable' }
                    elseif ($anios -ge 3) { $nota = 'Antiguo ({0} años)' -f $anios }
                }
                [pscustomobject]@{
                    Dispositivo = [string]$_.DeviceName
                    Clase       = [string]$_.DeviceClass
                    Proveedor   = [string]$_.DriverProviderName
                    Version     = [string]$_.DriverVersion
                    Fecha       = $fecha
                    Nota        = $nota
                }
            })
    $pendientes = @()
    $aviso = ''
    $origen = ''
    try {
        $b = Get-BusquedaDrivers
        $origen = $b.Origen
        $pendientes = @(foreach ($u in $b.Updates) {
                $fecha = ''
                try { if ($u.DriverVerDate) { $fecha = ([datetime]$u.DriverVerDate).ToString('yyyy-MM-dd') } } catch { }
                [pscustomobject]@{
                    UpdateId    = [string]$u.Identity.UpdateID
                    Titulo      = [string]$u.Title
                    Dispositivo = [string]$u.DriverModel
                    Clase       = [string]$u.DriverClass
                    Proveedor   = [string]$u.DriverProvider
                    Fecha       = $fecha
                    TamanoMB    = [string][math]::Round($u.MaxDownloadSize / 1MB, 1)
                }
            })
    }
    catch { $aviso = 'No se pudo consultar Windows Update: ' + $_.Exception.Message }

    # Herramientas oficiales segun el fabricante del equipo y de sus componentes
    $cs = Get-CimInstance Win32_ComputerSystem
    $marca = [string]$cs.Manufacturer
    $proveedores = (@($instalados | ForEach-Object { $_.Proveedor } | Sort-Object -Unique)) -join ' | '
    $candidatas = @(
        @{ Nombre = 'Dell Command Update'; Id = 'Dell.CommandUpdate'; Aplica = ($marca -match 'Dell') },
        @{ Nombre = 'Lenovo System Update'; Id = 'Lenovo.SystemUpdate'; Aplica = ($marca -match 'Lenovo') },
        @{ Nombre = 'HP Support Assistant'; Id = 'HPInc.HPSupportAssistant'; Aplica = ($marca -match '^(HP|Hewlett)') },
        @{ Nombre = 'Intel Driver & Support Assistant'; Id = 'Intel.IntelDriverAndSupportAssistant'; Aplica = ($proveedores -match 'Intel') },
        @{ Nombre = 'Drivers NVIDIA (sitio oficial)'; Url = 'https://www.nvidia.com/Download/index.aspx'; Aplica = ($proveedores -match 'NVIDIA') },
        @{ Nombre = 'Drivers AMD (sitio oficial)'; Url = 'https://www.amd.com/en/support/download/drivers.html'; Aplica = ($proveedores -match 'AMD|Advanced Micro') }
    )
    $winget = Get-RutaWinget
    $herramientas = @(foreach ($c in $candidatas) {
            if (-not $c.Aplica) { continue }
            if ($c.Url) { [pscustomobject]@{ Nombre = $c.Nombre; Id = ''; Url = $c.Url; Instalada = $false }; continue }
            if (-not $winget) { continue }
            $comunes = '--id "{0}" --exact --accept-source-agreements --disable-interactivity' -f $c.Id
            if ((Invoke-Exe $winget ('show ' + $comunes)).Codigo -ne 0) { continue }
            $instalada = (Invoke-Exe $winget ('list ' + $comunes)).Codigo -eq 0
            [pscustomobject]@{ Nombre = $c.Nombre; Id = $c.Id; Url = ''; Instalada = $instalada }
        })
    [pscustomobject]@{
        Instalados = $instalados; Pendientes = $pendientes; Aviso = $aviso; Origen = $origen
        Fabricante = ('{0} {1}' -f $cs.Manufacturer, $cs.Model).Trim(); Herramientas = $herramientas
    }
}

$sbInstalarDrivers = {
    param([string]$Ayuda, [string[]]$Ids, [bool]$Punto, [bool]$Respaldo, [string]$Carpeta, [bool]$Simular)
    . ([scriptblock]::Create($Ayuda))
    $mensajes = New-Object System.Collections.Generic.List[string]
    $resultados = @{}
    if ($Simular) {
        $mensajes.Add(('SIMULACIÓN: se instalarían {0} drivers desde Windows Update (con punto de restauración: {1}; con respaldo de drivers: {2}). No se cambió nada.' -f @($Ids).Count, $Punto, $Respaldo))
        foreach ($id in $Ids) { $resultados[[string]$id] = 'Simulado' }
        return [pscustomobject]@{ Mensajes = $mensajes.ToArray(); Resultados = $resultados; Simulado = $true }
    }

    if ($Punto) {
        try {
            Checkpoint-Computer -Description 'ActualizadorPC antes de drivers' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
            $mensajes.Add('Punto de restauracion solicitado (Windows lo omite si ya hubo uno en las ultimas 24 h).')
        }
        catch { $mensajes.Add('AVISO: no se pudo crear el punto de restauracion: ' + $_.Exception.Message) }
    }
    if ($Respaldo) {
        try {
            $destino = Join-Path $Carpeta ('{0}_{1}' -f $env:COMPUTERNAME, (Get-Date).ToString('yyyyMMdd_HHmm'))
            New-Item -ItemType Directory -Path $destino -Force | Out-Null
            $r = Invoke-Exe (Join-Path $env:windir 'System32\pnputil.exe') ('/export-driver * "{0}"' -f $destino)
            $mensajes.Add(('Respaldo de drivers en {0} (codigo {1}).' -f $destino, $r.Codigo))
        }
        catch { $mensajes.Add('AVISO: no se pudo respaldar los drivers: ' + $_.Exception.Message) }
    }

    $b = Get-BusquedaDrivers
    $coleccion = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $b.Updates) {
        if ($Ids -contains [string]$u.Identity.UpdateID) {
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$coleccion.Add($u)
        }
    }
    if ($coleccion.Count -eq 0) {
        $mensajes.Add('Los drivers seleccionados ya no figuran como pendientes.')
    }
    else {
        $descarga = $b.Sesion.CreateUpdateDownloader()
        $descarga.Updates = $coleccion
        [void]$descarga.Download()
        $instalador = $b.Sesion.CreateUpdateInstaller()
        $instalador.Updates = $coleccion
        $res = $instalador.Install()
        for ($n = 0; $n -lt $coleccion.Count; $n++) {
            $codigo = [int]$res.GetUpdateResult($n).ResultCode
            switch ($codigo) {
                2 { $texto = 'Instalado' }
                3 { $texto = 'Instalado con avisos' }
                4 { $texto = 'Error' }
                5 { $texto = 'Cancelado' }
                default { $texto = 'Sin resultado (' + $codigo + ')' }
            }
            $resultados[[string]$coleccion.Item($n).Identity.UpdateID] = $texto
            $mensajes.Add(('{0}: {1}' -f $coleccion.Item($n).Title, $texto))
        }
        if ($res.RebootRequired) { $mensajes.Add('REINICIO REQUERIDO para terminar de aplicar los drivers.') }
    }
    [pscustomobject]@{ Mensajes = $mensajes.ToArray(); Resultados = $resultados; Simulado = $false }
}
