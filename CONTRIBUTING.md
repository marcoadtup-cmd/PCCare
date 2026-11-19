# Cómo contribuir

Gracias por querer mejorar PC Care. Un Issue claro ya es una gran ayuda.

## Reportar un error

Adjunta:

- Versión de PC Care y de Windows.
- Qué hiciste, qué esperabas y qué pasó.
- El archivo `PCCare_autoprueba_NOMBRE.log` (ver README).
- Captura de pantalla si es un problema visual. **Quita nombres de equipo, usuarios y rutas privadas.**

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
| `PCCare.ps1` | Ventana principal, motor de cola, limpieza, rendimiento, monitor, seguridad y autoprueba. |
| `modulos\Cola.ps1` | Registro persistente de tareas y políticas de reanudación. |
| `modulos\Actualizaciones.ps1` | Motor en segundo plano de aplicaciones (winget) y drivers. |
| `modulos\UI_Actualizaciones.ps1` | Página Actualizaciones. |
| `modulos\Ejecutores.ps1` | Tareas que lanzan el informe de auditoría y la optimización de red. |
| `modulos\UI_InformeRed.ps1` | Páginas Informe y Red. |
| `modulos\AuditoriaPC.ps1` | Auditoría de solo lectura que genera `Informe.html`. |
| `modulos\OptimizarRed.ps1` | Diagnóstico y mejoras de red. |
