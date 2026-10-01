@echo off
setlocal EnableExtensions
title IOTerminal Setup
cd /d "%~dp0.."

net session >nul 2>&1
if errorlevel 1 (
  echo.
  echo Precisa de administrador.
  echo Vai abrir o UAC: clique em SIM.
  echo.
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -LiteralPath '%~f0' -Verb RunAs"
  if errorlevel 1 (
    echo.
    echo UAC recusado ou falhou. Clique com o botao direito em
    echo iniciar-kit.cmd e escolha Executar como administrador.
    echo.
    pause
    exit /b 10
  )
  exit /b 0
)

echo.
echo Pasta do kit: %CD%
echo.

if not exist "%CD%\manifest.json" (
  echo ERRO: manifest.json nao esta nesta pasta.
  echo A pasta certa tem installer.ps1, manifest.json e a pasta IOTERMINAL.
  echo.
  pause
  exit /b 12
)

if not exist "%CD%\installer.ps1" (
  echo ERRO: installer.ps1 nao esta nesta pasta.
  echo.
  pause
  exit /b 12
)

if not exist "%CD%\IOTERMINAL\" (
  echo ERRO: pasta IOTERMINAL nao encontrada.
  echo Ela deve conter DRIVERS, INSTALADOR e LICENCA.
  echo.
  pause
  exit /b 20
)

echo Iniciando o instalador.
echo Se o IOTerminal ja estiver neste PC, ele e apagado e instalado de novo.
echo A janela fica aberta.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CD%\installer.ps1" -Reinstall %*
set "ERR=%ERRORLEVEL%"

echo.
echo Instalador encerrou. Codigo: %ERR%
echo Log: C:\ProgramData\OficinaBinaria\ioterminal-setup\
echo.
pause
exit /b %ERR%
