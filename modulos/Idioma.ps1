# ===========================================================================
# Idioma.ps1 : interfaz en espanol e ingles (ES / EN)
# Los datos internos siguen en espanol (estados, claves, historial). Solo se
# traduce lo que se muestra. Si falta una traduccion, se muestra el espanol.
# Diccionario: modulos\idioma\en.tsv (ES <TAB> EN). Filas con {0} = plantillas.
# ===========================================================================
$script:IdiomaActual = 'es'
$script:IdiomaElegido = 'es'
$script:IdExacto = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
$script:IdCache = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
$script:IdPlantillas = New-Object System.Collections.ArrayList
$script:IdPrefijos = New-Object System.Collections.ArrayList
$script:IdCargado = $false
$script:IdFallas = 0

function Get-IdiomaSistema {
    # Idioma por defecto: espanol si Windows esta en espanol; en otro caso ingles
    try { if ([System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'es') { return 'es' } } catch { }
    return 'en'
}

function Get-IdiomaGuardado {
    param([string]$RutaConfig)
    try {
        if (Test-Path -LiteralPath $RutaConfig) {
            $txt = Get-Content -LiteralPath $RutaConfig -Raw -Encoding UTF8
            $m = [regex]::Match($txt, '"Idioma"\s*:\s*"(es|en)"')
            if ($m.Success) { return $m.Groups[1].Value }
        }
    }
    catch { }
    return $null
}

function ConvertFrom-EscapeIdioma {
    param([string]$Texto)
    return [regex]::Replace($Texto, '\\(.)', {
            param($m)
            switch ($m.Groups[1].Value) {
                'n' { "`n" }
                't' { "`t" }
                '\' { '\' }
                default { $m.Value }
            }
        })
}

function Import-DiccionarioIdioma {
    param([string]$Ruta)
    $script:IdExacto.Clear(); $script:IdCache.Clear()
    $script:IdPlantillas.Clear(); $script:IdPrefijos.Clear()
    $script:IdCargado = $false
    if (-not (Test-Path -LiteralPath $Ruta)) { return 0 }
    $reTok = [regex]'\{(\d+)(?:,-?\d+)?(?::[^}]*)?\}'
    $n = 0
    foreach ($linea in (Get-Content -LiteralPath $Ruta -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($linea) -or $linea.StartsWith('#')) { continue }
        $i = $linea.IndexOf("`t")
        if ($i -lt 1) { continue }
        $es = ConvertFrom-EscapeIdioma $linea.Substring(0, $i)
        $en = ConvertFrom-EscapeIdioma $linea.Substring($i + 1)
        if ($reTok.IsMatch($es)) {
            # plantilla: las partes fijas se escapan y cada {n} captura el texto variable
            $patron = New-Object System.Text.StringBuilder
            [void]$patron.Append('(?s)^')
            $pos = 0; $fijo = 0
            foreach ($m in $reTok.Matches($es)) {
                $lit = $es.Substring($pos, $m.Index - $pos)
                $fijo += $lit.Length
                [void]$patron.Append([regex]::Escape($lit))
                [void]$patron.Append('(?<g' + $m.Groups[1].Value + '>.*?)')
                $pos = $m.Index + $m.Length
            }
            $lit = $es.Substring($pos); $fijo += $lit.Length
            [void]$patron.Append([regex]::Escape($lit)); [void]$patron.Append('$')
            try {
                $re = New-Object System.Text.RegularExpressions.Regex($patron.ToString())
                [void]$script:IdPlantillas.Add([pscustomobject]@{ Re = $re; En = $en; Peso = $fijo })
                $n++
            }
            catch { $script:IdFallas++ }
        }
        else {
            $script:IdExacto[$es] = $en
            if ($es.EndsWith(' ') -and $es.Trim().Length -ge 3) { [void]$script:IdPrefijos.Add([pscustomobject]@{ Es = $es; En = $en }) }
            $n++
        }
    }
    # mas especificas primero
    $ord = @($script:IdPlantillas | Sort-Object -Property Peso -Descending)
    $script:IdPlantillas.Clear(); foreach ($o in $ord) { [void]$script:IdPlantillas.Add($o) }
    $ordP = @($script:IdPrefijos | Sort-Object { $_.Es.Length } -Descending)
    $script:IdPrefijos.Clear(); foreach ($o in $ordP) { [void]$script:IdPrefijos.Add($o) }
    $script:IdCargado = $true
    return $n
}

function Set-IdiomaActual {
    param([ValidateSet('es', 'en')][string]$Codigo, [string]$Raiz)
    $script:IdiomaActual = 'es'
    $script:IdiomaElegido = $Codigo
    if ($Codigo -eq 'en') {
        $n = Import-DiccionarioIdioma (Join-Path $Raiz 'modulos\idioma\en.tsv')
        # sin diccionario no se cambia nada: la interfaz queda en espanol
        if ($n -gt 0) { $script:IdiomaActual = 'en' }
    }
    $script:IdiomaElegido = $script:IdiomaActual
}

function T {
    # Traduce un texto visible. Devuelve el mismo texto si no hay traduccion.
    param([string]$Texto)
    if ($script:IdiomaActual -eq 'es' -or [string]::IsNullOrEmpty($Texto)) { return $Texto }
    # sin letras (numeros, porcentajes, simbolos) no hay nada que traducir
    if ($Texto -notmatch '[A-Za-z\u00C0-\u00FF]') { return $Texto }
    try {
        $r = $null
        if ($script:IdCache.TryGetValue($Texto, [ref]$r)) { return $r }
        $res = $Texto
        if ($script:IdExacto.TryGetValue($Texto, [ref]$r)) { $res = $r }
        else {
            $hecho = $false
            foreach ($p in $script:IdPlantillas) {
                $m = $p.Re.Match($Texto)
                if ($m.Success) {
                    $res = [regex]::Replace($p.En, '\{(\d+)(?:,-?\d+)?(?::[^}]*)?\}', {
                            param($t)
                            $g = $m.Groups['g' + $t.Groups[1].Value]
                            if ($g.Success) { T $g.Value } else { $t.Value }
                        })
                    $hecho = $true; break
                }
            }
            if (-not $hecho) {
                foreach ($p in $script:IdPrefijos) {
                    if ($Texto.StartsWith($p.Es, [System.StringComparison]::Ordinal)) { $res = $p.En + (T $Texto.Substring($p.Es.Length)); $hecho = $true; break }
                }
            }
            if (-not $hecho -and $Texto.Contains("`n")) {
                # listas de varias lineas: cada linea por separado
                $partes = $Texto -split "`n"
                $res = (@($partes | ForEach-Object { T $_ }) -join "`n")
            }
        }
        if ($script:IdCache.Count -lt 6000) { $script:IdCache[$Texto] = $res }
        return $res
    }
    catch { return $Texto }
}

function Convert-XamlIdioma {
    # Traduce textos fijos del XAML antes de cargarlo (atributos y texto entre etiquetas)
    param([string]$Xaml)
    if ($script:IdiomaActual -eq 'es') { return $Xaml }
    $dec = { param($s) [System.Net.WebUtility]::HtmlDecode($s) }
    $enc = { param($s) ($s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("`n", '&#10;')) }
    $xaml2 = [regex]::Replace($Xaml, '\b(Text|Content|Header|ToolTip|Title)="([^"]*)"', {
            param($m)
            $v = $m.Groups[2].Value
            if ($v.StartsWith('{')) { return $m.Value }
            $orig = & $dec $v
            $tr = T $orig
            if ($tr -ceq $orig) { return $m.Value }
            return ($m.Groups[1].Value + '="' + (& $enc $tr) + '"')
        })
    $xaml2 = [regex]::Replace($xaml2, '>([^<>{}]*[A-Za-zÁÉÍÓÚáéíóúñ]{3,}[^<>{}]*)</', {
            param($m)
            $orig = & $dec $m.Groups[1].Value
            $tr = T $orig.Trim()
            if ($tr -ceq $orig.Trim()) { return $m.Value }
            $lead = [regex]::Match($orig, '^\s*').Value
            $trail = [regex]::Match($orig, '\s*$').Value
            return ('>' + (& $enc ($lead + $tr + $trail)).Replace('&#10;', "`n") + '</')
        })
    return $xaml2
}

function Register-TraduccionVisual {
    # Traduce los TextBlock (celdas de tablas, botones de tabla, textos cambiados por codigo)
    # sin tocar los datos: se usa SetCurrentValue, la vinculacion de datos sigue intacta.
    param($Ventana, $Controles)
    if ($script:IdiomaActual -eq 'es') { return }
    $cambiar = {
        param($tb)
        try {
            $txt = [string]$tb.Text
            if ($txt) {
                $n = T $txt
                if ($n -cne $txt) { $tb.SetCurrentValue([System.Windows.Controls.TextBlock]::TextProperty, $n) }
            }
        }
        catch { }
    }
    $script:IdCambiar = $cambiar
    try {
        $h = [System.Windows.RoutedEventHandler] { param($s, $e) & $script:IdCambiar $s }
        [System.Windows.EventManager]::RegisterClassHandler([System.Windows.Controls.TextBlock], [System.Windows.FrameworkElement]::LoadedEvent, $h)
    }
    catch { $script:IdFallas++ }
    try {
        $dpd = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty([System.Windows.Controls.TextBlock]::TextProperty, [System.Windows.Controls.TextBlock])
        foreach ($k in @($Controles.Keys)) {
            $c = $Controles[$k]
            if ($c -is [System.Windows.Controls.TextBlock]) {
                $dpd.AddValueChanged($c, [System.EventHandler] { param($s, $e) & $script:IdCambiar $s })
                & $cambiar $c
            }
        }
    }
    catch { $script:IdFallas++ }
}

function Convert-InformeIdioma {
    # Copia traducida del informe HTML (AuditoriaPC genera el informe en espanol)
    param([string]$Ruta)
    if ($script:IdiomaActual -eq 'es' -or -not (Test-Path -LiteralPath $Ruta)) { return $Ruta }
    try {
        $html = [System.IO.File]::ReadAllText($Ruta, [System.Text.Encoding]::UTF8)
        $html = $html.Replace('<html lang="es">', '<html lang="en">')
        $html = [regex]::Replace($html, '>([^<>]+)<', {
                param($m)
                $orig = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
                $t = T $orig.Trim()
                if ($t -ceq $orig.Trim()) { return $m.Value }
                $lead = [regex]::Match($orig, '^\s*').Value
                $trail = [regex]::Match($orig, '\s*$').Value
                $salida = [System.Net.WebUtility]::HtmlEncode($lead + $t + $trail)
                return ('>' + $salida + '<')
            })
        $destino = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($Ruta), ([System.IO.Path]::GetFileNameWithoutExtension($Ruta) + '_EN.html'))
        [System.IO.File]::WriteAllText($destino, $html, (New-Object System.Text.UTF8Encoding($true)))
        return $destino
    }
    catch { return $Ruta }
}
