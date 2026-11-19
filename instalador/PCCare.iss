; Instalador de PC Care (Inno Setup 6). La version llega desde la linea de comandos:
;   ISCC /DAppVersion=2.1.0 instalador\PCCare.iss
; Lo compila GitHub Actions en cada release (ver instalador\compilar.ps1). No lleva nada que no este en el repositorio.
#ifndef AppVersion
  #error Falta la version. Ejecuta ISCC con /DAppVersion=X.Y.Z
#endif
#define AppName "PC Care"
#define AppPublisher "NOVALTEK"
#define AppURL "https://github.com/marcoadtup-cmd/PCCare"
#define PowerShellExe "{sys}\WindowsPowerShell\v1.0\powershell.exe"

[Setup]
; El AppId identifica a PC Care para las actualizaciones: no cambiarlo nunca.
AppId={{0228E363-D0DA-455F-9E18-F50ECA68DCDA}}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
VersionInfoVersion={#AppVersion}.0
VersionInfoProductVersion={#AppVersion}.0
VersionInfoCompany={#AppPublisher}
VersionInfoDescription=Instalador de {#AppName}
VersionInfoProductName={#AppName}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE
OutputDir=..\salida
OutputBaseFilename=PCCare-Setup-{#AppVersion}-x64
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
MinVersion=10.0
WizardStyle=modern
UninstallDisplayName={#AppName} {#AppVersion}

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "Crear un acceso directo en el escritorio"; GroupDescription: "Accesos directos:"; Flags: unchecked

[Files]
Source: "..\PCCare.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\modulos\*"; DestDir: "{app}\modulos"; Flags: ignoreversion recursesubdirs
Source: "..\Autoprueba PC Care.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\CHANGELOG.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\SECURITY.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; PC Care pide permisos de administrador por si mismo al abrirse (UAC).
Name: "{group}\PC Care"; Filename: "{#PowerShellExe}"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\PCCare.ps1"""; WorkingDir: "{app}"; Comment: "Mantenimiento de Windows"
Name: "{group}\Autoprueba de PC Care"; Filename: "{app}\Autoprueba PC Care.cmd"; WorkingDir: "{app}"
Name: "{group}\Desinstalar PC Care"; Filename: "{uninstallexe}"
Name: "{autodesktop}\PC Care"; Filename: "{#PowerShellExe}"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\PCCare.ps1"""; WorkingDir: "{app}"; Comment: "Mantenimiento de Windows"; Tasks: desktopicon

[Run]
Filename: "{#PowerShellExe}"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\PCCare.ps1"""; WorkingDir: "{app}"; Description: "Abrir PC Care ahora"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Los datos del usuario (%LOCALAPPDATA%\PCCare y Documentos\PCCare) NO se borran al desinstalar.
Type: files; Name: "{app}\PCCare_autoprueba_*.log"
Type: dirifempty; Name: "{app}"
