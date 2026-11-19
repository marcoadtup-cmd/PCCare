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
- Sin telemetría. No hay conexiones salvo las de winget, Windows Update y las pruebas de red que inicia el usuario.

## Qué verificar antes de ejecutar una versión

1. Descárgala solo desde la sección Releases de este repositorio.
2. Compara el SHA256 con el archivo `.sha256` de la release.
3. Comprueba el origen: `gh attestation verify ARCHIVO --repo marcoadtup-cmd/PCCare`. Confirma que lo compiló GitHub Actions desde este repositorio.
4. El instalador y el programa no están firmados digitalmente, por eso SmartScreen avisa. Dentro del instalador, PC Care sigue siendo PowerShell en texto plano y puedes leerlo en la carpeta instalada.

Cómo se compila: al crear una etiqueta `vX.Y.Z`, GitHub Actions compila el instalador con Inno Setup, lo instala y desinstala en silencio, compara cada archivo instalado con el del repositorio y recién entonces publica la release. La etiqueta debe coincidir con la versión del programa o la compilación se detiene.
