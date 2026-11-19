# UI_Actualizaciones.ps1
# Pagina "Actualizaciones" de PC Care: aplicaciones (winget) y drivers (Windows Update).
# Se carga con "punto" desde PCCare.ps1 una vez creada la ventana, la cola y las tablas base.
# Todo pasa por Add-Tarea: queda en la cola, en el historial y se puede reanudar si PC Care se cierra.

$CarpetaRespaldoDrivers = Join-Path $CarpetaDatos 'RespaldoDrivers'

$tApps = New-Tabla 'Nombre', 'Id', 'Version', 'Disponible', 'Origen', 'Estado', 'Tipo'
$tDrvPend = New-Tabla 'UpdateId', 'Titulo', 'Dispositivo', 'Clase', 'Proveedor', 'Fecha', 'TamanoMB', 'Estado'
$tDrvInst = New-Tabla 'Dispositivo', 'Clase', 'Proveedor', 'Version', 'Fecha', 'Nota'
$ui.gridApps.ItemsSource = $tApps.DefaultView
$ui.gridDrvPend.ItemsSource = $tDrvPend.DefaultView
$ui.gridDrvInst.ItemsSource = $tDrvInst.DefaultView

function Update-ResumenAct {
    $pend = @($tApps.Select("Disponible <> ''")).Count
    $terceros = @($tApps.Select("Tipo = 'Terceros'")).Count
    $manual = @($tApps.Select("Estado = 'Manual (sin catálogo)'")).Count
    $ui.txtResApps.Text = '{0} apps ({1} de terceros) | {2} por actualizar | {3} de terceros sin catálogo' -f $tApps.Rows.Count, $terceros, $pend, $manual
    $ui.tabApps.Header = 'Aplicaciones ({0})' -f $pend
    $antiguos = @($tDrvInst.Select("Nota LIKE 'Antiguo*'")).Count
    $ui.txtResDrv.Text = '{0} por actualizar | {1} instalados de terceros | {2} antiguos' -f $tDrvPend.Rows.Count, $tDrvInst.Rows.Count, $antiguos
    $ui.tabDrivers.Header = 'Drivers ({0})' -f $tDrvPend.Rows.Count
}

function Update-FiltroApps {
    $partes = @()
    if ($ui.chkTerceros.IsChecked) { $partes += "Tipo = 'Terceros'" }
    if ($ui.chkSoloPend.IsChecked) { $partes += "Disponible <> ''" }
    $tApps.DefaultView.RowFilter = ($partes -join ' AND ')
}

function Get-FilasMarcadasAct {
    # Filas marcadas tal como se ven en la grilla (respeta el filtro)
    param([System.Data.DataTable]$Tabla)
    foreach ($v in $Tabla.DefaultView) { if ($v['Sel'] -eq $true) { $v.Row } }
}

# Aplicaciones que el usuario decidio no actualizar en este equipo (una por linea; borrar la linea para volver a ofrecerla)
$rutaIgnoradas = Join-Path $env:LOCALAPPDATA 'PCCare\ignoradas.txt'
$script:ignoradas = @{}
try {
    foreach ($r in @($rutaIgnoradas, (Join-Path $env:LOCALAPPDATA 'ActualizadorPC\ignoradas.txt'))) {
        if (Test-Path -LiteralPath $r) {
            foreach ($l in (Get-Content -LiteralPath $r -Encoding UTF8)) { if ($l.Trim()) { $script:ignoradas[$l.Trim()] = $true } }
        }
    }
}
catch { }

# ---------------------------------------------------------------------------
# Analisis
# ---------------------------------------------------------------------------
function Start-AnalisisApps {
    Add-Tarea 'Analizando aplicaciones (winget)' $sbAnalizarApps @{} {
        param($res, $ctx, $fallo)
        if ($fallo) { $ui.txtActAviso.Text = 'No se pudo analizar las aplicaciones: ' + $fallo; return }
        $tApps.Rows.Clear()
        foreach ($a in $res) {
            if ($a.Id -match '^(MSIX\\|ARP\\\w+\\\w+\\)?(Microsoft|Windows)' -or $a.Nombre -match '^(Microsoft|Windows)\b') { $tipo = 'Microsoft' }
            else { $tipo = 'Terceros' }
            $disponible = $a.Disponible
            if ($disponible -and $script:ignoradas.ContainsKey([string]$a.Id)) { $estado = 'Ignorada'; $disponible = '' }
            elseif ($disponible) { $estado = 'Pendiente' }
            elseif ($a.Origen) { $estado = 'Al día' }
            elseif ($a.Id -like 'MSIX\*') { $estado = 'Microsoft Store' }
            else { $estado = 'Manual (sin catálogo)' }
            [void]$tApps.Rows.Add($false, $a.Nombre, $a.Id, $a.Version, $disponible, $a.Origen, $estado, $tipo)
        }
        $tApps.DefaultView.Sort = 'Disponible DESC, Estado DESC, Nombre ASC'
        Update-ResumenAct
        $ui.txtActAviso.Text = 'Análisis de aplicaciones terminado. Marca las que quieras actualizar o usa "Actualizar todas".'
        Write-Registro ('Aplicaciones detectadas: {0}' -f $tApps.Rows.Count)
    }
}

function Start-AnalisisDrivers {
    Add-Tarea 'Analizando drivers (Windows Update, puede tardar unos minutos)' $sbAnalizarDrivers @{} {
        param($res, $ctx, $fallo)
        if ($fallo -or -not $res) { return }
        $d = $res[0]
        $tDrvPend.Rows.Clear()
        $tDrvInst.Rows.Clear()
        foreach ($p in $d.Pendientes) {
            [void]$tDrvPend.Rows.Add($false, $p.UpdateId, $p.Titulo, $p.Dispositivo, $p.Clase, $p.Proveedor, $p.Fecha, $p.TamanoMB, 'Pendiente')
        }
        foreach ($i in $d.Instalados) {
            [void]$tDrvInst.Rows.Add($false, $i.Dispositivo, $i.Clase, $i.Proveedor, $i.Version, $i.Fecha, $i.Nota)
        }
        $tDrvInst.DefaultView.Sort = 'Nota DESC, Clase ASC, Dispositivo ASC'
        $ui.panelHerr.Children.Clear()
        foreach ($h in $d.Herramientas) {
            $boton = New-Object System.Windows.Controls.Button
            if ($h.Url) { $boton.Content = $h.Nombre }
            elseif ($h.Instalada) { $boton.Content = $h.Nombre + ' (instalada)' }
            else { $boton.Content = 'Instalar ' + $h.Nombre }
            $boton.Tag = $h
            $boton.Margin = '0,4,8,4'
            $boton.Padding = '10,4,10,4'
            $boton.Add_Click($clicHerramienta)
            [void]$ui.panelHerr.Children.Add($boton)
        }
        if (@($d.Herramientas).Count -gt 0) { $ui.txtFabricante.Text = 'Equipo: {0}. Herramientas oficiales para lo que Windows Update no ofrece:' -f $d.Fabricante }
        else { $ui.txtFabricante.Text = 'Equipo: {0}. Sin herramienta oficial reconocida: los drivers que falten se bajan de la web de soporte del fabricante.' -f $d.Fabricante }
        Update-ResumenAct
        if ($d.Aviso) { Write-Registro $d.Aviso }
        Write-Registro ('Drivers pendientes: {0} (origen: {1}). Equipo: {2}' -f $tDrvPend.Rows.Count, $d.Origen, $d.Fabricante)
    }
}

function Start-AnalisisActualizaciones {
    $ui.txtActAviso.Text = 'Analizando... los resultados aparecen en las pestañas Aplicaciones y Drivers.'
    Start-AnalisisApps
    Start-AnalisisDrivers
}

# ---------------------------------------------------------------------------
# Herramientas oficiales del fabricante
# ---------------------------------------------------------------------------
$clicHerramienta = {
    param($origen, $e)
    $h = $origen.Tag
    if ($h.Url) { Start-Process $h.Url; return }
    if ($h.Instalada) {
        [void][System.Windows.MessageBox]::Show(('{0} ya está instalada. Ábrela desde el menú Inicio para buscar e instalar drivers.' -f $h.Nombre), 'PC Care')
        return
    }
    $msg = 'Se instalará {0} con winget (herramienta oficial del fabricante). ¿Continuar?' -f $h.Nombre
    if (-not (Confirm-Accion $msg 'Instalar herramienta')) { return }
    Add-Tarea ('Instalando ' + $h.Nombre) $sbInstalarHerramienta @{ Id = [string]$h.Id; Simular = (Test-Simulacion) } {
        param($res, $h, $fallo)
        if ($fallo -or -not $res) { return }
        foreach ($l in $res[0].Lineas) { Write-Registro ('   ' + $l) }
        if ($res[0].Simulado) { return }
        if ($res[0].Codigo -eq 0) {
            $h.Instalada = $true
            [void][System.Windows.MessageBox]::Show(('{0} quedó instalada. Ábrela desde el menú Inicio para buscar e instalar drivers.' -f $h.Nombre), 'PC Care')
        }
        else { Write-Registro ('No se pudo instalar {0} (código 0x{1:X8}).' -f $h.Nombre, $res[0].Codigo) }
    } $h -Opciones ([string]$h.Nombre)
}

# ---------------------------------------------------------------------------
# Aplicaciones
# ---------------------------------------------------------------------------
function Add-TareaApp {
    param([string]$Id, [string]$Nombre, [bool]$Reinstalar, $Fila)
    if ($Reinstalar) { $titulo = 'Reinstalando ' } else { $titulo = 'Actualizando ' }
    $detalle = '{0} ({1})' -f $Nombre, $Id
    if ($Fila) { $detalle = '{0} ({1}): {2} a {3}' -f $Nombre, $Id, $Fila['Version'], $Fila['Disponible'] }
    Add-Tarea ($titulo + $Nombre) $sbActualizarApp @{ Id = $Id; Reinstalar = $Reinstalar; Simular = (Test-Simulacion) } {
        param($res, $fila, $fallo)
        if ($fallo -or -not $res) { if ($fila) { $fila['Estado'] = 'Error' }; return }
        $r = $res[0]
        foreach ($l in $r.Lineas) { Write-Registro ('   ' + $l) }
        if ($r.Simulado) { if ($fila) { $fila['Estado'] = 'Simulado'; $fila['Sel'] = $false }; return }
        if ($r.Codigo -eq 0) {
            if ($fila) {
                $fila['Estado'] = 'Actualizado'
                $fila['Version'] = $fila['Disponible']
                $fila['Disponible'] = ''
                $fila['Sel'] = $false
            }
        }
        else {
            if ($fila) { $fila['Estado'] = 'Error 0x{0:X8}' -f $r.Codigo }
            Write-Registro '   Si el mensaje habla de una tecnología de instalación diferente, marca la fila y usa "Reinstalar seleccionadas".'
        }
        Update-ResumenAct
    } $Fila -Opciones $detalle
}

function Start-ActualizacionApp {
    param([System.Data.DataRow]$Fila, [switch]$Reinstalar)
    if (-not $Fila['Disponible'] -or $Fila['Estado'] -in @('En cola', 'Actualizado')) { return }
    if ([string]$Fila['Id'] -match '…$') {
        $Fila['Estado'] = 'Id truncado'
        Write-Registro ('No se puede actualizar "{0}": winget devolvió el Id recortado.' -f $Fila['Nombre'])
        return
    }
    $Fila['Estado'] = 'En cola'
    Add-TareaApp -Id ([string]$Fila['Id']) -Nombre ([string]$Fila['Nombre']) -Reinstalar ([bool]$Reinstalar) -Fila $Fila
}

# ---------------------------------------------------------------------------
# Drivers
# ---------------------------------------------------------------------------
function Add-TareaDrivers {
    param([string[]]$Ids, [bool]$Punto, [bool]$Respaldo, [string]$Opciones, $Filas)
    $param = @{ Ids = [string[]]$Ids; Punto = $Punto; Respaldo = $Respaldo; Carpeta = $CarpetaRespaldoDrivers; Simular = (Test-Simulacion) }
    Add-Tarea ('Instalando {0} drivers' -f @($Ids).Count) $sbInstalarDrivers $param {
        param($res, $filas, $fallo)
        if ($fallo -or -not $res) { foreach ($f in @($filas)) { if ($f) { $f['Estado'] = 'Error' } }; return }
        $r = $res[0]
        foreach ($m in $r.Mensajes) { Write-Registro ('   ' + $m) }
        foreach ($f in @($filas)) {
            if (-not $f) { continue }
            $id = [string]$f['UpdateId']
            if ($r.Resultados.ContainsKey($id)) { $f['Estado'] = $r.Resultados[$id] } else { $f['Estado'] = 'No aplicado' }
            $f['Sel'] = $false
        }
        if (@($r.Mensajes | Where-Object { $_ -like 'REINICIO*' }).Count -gt 0) {
            [void][System.Windows.MessageBox]::Show('Los drivers se instalaron. Reinicia el equipo para terminar de aplicarlos.', 'PC Care')
        }
    } $Filas -Opciones $Opciones
}

function Start-InstalacionDrivers {
    param([System.Data.DataRow[]]$Filas)
    $Filas = @($Filas | Where-Object { $_['Estado'] -eq 'Pendiente' })
    if ($Filas.Count -eq 0) { return }
    $lista = ($Filas | ForEach-Object { '  - ' + $_['Titulo'] }) -join "`n"
    $msg = "Se instalarán {0} drivers desde Windows Update:`n`n{1}`n`nLa pantalla, la red o el audio pueden cortarse unos segundos y puede requerirse un reinicio. ¿Continuar?" -f $Filas.Count, $lista
    if (-not (Confirm-Accion $msg 'Instalar drivers')) { return }
    foreach ($f in $Filas) { $f['Estado'] = 'En cola' }
    $titulos = (@($Filas | ForEach-Object { [string]$_['Titulo'] }) -join '; ')
    Add-TareaDrivers -Ids ([string[]]@($Filas | ForEach-Object { [string]$_['UpdateId'] })) -Punto ([bool]$ui.chkDrvPunto.IsChecked) -Respaldo ([bool]$ui.chkDrvRespaldo.IsChecked) -Opciones (Get-TextoCorto $titulos 400) -Filas $Filas
}

function Start-StoreActualizar {
    Add-Tarea 'Solicitando actualizaciones a Microsoft Store' $sbStore @{ Simular = (Test-Simulacion) } {
        param($res, $ctx, $fallo)
        if ($fallo) { return }
        if ($res -and [string]$res[0] -eq 'simulado') { Write-Registro 'SIMULACIÓN: se pediría a Microsoft Store que actualice sus aplicaciones.'; return }
        Write-Registro 'Microsoft Store está actualizando sus aplicaciones en segundo plano. Vuelve a analizar en unos minutos.'
    }
}

# ---------------------------------------------------------------------------
# Reanudacion despues de un cierre
# ---------------------------------------------------------------------------
$script:Reanudadores['AnalisisApps'] = { param($p, $reg) Start-AnalisisApps }
$script:Reanudadores['AnalisisDrivers'] = { param($p, $reg) Start-AnalisisDrivers }
$script:Reanudadores['Store'] = { param($p, $reg) Start-StoreActualizar }
$script:Reanudadores['ActualizarApp'] = {
    param($p, $reg)
    $nombre = ([string]$reg.Nombre) -replace '^(Actualizando|Reinstalando) ', ''
    Add-TareaApp -Id ([string]$p['Id']) -Nombre $nombre -Reinstalar ([bool]$p['Reinstalar']) -Fila $null
}
$script:Reanudadores['InstalarDrivers'] = {
    param($p, $reg)
    Add-TareaDrivers -Ids ([string[]]@($p['Ids'])) -Punto ([bool]$p['Punto']) -Respaldo ([bool]$p['Respaldo']) -Opciones ([string]$reg.Opciones) -Filas $null
}

# ---------------------------------------------------------------------------
# Eventos de la pagina
# ---------------------------------------------------------------------------
$ui.btnActAnalizar.Add_Click({ Start-AnalisisActualizaciones })
$ui.chkSoloPend.Add_Click({ Update-FiltroApps })
$ui.chkTerceros.Add_Click({ Update-FiltroApps })
$ui.btnAppsReinst.Add_Click({
        $filas = @(Get-FilasMarcadasAct $tApps)
        if ($filas.Count -eq 0) { return }
        $lista = ($filas | ForEach-Object { '  - ' + $_['Nombre'] }) -join "`n"
        $msg = "Se desinstalarán y volverán a instalar {0} aplicaciones:`n`n{1}`n`nSi la instalación falla, la aplicación quedará desinstalada. Algunas pierden su configuración al reinstalar. ¿Continuar?" -f $filas.Count, $lista
        if (-not (Confirm-Accion $msg 'Reinstalar')) { return }
        foreach ($f in $filas) { Start-ActualizacionApp $f -Reinstalar }
    })
$ui.btnAppsIgnorar.Add_Click({
        $filas = @(Get-FilasMarcadasAct $tApps)
        if ($filas.Count -eq 0) { return }
        foreach ($f in $filas) {
            $script:ignoradas[[string]$f['Id']] = $true
            $f['Estado'] = 'Ignorada'
            $f['Disponible'] = ''
            $f['Sel'] = $false
        }
        try {
            New-Item -ItemType Directory -Path (Split-Path $rutaIgnoradas) -Force | Out-Null
            Set-Content -LiteralPath $rutaIgnoradas -Value @($script:ignoradas.Keys) -Encoding UTF8
            Write-Registro ('Ignoradas guardadas en ' + $rutaIgnoradas)
        }
        catch { Write-Registro ('No se pudo guardar la lista de ignoradas: ' + $_.Exception.Message) }
        Update-ResumenAct
    })
$ui.btnStore.Add_Click({ Start-StoreActualizar })
$ui.btnAppsTodo.Add_Click({
        $filas = @($tApps.Select("Disponible <> ''"))
        if ($filas.Count -eq 0) { return }
        $msg = 'Se actualizarán {0} aplicaciones. Las que estén abiertas pueden cerrarse. ¿Continuar?' -f $filas.Count
        if (-not (Confirm-Accion $msg 'Actualizar todas')) { return }
        foreach ($f in $filas) { Start-ActualizacionApp $f }
    })
$ui.btnAppsSel.Add_Click({
        foreach ($f in (Get-FilasMarcadasAct $tApps)) { Start-ActualizacionApp $f }
    })
$ui.btnDrvTodo.Add_Click({ Start-InstalacionDrivers @($tDrvPend.Select()) })
$ui.btnDrvSel.Add_Click({ Start-InstalacionDrivers (Get-FilasMarcadasAct $tDrvPend) })

# Boton por fila: el clic sube hasta la grilla y la fila viaja en el DataContext del boton
$clicFilaApp = [System.Windows.RoutedEventHandler] {
    param($origen, $e)
    $b = $e.OriginalSource
    if ($b -is [System.Windows.Controls.Button] -and $b.DataContext -is [System.Data.DataRowView]) { Start-ActualizacionApp $b.DataContext.Row }
}
$clicFilaDrv = [System.Windows.RoutedEventHandler] {
    param($origen, $e)
    $b = $e.OriginalSource
    if ($b -is [System.Windows.Controls.Button] -and $b.DataContext -is [System.Data.DataRowView]) { Start-InstalacionDrivers @($b.DataContext.Row) }
}
$ui.gridApps.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $clicFilaApp)
$ui.gridDrvPend.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $clicFilaDrv)

Update-FiltroApps
