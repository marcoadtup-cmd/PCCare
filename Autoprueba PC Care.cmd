@echo off
setlocal
title PC Care - autoprueba
set "PCCARE_DIR=%~dp0"
rem Ejecuta los analisis en solo lectura y deja un informe PCCare_autoprueba_EQUIPO.log en esta carpeta.
rem Para incluir drivers, informe de auditoria y red (tarda varios minutos) ejecuta con el parametro COMPLETA.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath $env:PCCARE_DIR -Recurse -File | Where-Object { $_.Extension -in .ps1,.cmd } | Unblock-File" >nul 2>&1
if /i "%~1"=="completa" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PCCare.ps1" -AutoPrueba -Completa
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PCCare.ps1" -AutoPrueba
)
pause
