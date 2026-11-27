# Cómo contribuir

Gracias por querer mejorar PC Care. Un Issue claro ya es una gran ayuda.

Contacto: marcoadtup@gmail.com

## Reportar un error

Adjunta:

- Versión de PC Care y de Windows.
- Qué hiciste, qué esperabas y qué pasó.
- El archivo `PCCare_autoprueba_NOMBRE.log` (ver README).
- Captura de pantalla si es un problema visual. **Quita nombres de equipo, usuarios y rutas privadas.**

## Quién aprueba los cambios

Nadie, salvo el dueño del repositorio, puede modificar el código de este repositorio. Cualquiera puede proponer un cambio, pero el proceso es siempre el mismo:

1. Haces un fork y envías un Pull Request.
2. Es obligatorio incluir una entrada en `CHANGELOG.md` con fecha, hora y tipo de cambio (nuevo módulo, mejora, corrección, actualización o seguridad). Un Pull Request que toque código sin esa entrada falla la validación automática.
3. El dueño revisa el código línea por línea antes de aceptarlo. Puede pedir cambios o rechazarlo sin dar más explicación.
4. Solo el dueño fusiona el cambio y publica la nueva versión.

Cualquiera puede copiar y modificar su propia versión (la licencia MIT lo permite), pero eso no cambia este repositorio ni sus descargas oficiales.

## Proponer cambios

1. Haz un fork y crea una rama.
2. Mantén el espíritu del proyecto: lo que modifica el equipo debe tener modo simulación, confirmación y, cuando sea posible, forma de revertirse.
3. Toda tarea nueva debe registrarse en `PCCare.ps1` (`$mapaTipos`) y en `modulos\Cola.ps1` (`$script:PoliticaTipos`) con su política de reanudación. La autoprueba falla si falta alguna.
4. Guarda los `.ps1` como **UTF-8 con BOM** y fin de línea CRLF. Sin BOM, Windows PowerShell 5.1 rompe los acentos.
5. Ejecuta `Autoprueba PC Care.cmd` en tu equipo y adjunta el resultado en el Pull Request.

La validación automática comprueba la sintaxis de todos los `.ps1` en cada Pull Request.

## Estructura

| Archivo | Para qué sirve |
|---|---|
| `lanzador\Program.cs` | Código de `PCCare.exe` (C# 5, sin consola). Se compila con `lanzador\compilar.ps1` y se prueba con `lanzador\probar.ps1`. |
| `PCCare.ps1` | Ventana principal, motor de cola, limpieza, rendimiento, monitor, seguridad y autoprueba. |
| `modulos\Cola.ps1` | Registro persistente de tareas y políticas de reanudación. |
| `modulos\Inicio.ps1` | Lista de tareas de la ventana al abrir y lógica de estados y detalle (sin interfaz, probada en la autoprueba). |
| `modulos\Proteccion.ps1` | Antivirus activo (SecurityCenter2 y Defender) y escaneo con Microsoft Defender. Decisión de escaneo probada en la autoprueba. |
| `modulos\Resumen.ps1` | Resumen honesto del análisis, puntos de color del menú, impacto acumulado, último análisis guardado y ficha del equipo. |
| `modulos\Programas.ps1` | Programas instalados, desinstalación interactiva con guardas, programas con fallos y registro de cambios del arranque para deshacer. |
| `modulos\Privacidad.ps1` | Limpieza de privacidad: recientes, Jump Lists, recientes de Office y cookies por navegador. Sus funciones de ayuda se suman al texto de ayuda de las tareas en segundo plano. |
| `modulos\Actualizaciones.ps1` | Motor en segundo plano de aplicaciones (winget) y drivers. |
| `modulos\UI_Actualizaciones.ps1` | Página Actualizaciones. |
| `modulos\Ejecutores.ps1` | Tareas que lanzan el informe de auditoría y la optimización de red. |
| `modulos\UI_InformeRed.ps1` | Páginas Informe y Red. |
| `modulos\AuditoriaPC.ps1` | Auditoría de solo lectura que genera `Informe.html`. |
| `modulos\OptimizarRed.ps1` | Diagnóstico y mejoras de red. |
| `instalador\PCCare.iss` | Script de Inno Setup del instalador de 64 bits. |
| `instalador\compilar.ps1` | Compila el instalador y calcula su SHA256. |
| `instalador\probar.ps1` | Instala, verifica y desinstala en silencio (lo usa CI). |
| `modulos\Idioma.ps1` | Motor de idiomas (traduce lo que se muestra; los datos siguen en español). |
| `modulos\idioma\en.tsv` | Diccionario ES a EN, una fila por texto. Las filas con `{0}` son plantillas. Todo texto nuevo de la interfaz necesita su fila. |
| `pruebas\Idioma.Tests.ps1` | Pruebas obligatorias del sistema de idiomas (las corre CI). |
