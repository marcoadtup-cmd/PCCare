# Privacidad.ps1
# Limpieza de rastros de privacidad: archivos recientes, Jump Lists, recientes de Office y cookies.
#
# Reglas de diseno (aprobadas el 2026-11-27):
#   - Las cookies van desmarcadas por defecto y con aviso: borrarlas cierra la sesion en los sitios web.
#   - Las cookies se eligen por navegador: el que no marques no se toca (es la lista de excepciones).
#   - Se muestra tamano y cantidad por categoria antes de limpiar.
#   - Respeta el modo simulacion y nunca corre sola (no esta en la ventana al abrir ni en Cuidado inteligente).
#   - Los recientes de Office guardados en el REGISTRO no se tocan: sus claves cambian por version y quedan por confirmar.
#
# $ayudaPrivacidad se suma al texto de ayuda de las tareas en segundo plano y tambien se carga en la interfaz.

$ayudaPrivacidad = {
    function Get-PerfilesNavegador {
        # Carpetas de perfil de un navegador Chromium (Default y Profile N) o de Firefox.
        param([string]$Base, [bool]$Firefox)
        if (-not $Base -or -not (Test-Path -LiteralPath $Base)) { return @() }
        if ($Firefox) { return @(Get-ChildItem -LiteralPath $Base -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
        return @(Get-ChildItem -LiteralPath $Base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } | ForEach-Object { $_.FullName })
    }

    function Get-CategoriasPrivacidad {
        # Cada categoria: carpetas con filtro de archivos (sin subcarpetas), si va marcada por defecto,
        # y el proceso del navegador que debe estar cerrado para borrar sus cookies.
        $ad = $env:APPDATA
        $la = $env:LOCALAPPDATA
        $rec = Join-Path $ad 'Microsoft\Windows\Recent'
        $lista = New-Object System.Collections.Generic.List[object]
        $lista.Add(@{ Id = 'Recientes'; Nombre = 'Archivos recientes del Explorador'; Carpetas = @(@{ Ruta = $rec; Filtro = '*.lnk' }); Marcar = $true; Proceso = ''; Cookies = $false })
        $lista.Add(@{ Id = 'JumpLists'; Nombre = 'Listas de accesos rápidos (Jump Lists) de la barra de tareas'; Carpetas = @(@{ Ruta = (Join-Path $rec 'AutomaticDestinations'); Filtro = '*' }, @{ Ruta = (Join-Path $rec 'CustomDestinations'); Filtro = '*' }); Marcar = $true; Proceso = ''; Cookies = $false })
        $lista.Add(@{ Id = 'OfficeRecientes'; Nombre = 'Accesos recientes de Office (carpeta)'; Carpetas = @(@{ Ruta = (Join-Path $ad 'Microsoft\Office\Recent'); Filtro = '*' }); Marcar = $true; Proceso = ''; Cookies = $false })
        $navegadores = @(
            @{ Id = 'CookiesEdge'; Nombre = 'Cookies de Microsoft Edge'; Base = "$la\Microsoft\Edge\User Data"; Proceso = 'msedge'; Firefox = $false },
            @{ Id = 'CookiesChrome'; Nombre = 'Cookies de Google Chrome'; Base = "$la\Google\Chrome\User Data"; Proceso = 'chrome'; Firefox = $false },
            @{ Id = 'CookiesBrave'; Nombre = 'Cookies de Brave'; Base = "$la\BraveSoftware\Brave-Browser\User Data"; Proceso = 'brave'; Firefox = $false },
            @{ Id = 'CookiesVivaldi'; Nombre = 'Cookies de Vivaldi'; Base = "$la\Vivaldi\User Data"; Proceso = 'vivaldi'; Firefox = $false },
            @{ Id = 'CookiesFirefox'; Nombre = 'Cookies de Mozilla Firefox'; Base = "$ad\Mozilla\Firefox\Profiles"; Proceso = 'firefox'; Firefox = $true }
        )
        foreach ($n in $navegadores) {
            $carpetas = @()
            foreach ($p in (Get-PerfilesNavegador $n.Base $n.Firefox)) {
                if ($n.Firefox) { $carpetas += @{ Ruta = $p; Filtro = 'cookies.sqlite*' } }
                else {
                    $carpetas += @{ Ruta = (Join-Path $p 'Network'); Filtro = 'Cookies*' }
                    $carpetas += @{ Ruta = $p; Filtro = 'Cookies*' }
                }
            }
            if ($carpetas.Count -eq 0) { continue }
            $lista.Add(@{ Id = $n.Id; Nombre = $n.Nombre; Carpetas = $carpetas; Marcar = $false; Proceso = $n.Proceso; Cookies = $true })
        }
        return $lista.ToArray()
    }

    function Get-ArchivosPrivacidad {
        # Solo archivos directos de cada carpeta (sin subcarpetas) y siempre dentro de ella.
        param([hashtable]$Categoria)
        foreach ($c in $Categoria.Carpetas) {
            if (-not $c.Ruta -or -not (Test-Path -LiteralPath $c.Ruta -PathType Container)) { continue }
            $archivos = @()
            try {
                $dir = New-Object System.IO.DirectoryInfo ([System.IO.Path]::GetFullPath([string]$c.Ruta))
                $archivos = @($dir.GetFiles([string]$c.Filtro, [System.IO.SearchOption]::TopDirectoryOnly))
            }
            catch { continue }
            foreach ($f in $archivos) {
                if ($f.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                if ($f.Name -eq 'desktop.ini') { continue }
                $f
            }
        }
    }
}

$sbAnalizarPrivacidad = {
    param([string]$Ayuda)
    . ([scriptblock]::Create($Ayuda))
    foreach ($c in (Get-CategoriasPrivacidad)) {
        $archivos = @(Get-ArchivosPrivacidad $c)
        $bytes = [double]0
        foreach ($f in $archivos) { $bytes += $f.Length }
        $abierto = $false
        if ($c.Proceso) { $abierto = [bool](Get-Process -Name $c.Proceso -ErrorAction SilentlyContinue) }
        [pscustomobject]@{ Id = $c.Id; Nombre = $c.Nombre; Archivos = $archivos.Count; Bytes = $bytes; Marcar = [bool]$c.Marcar; Cookies = [bool]$c.Cookies; Abierto = $abierto }
    }
}

$sbLimpiarPrivacidad = {
    param([string]$Ayuda, [string[]]$Ids, [bool]$Simular)
    . ([scriptblock]::Create($Ayuda))
    $mensajes = New-Object System.Collections.Generic.List[string]
    $total = [double]0
    foreach ($c in (Get-CategoriasPrivacidad)) {
        if ($Ids -notcontains $c.Id) { continue }
        if ($c.Proceso -and (Get-Process -Name $c.Proceso -ErrorAction SilentlyContinue)) {
            $mensajes.Add(('{0}: omitidas porque el navegador está abierto. Ciérralo y repite.' -f $c.Nombre))
            continue
        }
        $raices = @($c.Carpetas | ForEach-Object { [string]$_.Ruta })
        $hechos = 0; $omitidos = 0; $bytes = [double]0
        foreach ($f in @(Get-ArchivosPrivacidad $c)) {
            if (-not (Test-RutaPermitida $f.FullName $raices)) { $omitidos++; continue }
            $t = $f.Length
            if ($Simular) { $hechos++; $bytes += $t; continue }
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $hechos++; $bytes += $t }
            catch { $omitidos++ }
        }
        $total += $bytes
        if ($Simular) { $mensajes.Add(('SIMULACIÓN: {0}: se borrarían {1} archivos ({2}).' -f $c.Nombre, $hechos, (Format-Tamano $bytes))) }
        else { $mensajes.Add(('{0}: {1} archivos borrados ({2}); {3} en uso, omitidos.' -f $c.Nombre, $hechos, (Format-Tamano $bytes), $omitidos)) }
    }
    [pscustomobject]@{ Mensajes = $mensajes.ToArray(); Bytes = $total; Simulado = $Simular }
}
