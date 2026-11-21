# probar.ps1 (lanzador)
# Comprueba PCCare.exe ya compilado, sin abrir PC Care: tipo de programa, version, permisos,
# paso de argumentos, codigo de salida, registro de errores y archivo faltante.
# Los cuadros de aviso se desactivan con PCCARE_LANZADOR_SIN_CUADROS=1.
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $PSScriptRoot 'bin\PCCare.exe'
$script:fallas = 0
function Assert-Prueba {
    param([string]$Nombre, [bool]$Condicion, [string]$Detalle = '')
    if ($Condicion) { Write-Host ('OK     ' + $Nombre) }
    else {
        Write-Host ('FALLA  ' + $Nombre + ' ' + $Detalle)
        Write-Host ('::error file=lanzador/probar.ps1::' + $Nombre + ' ' + ($Detalle -replace '[\r\n]+', ' '))
        $script:fallas++
    }
}
function Start-Lanzador {
    param([string]$Carpeta, [string]$Argumentos = '')
    $ruta = Join-Path $Carpeta 'PCCare.exe'
    if ($Argumentos) { $p = Start-Process -FilePath $ruta -ArgumentList $Argumentos -Wait -PassThru }
    else { $p = Start-Process -FilePath $ruta -Wait -PassThru }
    return $p.ExitCode
}

try {
    Assert-Prueba 'existe PCCare.exe' (Test-Path -LiteralPath $exe)
    $bytes = [System.IO.File]::ReadAllBytes($exe)

    # 1) Es un programa de ventana (subsistema GUI = 2): no abre consola
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    $subsistema = [BitConverter]::ToUInt16($bytes, $pe + 24 + 68)
    Assert-Prueba 'programa de ventana, sin consola (subsistema GUI)' ($subsistema -eq 2) ('subsistema=' + $subsistema)

    # 2) Version, producto y permisos
    $linea = Select-String -LiteralPath (Join-Path $raiz 'PCCare.ps1') -Pattern '^\$VersionApp = ''([^'']+)''' | Select-Object -First 1
    $versionApp = $linea.Matches[0].Groups[1].Value
    $vi = (Get-Item -LiteralPath $exe).VersionInfo
    Assert-Prueba 'producto PC Care y empresa NOVALTEK' ($vi.ProductName -ceq 'PC Care' -and $vi.CompanyName -ceq 'NOVALTEK') ($vi.ProductName + ' / ' + $vi.CompanyName)
    Assert-Prueba 'version del .exe igual a la de PCCare.ps1' ($vi.FileVersion -ceq ($versionApp + '.0')) ($vi.FileVersion + ' vs ' + $versionApp)
    $texto = [System.Text.Encoding]::ASCII.GetString($bytes)
    Assert-Prueba 'manifiesto pide administrador' ($texto.Contains('requireAdministrator'))

    # 3) Carpeta de prueba con un PCCare.ps1 falso
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('pccare_lanz_' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $tmp)
    $datos = Join-Path $tmp 'datos'
    [void](New-Item -ItemType Directory -Path $datos)
    Copy-Item -LiteralPath $exe -Destination (Join-Path $tmp 'PCCare.exe')
    $falso = @'
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'args.txt'), ($args -join '|'))
if ($env:STUB_CODIGO) {
    [Console]::Error.WriteLine('fallo simulado del stub')
    exit ([int]$env:STUB_CODIGO)
}
exit 0
'@
    [System.IO.File]::WriteAllText((Join-Path $tmp 'PCCare.ps1'), $falso, (New-Object System.Text.UTF8Encoding($true)))
    $env:PCCARE_LANZADOR_SIN_CUADROS = '1'
    $env:LOCALAPPDATA = $datos

    # 3a) Salida correcta y paso de argumentos, incluidos espacios y barra final
    $env:STUB_CODIGO = ''
    $codigo = Start-Lanzador $tmp '-Idioma en -CarpetaDatos "C:\Ruta con espacios\\"'
    Assert-Prueba 'salida 0 cuando PC Care termina bien' ($codigo -eq 0) ('codigo=' + $codigo)
    $args1 = [System.IO.File]::ReadAllText((Join-Path $tmp 'args.txt'))
    Assert-Prueba 'pasa los argumentos tal cual' ($args1 -ceq '-Idioma|en|-CarpetaDatos|C:\Ruta con espacios\') ('recibido=' + $args1)
    Assert-Prueba 'sin errores no escribe registro' (-not (Test-Path -LiteralPath (Join-Path $datos 'PCCare\lanzador.log')))

    # 3b) Error: devuelve el mismo codigo y lo anota con el texto del error
    $env:STUB_CODIGO = '3'
    $codigo = Start-Lanzador $tmp ''
    Assert-Prueba 'devuelve el codigo de error de PC Care' ($codigo -eq 3) ('codigo=' + $codigo)
    $rutaLog = Join-Path $datos 'PCCare\lanzador.log'
    Assert-Prueba 'anota el error en lanzador.log' (Test-Path -LiteralPath $rutaLog)
    if (Test-Path -LiteralPath $rutaLog) {
        $log = [System.IO.File]::ReadAllText($rutaLog, [System.Text.Encoding]::UTF8)
        Assert-Prueba 'el registro trae codigo y texto del error' ($log.Contains('3') -and $log.Contains('fallo simulado del stub')) $log
    }

    # 3c) Falta PCCare.ps1
    Remove-Item -LiteralPath (Join-Path $tmp 'PCCare.ps1') -Force
    $env:STUB_CODIGO = ''
    $codigo = Start-Lanzador $tmp ''
    Assert-Prueba 'sin PCCare.ps1 devuelve 2' ($codigo -eq 2) ('codigo=' + $codigo)
    $log = [System.IO.File]::ReadAllText($rutaLog, [System.Text.Encoding]::UTF8)
    Assert-Prueba 'avisa que falta PCCare.ps1' ($log.Contains('PCCare.ps1') -and ($log.Contains('Extrae TODA') -or $log.Contains('Extract the WHOLE')))
}
catch {
    Write-Host ('::error file=lanzador/probar.ps1,line=' + $_.InvocationInfo.ScriptLineNumber + '::' + ($_.Exception.Message -replace '[\r\n]+', ' '))
    $script:fallas++
}
finally {
    Remove-Item Env:\PCCARE_LANZADOR_SIN_CUADROS, Env:\STUB_CODIGO -ErrorAction SilentlyContinue
    if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:fallas -gt 0) { Write-Host ('RESULTADO: {0} fallas' -f $script:fallas); exit 1 }
Write-Host 'RESULTADO: todo correcto'
