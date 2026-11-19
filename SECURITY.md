# Seguridad

## Cómo reportar un problema

Si encuentras una falla que pueda borrar datos, escalar privilegios o filtrar información, **no la publiques en un Issue abierto**. Usa la opción "Report a vulnerability" de la pestaña Security de este repositorio. Incluye pasos para reproducirla y la versión de PC Care.

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
3. El programa no está firmado digitalmente, por eso SmartScreen avisa. Todo el código es legible en texto plano.
