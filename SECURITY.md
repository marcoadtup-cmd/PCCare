# Seguridad

## Cómo reportar un problema

Si encuentras una falla que pueda borrar datos, escalar privilegios o filtrar información, **no la publiques en un Issue abierto**. Usa la opción "Report a vulnerability" de la pestaña Security de este repositorio. Incluye pasos para reproducirla y la versión de PC Care.

Si no puedes usar esa opción, escribe a **marcoadtup@gmail.com** con el asunto "PC Care seguridad".

## Quién puede cambiar el código

- Solo el dueño del repositorio puede escribir en la rama principal y publicar versiones.
- Los demás participan con Pull Requests, que el dueño revisa y aprueba una por una.
- Cada cambio queda anotado en `CHANGELOG.md` con fecha y hora.
- Las descargas oficiales son únicamente las de la sección Releases de este repositorio. Una copia en otro sitio puede estar modificada.

## Diseño

- Modo simulación al arrancar. Los cambios reales exigen desactivarlo y confirmar.
- La limpieza solo actúa dentro de una lista cerrada de carpetas y rechaza rutas fuera de ella, incluidos accesos directos de carpeta y escapes con `..`.
- Archivos de usuario: van a la Papelera, nunca se borran de forma definitiva.
- Registro: solo tres tipos de entrada comprobada, con respaldo `.reg` antes de borrar.
- Drivers: solo Windows Update y herramientas oficiales del fabricante. Punto de restauración y respaldo previos.
- La cola guardada (`%LOCALAPPDATA%\PCCare\Cola.json`) no contiene contraseñas. Solo guarda nombres, opciones marcadas y parámetros de la tarea.
- Sin telemetría, sin publicidad y sin ofertas de otros productos. El desinstalador no abre páginas web.
- Conexiones: solo las de `winget`, Microsoft Store, Windows Update, las pruebas de red que inicia el usuario y los enlaces que el usuario abre en su navegador. La lista completa, con destinos y momento, está en la sección "Privacidad y transparencia" del README.
- Limpieza de privacidad: las cookies van desmarcadas, se eligen por navegador y se omiten si el navegador está abierto. Nunca se ejecuta sola.
- Desinstalación de programas: siempre el desinstalador interactivo del fabricante, uno a la vez, con el comando leído del registro en el momento. PC Care no se desinstala a sí mismo.

## Qué verificar antes de ejecutar una versión

1. Descárgala solo desde la sección Releases de este repositorio.
2. Compara el SHA256 con el archivo `.sha256` de la release.
3. Comprueba el origen: `gh attestation verify ARCHIVO --repo marcoadtup-cmd/PCCare`. Confirma que lo compiló GitHub Actions desde este repositorio.
4. Mientras el proyecto no esté aprobado en SignPath Foundation, el instalador no está firmado digitalmente y por eso SmartScreen avisa. Cuando lo esté, la release lo indicará y `Get-AuthenticodeSignature` mostrará la firma como válida. La versión portable nunca se firma. Dentro del instalador, PC Care sigue siendo PowerShell en texto plano y puedes leerlo en la carpeta instalada.

`PCCare.exe` es un lanzador pequeño y auditable (`lanzador\Program.cs`, unas 200 líneas): solo busca `PCCare.ps1` junto a él, quita la marca de "descargado de internet" de los archivos de PC Care, abre PowerShell sin ventana con ese script y muestra el error si falla. No usa la red ni descarga nada. Como abre PowerShell oculto con `-ExecutionPolicy Bypass`, algunos antivirus pueden marcarlo por error mientras no esté firmado; si pasa, compara su SHA256 con el de la release o usa `Iniciar PC Care.cmd`.

Firma digital: la configuración vive en `publicar.yml` y solo corre si el repositorio tiene la variable `SIGNPATH_ORGANIZATION_ID` y el secreto `SIGNPATH_API_TOKEN`. Cada firma exige aprobación manual del dueño en SignPath, con autenticación en dos pasos. Si la firma no es válida, la release no se publica. Política completa en el README.

Cómo se compila: al crear una etiqueta `vX.Y.Z`, GitHub Actions compila el instalador con Inno Setup, lo instala y desinstala en silencio, compara cada archivo instalado con el del repositorio y recién entonces publica la release. La etiqueta debe coincidir con la versión del programa o la compilación se detiene.
