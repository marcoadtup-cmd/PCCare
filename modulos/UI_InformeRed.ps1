# UI_InformeRed.ps1
# Paginas "Informe" (auditoria del equipo) y "Red" (diagnostico de conexion) de PC Care.
# Ejecutan AuditoriaPC.ps1 y OptimizarRed.ps1 desde la cola de tareas, en segundo plano.

$CarpetaInformes = Join-Path $CarpetaDatos 'Informes'
$CarpetaRed = Join-Path $CarpetaDatos 'Red'
$tCambiosRed = New-Tabla 'Nombre', 'Efecto', 'Cmds'
$ui.gridRedCambios.ItemsSource = $tCambiosRed.DefaultView
$script:ultimoInforme = ''

# ---------------------------------------------------------------------------
# Informe
# ---------------------------------------------------------------------------
function Start-Informe {
    param([bool]$OmitirWU = [bool]$ui.chkInfSinWU.IsChecked)
    $modulo = Join-Path $RaizApp 'modulos\AuditoriaPC.ps1'
    $opcion = 'Con búsqueda de parches de Windows'
    if ($OmitirWU) { $opcion = 'Sin búsqueda de parches de Windows' }
    Add-Tarea 'Generando informe de auditoría del equipo' $sbInformeAuditoria @{ Script = $modulo; Salida = $CarpetaInformes; OmitirWU = $OmitirWU } {
        param($res, $ctx, $fallo)
        if ($fallo -or -not $res) { $ui.txtInfEstado.Text = 'No se pudo generar el informe: ' + $fallo; return }
        $r = $res[0]
        $script:ultimoInforme = [string]$r.Informe
        $ui.btnInfAbrir.IsEnabled = $true
        $ui.txtInfEstado.Text = 'Informe listo: {0}% de controles conformes, {1} críticos, {2} alertas, {3} apps por actualizar, {4} parches de Windows. Guardado en {5}' -f $r.Puntaje, $r.Criticos, $r.Alertas, $r.Apps, $r.Parches, $r.Carpeta
        Write-Registro ('Informe generado: ' + $script:ultimoInforme)
    } -Opciones $opcion -AlIniciar { $ui.txtInfEstado.Text = 'Generando el informe... puede tardar uno o dos minutos.' }
    $ui.txtInfEstado.Text = Get-TextoEspera 'Generando el informe... puede tardar uno o dos minutos.'
}

$ui.btnInfGenerar.Add_Click({ Start-Informe })
$ui.btnInfAbrir.Add_Click({
        if ($script:ultimoInforme -and (Test-Path -LiteralPath $script:ultimoInforme)) { Start-Process -FilePath $script:ultimoInforme }
    })
$ui.btnInfCarpeta.Add_Click({
        if (-not (Test-Path -LiteralPath $CarpetaInformes)) { New-Item -ItemType Directory -Path $CarpetaInformes -Force | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $CarpetaInformes)
    })

# ---------------------------------------------------------------------------
# Red
# ---------------------------------------------------------------------------
function Start-RedDiagnostico {
    param([bool]$SinDescarga = (-not [bool]$ui.chkRedDescarga.IsChecked))
    $modulo = Join-Path $RaizApp 'modulos\OptimizarRed.ps1'
    $opcion = 'Con medición de velocidad de descarga (unos 9 MB)'
    if ($SinDescarga) { $opcion = 'Sin medición de velocidad (no gasta datos)' }
    Add-Tarea 'Diagnóstico de red' $sbRedDiagnostico @{ Script = $modulo; Carpeta = $CarpetaRed; SinDescarga = $SinDescarga; MB = 8 } {
        param($res, $ctx, $fallo)
        if ($fallo -or -not $res) { $ui.txtRedInforme.Text = 'No se pudo diagnosticar la red: ' + $fallo; return }
        $r = $res[0]
        $ui.txtRedInforme.Text = [string]$r.Informe
        $tCambiosRed.Rows.Clear()
        foreach ($c in @($r.Cambios)) {
            if ($c -and $c.Nombre) { [void]$tCambiosRed.Rows.Add($false, [string]$c.Nombre, [string]$c.Efecto, (@($c.Cmds) -join "`n")) }
        }
        if ($tCambiosRed.Rows.Count -gt 0) { $ui.txtRedAviso.Text = '{0} mejoras propuestas. Márcalas y pulsa "Aplicar mejoras marcadas".' -f $tCambiosRed.Rows.Count }
        else { $ui.txtRedAviso.Text = 'No hay mejoras propuestas para esta conexión.' }
        Write-Registro ('Diagnóstico de red terminado. Mejoras propuestas: {0}' -f $tCambiosRed.Rows.Count)
    } -Opciones $opcion -AlIniciar { $ui.txtRedInforme.Text = 'Diagnosticando... unos 30 a 60 segundos.' }
    $ui.txtRedInforme.Text = Get-TextoEspera 'Diagnosticando... unos 30 a 60 segundos.'
}

function Start-RedAplicar {
    param([string[]]$Nombres, [switch]$SinConfirmar)
    $nombresAplicar = @()
    if ($Nombres) { $nombresAplicar = @($Nombres) }
    else { $nombresAplicar = @(Get-Marcadas $tCambiosRed | ForEach-Object { [string]$_['Nombre'] }) }
    if ($nombresAplicar.Count -eq 0) { return }
    if (-not $SinConfirmar) {
        $lista = (@(Get-Marcadas $tCambiosRed | ForEach-Object { '  - {0}: {1}' -f $_['Nombre'], $_['Efecto'] }) -join "`n")
        if (-not $lista) { $lista = ($nombresAplicar | ForEach-Object { '  - ' + $_ }) -join "`n" }
        if (-not (Confirm-Accion ("Se aplicarán estos cambios de red:`n`n{0}`n`nSe guarda un archivo para revertirlos. ¿Continuar?" -f $lista) 'Mejoras de red')) { return }
    }
    $modulo = Join-Path $RaizApp 'modulos\OptimizarRed.ps1'
    Add-Tarea 'Aplicando mejoras de red' $sbRedAplicar @{ Script = $modulo; Carpeta = $CarpetaRed; Nombres = [string[]]$nombresAplicar; Simular = (Test-Simulacion) } {
        param($res, $ctx, $fallo)
        if ($fallo -or -not $res) { $ui.txtRedInforme.Text = 'No se pudieron aplicar los cambios: ' + $fallo; return }
        $r = $res[0]
        $ui.txtRedInforme.Text = [string]$r.Informe
        if ($r.Simulado) { Write-Registro ([string]$r.Informe); return }
        if ($r.Revertir) { $ui.txtRedRevertir.Text = 'Para deshacer: ejecuta como administrador ' + $r.Revertir }
        else { $ui.txtRedRevertir.Text = 'No se aplicó ningún cambio.' }
        Write-Registro 'Mejoras de red aplicadas. Revisa el informe en la página Red.'
        $ui.expLog.IsExpanded = $true
    } -Opciones ($nombresAplicar -join '; ')
}

function Start-RedReparar {
    $modulo = Join-Path $RaizApp 'modulos\OptimizarRed.ps1'
    Add-Tarea 'Reparando la pila de red' $sbRedReparar @{ Script = $modulo; Carpeta = $CarpetaRed; Simular = (Test-Simulacion) } {
        param($res, $ctx, $fallo)
        if ($fallo -or -not $res) { $ui.txtRedInforme.Text = 'No se pudo reparar: ' + $fallo; return }
        $ui.txtRedInforme.Text = [string]$res[0].Informe
        if (-not $res[0].Simulado) { [void][System.Windows.MessageBox]::Show('Reinicia el equipo para completar la reparación de red.', 'PC Care') }
    } -Opciones 'ipconfig /flushdns; netsh winsock reset; netsh int ip reset'
}

$script:Reanudadores['Informe'] = { param($p, $reg) Start-Informe -OmitirWU ([bool]$p['OmitirWU']) }
$script:Reanudadores['RedDiagnostico'] = { param($p, $reg) Start-RedDiagnostico -SinDescarga ([bool]$p['SinDescarga']) }
$script:Reanudadores['RedAplicar'] = { param($p, $reg) Start-RedAplicar -Nombres ([string[]]@($p['Nombres'])) -SinConfirmar }

$ui.btnRedDiag.Add_Click({ Start-RedDiagnostico })
$ui.btnRedAplicar.Add_Click({ Start-RedAplicar })
$ui.btnRedReparar.Add_Click({
        $txt = "La reparación reinicia Winsock y la pila IP. Corrige fallos profundos de conexión.`n`nNO se puede revertir, exige reiniciar el equipo y se pierde la conexión unos segundos. Úsala solo si el diagnóstico no encontró otra causa.`n`n¿Continuar?"
        if (-not (Confirm-Accion $txt 'Reparar la pila de red')) { return }
        Start-RedReparar
    })
$ui.btnRedCarpeta.Add_Click({
        if (-not (Test-Path -LiteralPath $CarpetaRed)) { New-Item -ItemType Directory -Path $CarpetaRed -Force | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $CarpetaRed)
    })
