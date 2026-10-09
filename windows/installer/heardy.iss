; Instalador de Heardy para Windows (W4 del plan de escritorio).
; Empaqueta la carpeta de `flutter build windows --release` en un único
; Heardy-Setup.exe, porque Flutter no produce un .exe suelto (Hallazgo 4) —
; copiar sólo heardy.exe sin sus DLL/`data/` no arranca.
;
; Reproducible:
;   1. flutter build windows --release
;   2. ISCC.exe windows\installer\heardy.iss
; El .exe resultante queda en build\windows\installer\Heardy-Setup.exe.
;
; AppId es un GUID fijo generado una sola vez para este proyecto — no
; cambiarlo nunca: es lo que permite que una instalación futura se detecte
; como una actualización en vez de una instalación paralela.
#define MyAppName "Heardy"
#define MyAppVersion "1.1.7"
#define MyAppExeName "heardy.exe"
#define MyReleaseDir "..\..\build\windows\x64\runner\Release"

[Setup]
AppId={{B96AA35E-22F7-4DEA-9D69-47F93994775D}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\..\build\windows\installer
OutputBaseFilename=Heardy-Setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma
SolidCompression=yes
WizardStyle=modern
; Metadatos reales en vez de los genericos por defecto de Inno Setup: un
; instalador sin editor/descripcion es una senal mas que suma para los
; heuristicos de antivirus (junto con no estar firmado, ver mas abajo).
VersionInfoCompany=Vainastech
VersionInfoDescription=Instalador de Heardy - reproductor de musica local
VersionInfoProductName={#MyAppName}
VersionInfoVersion={#MyAppVersion}
VersionInfoCopyright=Copyright (C) 2026 Vainastech. All rights reserved.
; Sin certificado de firma de código (~200 USD/año, ver Hallazgo 4):
; SmartScreen va a avisar "editor desconocido". Asumido, no un fallo.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Actualizar sobre una instalación existente mientras Heardy está abierto.
; El filtro por defecto (*.exe,*.dll,*.chm) no mira `data\app.so`, que es
; donde vive TODO el código Dart compilado y que el proceso mantiene
; bloqueado: el instalador cambiaba el .exe y las DLL pero no podía
; reemplazar app.so, y la app "actualizada" seguía ejecutando el código
; viejo. Con `force`, un /VERYSILENT también cierra la app en vez de fallar.
CloseApplications=force
CloseApplicationsFilter=*.exe,*.dll,*.chm,*.so
RestartApplications=no

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Crear un acceso directo en el escritorio"; GroupDescription: "Accesos directos adicionales:"

; Inno Setup sólo sobrescribe lo que la versión nueva trae; nunca borra lo
; que una versión anterior dejó. `data\` (app.so + flutter_assets) se
; regenera entero en cada build, así que se limpia antes de copiar para que
; no queden assets/plugins huérfanos mezclados con lo nuevo. Los .dll de
; plugins van al mismo saco: uno que la app ya no use quedaría ahí para
; siempre. Nada de esto toca los datos del usuario, que viven en %APPDATA%.
[InstallDelete]
Type: filesandordirs; Name: "{app}\data"
Type: files; Name: "{app}\*.dll"

[Files]
; *.lib/*.exp son artefactos del enlazador que `flutter build windows` deja
; en la carpeta Release; la app no los necesita y sólo abultan el instalador.
Source: "{#MyReleaseDir}\*"; DestDir: "{app}"; Excludes: "*.lib,*.exp"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{commondesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{group}\Desinstalar {#MyAppName}"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Abrir {#MyAppName}"; Flags: nowait postinstall skipifsilent

; El desinstalador no pasa por Restart Manager (eso es sólo CloseApplications,
; del instalador): con Heardy abierto, heardy.exe/las DLL/app.so quedaban en
; uso y sobrevivían en disco. Cerrarla antes de borrar.
[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/IM {#MyAppExeName} /F"; Flags: runhidden; RunOnceId: "CloseHeardy"
