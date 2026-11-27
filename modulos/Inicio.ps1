# Ventana de tareas al abrir: lista de tareas, estado de cada fila y texto de detalle.
# Solo logica (sin interfaz) para poder probarla en la autoprueba.

# Todas son de solo lectura: analizan el equipo y no cambian nada.
$script:TareasInicio = @(
    [pscustomobject]@{ Id = 'Restauracion'; Funcion = 'Start-LecturaRestauracion'; Nombre = 'Leer puntos de restauración'; Que = 'Consulta el último punto de restauración de Windows.'; Tiempo = 'menos de 5 s' }
    [pscustomobject]@{ Id = 'Basura'; Funcion = 'Start-AnalisisBasura'; Nombre = 'Analizar archivos basura'; Que = 'Mide temporales, cachés, informes de error y Papelera. No borra nada.'; Tiempo = '10 a 60 s' }
    [pscustomobject]@{ Id = 'Seguridad'; Funcion = 'Start-Seguridad'; Nombre = 'Revisar la seguridad de Windows'; Que = 'Comprueba el estado de seguridad del equipo y qué antivirus está activo. Solo lectura.'; Tiempo = '5 a 20 s' }
    [pscustomobject]@{ Id = 'Inicio'; Funcion = 'Start-AnalisisInicio'; Nombre = 'Analizar programas de inicio'; Que = 'Lista lo que se abre junto con Windows. No cambia nada.'; Tiempo = 'menos de 5 s' }
    [pscustomobject]@{ Id = 'Diagnostico'; Funcion = 'Start-Diagnostico'; Nombre = 'Diagnosticar problemas comunes'; Que = 'Detecta problemas de rendimiento y mantenimiento. No aplica correcciones.'; Tiempo = '20 a 90 s' }
    [pscustomobject]@{ Id = 'Procesos'; Funcion = 'Start-Procesos'; Nombre = 'Listar programas en memoria'; Que = 'Muestra qué programas consumen memoria ahora.'; Tiempo = 'menos de 5 s' }
    [pscustomobject]@{ Id = 'Registro'; Funcion = 'Start-AnalisisRegistro'; Nombre = 'Analizar el registro'; Que = 'Busca entradas inválidas del registro. No las limpia.'; Tiempo = '5 a 20 s' }
)

function Get-EstadoFilaInicio {
    # Resume los registros de tareas de una fila en un codigo, un texto y si ya termino.
    param([object[]]$Regs, [bool]$Iniciada)
    if (-not $Iniciada) { return [pscustomobject]@{ Codigo = 'Pendiente'; Texto = ''; Final = $false } }
    if ($null -eq $Regs -or $Regs.Count -eq 0) { return [pscustomobject]@{ Codigo = 'SinTarea'; Texto = 'Ya estaba en cola'; Final = $true } }
    $estados = New-Object System.Collections.Generic.List[string]
    foreach ($r in $Regs) { $estados.Add([string]$r.Estado) }
    if ($estados.Contains('En curso')) { return [pscustomobject]@{ Codigo = 'EnCurso'; Texto = 'En curso...'; Final = $false } }
    if ($estados.Contains('Pendiente')) { return [pscustomobject]@{ Codigo = 'EnEspera'; Texto = 'En espera'; Final = $false } }
    if ($estados.Contains('Error')) { return [pscustomobject]@{ Codigo = 'Error'; Texto = '✖ Error'; Final = $true } }
    if ($estados.Contains('Cancelada')) { return [pscustomobject]@{ Codigo = 'Cancelada'; Texto = 'Cancelada'; Final = $true } }
    if ($estados.Contains('Interrumpida')) { return [pscustomobject]@{ Codigo = 'Interrumpida'; Texto = 'Interrumpida'; Final = $true } }
    return [pscustomobject]@{ Codigo = 'Listo'; Texto = '✓ Listo'; Final = $true }
}

function New-TextoDetalleInicio {
    # Texto de la sub-ventana: que se hizo, como termino, el resultado y los mensajes de esa tarea.
    param([string]$Nombre, [string]$Que, [object[]]$Regs, [string[]]$Resumen, [string[]]$Mensajes)
    $s = New-Object System.Text.StringBuilder
    [void]$s.AppendLine((T $Nombre))
    [void]$s.AppendLine((T $Que))
    foreach ($r in $Regs) {
        [void]$s.AppendLine('')
        [void]$s.AppendLine(('{0}: {1}' -f (T 'Estado'), (T ([string]$r.Estado))))
        [void]$s.AppendLine(('{0}: {1}' -f (T 'Modo'), (T ([string]$r.Modo))))
        if ($r.Inicio) { [void]$s.AppendLine(('{0}: {1}' -f (T 'Hora de inicio'), [string]$r.Inicio)) }
        if ($r.Fin) { [void]$s.AppendLine(('{0}: {1}' -f (T 'Hora de fin'), [string]$r.Fin)) }
        if ($r.Detalle) { [void]$s.AppendLine(('{0}: {1}' -f (T 'Detalle del error'), [string]$r.Detalle)) }
    }
    [void]$s.AppendLine('')
    [void]$s.AppendLine('== ' + (T 'Resultado') + ' ==')
    if ($null -eq $Resumen -or $Resumen.Count -eq 0) { [void]$s.AppendLine((T '(sin datos todavía)')) }
    else { foreach ($l in $Resumen) { [void]$s.AppendLine([string]$l) } }
    [void]$s.AppendLine('')
    [void]$s.AppendLine('== ' + (T 'Mensajes durante la tarea') + ' ==')
    if ($null -eq $Mensajes -or $Mensajes.Count -eq 0) { [void]$s.AppendLine((T '(sin mensajes)')) }
    else { foreach ($l in $Mensajes) { [void]$s.AppendLine([string]$l) } }
    return $s.ToString()
}
