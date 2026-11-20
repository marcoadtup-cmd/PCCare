@echo off
setlocal
title PC Care
set "PCCARE_DIR=%~dp0"
rem Si esta PCCare.exe (lanzador sin consola), se usa ese y esta ventana se cierra.
if exist "%~dp0PCCare.exe" (
  start "" "%~dp0PCCare.exe"
  exit /b 0
)
rem Quita el bloqueo "descargado de internet" de los archivos de esta carpeta y abre PC Care.
rem PC Care pide permisos de administrador por si solo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath $env:PCCARE_DIR -Recurse -File | Where-Object { $_.Extension -in .ps1,.cmd } | Unblock-File" >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PCCare.ps1"
if errorlevel 1 (
  echo.
  echo PC Care termino con un error. Copia este mensaje y abre un Issue en GitHub.
  pause
)
