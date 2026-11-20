# Pruebas del sistema de idiomas ES/EN. No necesitan administrador ni abren ventanas.
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File .\pruebas\Idioma.Tests.ps1
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
. (Join-Path $raiz 'modulos\Idioma.ps1')
$script:fallas = 0
function Assert-Prueba {
    param([string]$Nombre, [bool]$Condicion, [string]$Detalle = '')
    if ($Condicion) { Write-Host ('OK     ' + $Nombre) }
    else { Write-Host ('FALLA  ' + $Nombre + ' ' + $Detalle); $script:fallas++ }
}

# 1) Estructura del diccionario
$rutaTsv = Join-Path $raiz 'modulos\idioma\en.tsv'
Assert-Prueba 'existe en.tsv' (Test-Path -LiteralPath $rutaTsv)
$lineas = @(Get-Content -LiteralPath $rutaTsv -Encoding UTF8 | Where-Object { $_ -and -not $_.StartsWith('#') })
Assert-Prueba 'diccionario con mas de 700 filas' ($lineas.Count -gt 700) ('filas: ' + $lineas.Count)
$claves = @{}
$malas = New-Object System.Collections.ArrayList
$guion = [string][char]0x2014
foreach ($l in $lineas) {
    $p = $l.Split("`t")
    if ($p.Count -ne 2 -or [string]::IsNullOrWhiteSpace($p[0]) -or [string]::IsNullOrWhiteSpace($p[1])) { [void]$malas.Add('formato: ' + $l); continue }
    if ($claves.ContainsKey($p[0])) { [void]$malas.Add('duplicada: ' + $p[0]) }
    $claves[$p[0]] = $p[1]
    if ($p[1].Contains($guion)) { [void]$malas.Add('guion largo: ' + $p[1]) }
    $ph1 = @([regex]::Matches($p[0], '\{(\d+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ','
    $ph2 = @([regex]::Matches($p[1], '\{(\d+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ','
    if ($ph1 -ne $ph2) { [void]$malas.Add('marcadores distintos: ' + $p[0]) }
}
Assert-Prueba 'filas bien formadas, sin duplicados, sin guion largo, mismos marcadores {n}' ($malas.Count -eq 0) (($malas | Select-Object -First 8) -join ' | ')

# 2) Motor
Set-IdiomaActual -Codigo en -Raiz $raiz
Assert-Prueba 'idioma ingles activo' ($script:IdiomaActual -eq 'en')
Assert-Prueba 'sin plantillas rotas' ($script:IdFallas -eq 0) ('fallas: ' + $script:IdFallas)
Assert-Prueba 'texto exacto' ((T 'Limpieza') -ceq 'Cleanup')
Assert-Prueba 'plantilla con un dato' ((T '73% en uso de 16 GB.') -ceq '73% in use of 16 GB.')
Assert-Prueba 'plantilla con tres datos' ((T 'Temporales del usuario: 1,2 GB en 340 archivos; 5 en uso, omitidos.') -ceq 'User temporary files: 1,2 GB in 340 files; 5 in use, skipped.')
Assert-Prueba 'prefijo con dato' ((T 'Espacio en C:') -ceq 'Space on C:')
Assert-Prueba 'texto de varias lineas' ((T "Limpieza`nRed") -ceq "Cleanup`nNetwork")
Assert-Prueba 'texto sin traduccion queda igual' ((T 'zzz sin traduccion qqq') -ceq 'zzz sin traduccion qqq')
Assert-Prueba 'cadena vacia' ((T '') -ceq '')
$script:IdiomaActual = 'es'
Assert-Prueba 'en espanol no cambia nada' ((T 'Limpieza') -ceq 'Limpieza')
$script:IdiomaActual = 'en'

# 3) XAML de la ventana principal
$codigo = [System.IO.File]::ReadAllText((Join-Path $raiz 'PCCare.ps1'), [System.Text.Encoding]::UTF8)
$m = [regex]::Match($codigo, "(?s)\[xml\]\`$xaml = @'\r?\n(.*?)\r?\n'@")
Assert-Prueba 'se encontro el XAML' $m.Success
if ($m.Success) {
    $xamlEs = $m.Groups[1].Value
    $xamlEn = Convert-XamlIdioma $xamlEs
    $docEs = [xml]$xamlEs
    $okXml = $true
    try { $docEn = [xml]$xamlEn } catch { $okXml = $false; Write-Host $_.Exception.Message }
    Assert-Prueba 'XAML traducido sigue siendo XML valido' $okXml
    if ($okXml) {
        $nomEs = @($docEs.SelectNodes("//*[@*[local-name()='Name']]") | ForEach-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') } | Sort-Object)
        $nomEn = @($docEn.SelectNodes("//*[@*[local-name()='Name']]") | ForEach-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') } | Sort-Object)
        Assert-Prueba 'mismos controles con nombre' (($nomEs -join ',') -ceq ($nomEn -join ',')) ('es=' + $nomEs.Count + ' en=' + $nomEn.Count)
        Assert-Prueba 'selector de idioma presente' ($nomEn -contains 'cmbIdioma')
        $cambiados = 0; $total = 0
        foreach ($mm in [regex]::Matches($xamlEs, '\b(Text|Content|Header|ToolTip)="([^"{][^"]*)"')) {
            $v = [System.Net.WebUtility]::HtmlDecode($mm.Groups[2].Value)
            if ($v -match '[A-Za-z\u00C0-\u00FF]{4,}') { $total++; if ((T $v) -cne $v) { $cambiados++ } }
        }
        Assert-Prueba 'al menos 85% de los textos fijos traducidos' ($total -gt 100 -and ($cambiados / $total) -ge 0.85) ('traducidos {0} de {1}' -f $cambiados, $total)
        Write-Host ('       cobertura XAML: {0} de {1}' -f $cambiados, $total)
    }
}

# 4) Informe HTML
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('pccare_idioma_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $f = Join-Path $tmp 'Informe.html'
    [System.IO.File]::WriteAllText($f, '<html lang="es"><body><h2>Hallazgos y recomendaciones</h2><table><tr><th>Estado</th></tr><tr><td>CRITICO</td></tr></table><p>Valor 123</p></body></html>', (New-Object System.Text.UTF8Encoding($true)))
    $salida = Convert-InformeIdioma $f
    Assert-Prueba 'informe traducido en archivo aparte' ($salida -like '*Informe_EN.html' -and (Test-Path -LiteralPath $salida))
    $h = [System.IO.File]::ReadAllText($salida)
    Assert-Prueba 'informe: encabezado y estado traducidos' ($h.Contains('Findings and recommendations') -and $h.Contains('>CRITICAL<') -and $h.Contains('lang="en"'))
    Assert-Prueba 'informe: texto no traducible intacto' ($h.Contains('Valor 123') -or $h.Contains('Value 123'))
}
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# 5) Archivos que tocan el idioma
$cfgTmp = Join-Path ([System.IO.Path]::GetTempPath()) ('pccare_cfg_' + [guid]::NewGuid().ToString('N') + '.json')
[System.IO.File]::WriteAllText($cfgTmp, '{"Simulacion": true, "Idioma": "en"}')
Assert-Prueba 'lee el idioma guardado' ((Get-IdiomaGuardado $cfgTmp) -ceq 'en')
Remove-Item -LiteralPath $cfgTmp -Force -ErrorAction SilentlyContinue
Assert-Prueba 'sin archivo no hay idioma guardado' ($null -eq (Get-IdiomaGuardado 'C:\no\existe\config.json'))

if ($script:fallas -gt 0) { Write-Host ('RESULTADO: {0} fallas' -f $script:fallas); exit 1 }
Write-Host 'RESULTADO: todo correcto'
