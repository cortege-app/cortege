# Contourne deux problèmes du hook de build de `sodium` pour compiler libsodium
# sur Windows (utile seulement pour lancer `flutter test` sur le PC) :
#   1. Il appelle `msbuild /getProperty`, absent de MSBuild 16 (Visual Studio
#      2019 Build Tools). Ici on repère la DLL nous-mêmes.
#   2. Sur un Windows non anglophone, MSBuild et le compilateur écrivent leurs
#      messages en page de codes OEM (850 en France) ; le hook les lit en UTF-8
#      et plante sur le premier accent. Ici on force l'UTF-8.
#
# Ce script prépare le dossier de build du hook avec un script de remplacement.
# À lancer une fois après `flutter pub get`, et à relancer après `flutter clean`.
# Inutile pour les builds Android.
#
# Usage, depuis le dossier app/ :  powershell -File tool\windows\prepare_libsodium.ps1

param([string]$ConfigHash = '0c4039d93c')

$ErrorActionPreference = 'Stop'
$app = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$buildRoot = Join-Path $app '.dart_tool\hooks_runner\shared\sodium\build'

$sodiumDir = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Pub\Cache\hosted\pub.dev') -Directory |
    Where-Object { $_.Name -like 'sodium-4.*' } |
    Sort-Object Name -Descending | Select-Object -First 1
if (-not $sodiumDir) { throw 'Paquet sodium introuvable. Lance d''abord `flutter pub get`.' }
$archive = Get-ChildItem (Join-Path $sodiumDir.FullName '3rdparty') -Filter 'libsodium-*-stable.tar.gz' | Select-Object -First 1

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vsPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Workload.VCTools -property installationPath
if (-not $vsPath) { throw 'Visual Studio Build Tools (charge de travail C++) introuvable.' }
$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'

# Le nom du dossier de build est un hachage calculé par le hook (0c4039d93c sur
# la machine où ce script a été écrit). S'il est différent chez toi, lance
# `$env:NIX_HOOKS_ENABLE_DEBUG_LOGGING=1; flutter test`, cherche la ligne
# « Calculated config hash », et passe-la en paramètre.
if (-not (Test-Path $buildRoot)) { New-Item -ItemType Directory -Force $buildRoot | Out-Null }
$configDir = New-Item -ItemType Directory -Force (Join-Path $buildRoot $ConfigHash)

$src = Join-Path $configDir.FullName 'libsodium-stable'
if (-not (Test-Path $src)) {
    tar -xzf $archive.FullName -C $configDir.FullName
}

$script = @"
@ECHO ON
chcp 65001 >nul
CALL "$vcvars"
IF "%VSCMD_VER%"=="" (
  SET "__SODIUM_VS_VERSION=%VisualStudioVersion%"
) ELSE (
  SET "__SODIUM_VS_VERSION=%VSCMD_VER%"
)
FOR /f "tokens=1 delims=." %%i IN ("%__SODIUM_VS_VERSION%") DO SET "__SODIUM_VS_VERSION_MAJOR=%%i"
SET "__SODIUM_VS_NAME=vs2026"
IF "%__SODIUM_VS_VERSION_MAJOR%"=="18" SET "__SODIUM_VS_NAME=vs2026"
IF "%__SODIUM_VS_VERSION_MAJOR%"=="17" SET "__SODIUM_VS_NAME=vs2022"
IF "%__SODIUM_VS_VERSION_MAJOR%"=="16" SET "__SODIUM_VS_NAME=vs2019"
IF "%__SODIUM_VS_VERSION_MAJOR%"=="15" SET "__SODIUM_VS_NAME=vs2017"

msbuild "builds/msvc/%__SODIUM_VS_NAME%/libsodium/libsodium.vcxproj" /p:Configuration=ReleaseDLL /p:Platform=x64 /p:RuntimeLibrary=MultiThreadedDLL /m /v:q /nologo
IF ERRORLEVEL 1 EXIT /B 1
DEL target.txt 2>nul
FOR /R "%CD%\bin" %%f IN (libsodium.dll) DO IF EXIST "%%f" ECHO %%f> target.txt
EXIT /B 0
"@
Set-Content -Path (Join-Path $src 'dart-build.bat') -Value $script -Encoding ascii
Write-Host "Script de build préparé dans $src"
