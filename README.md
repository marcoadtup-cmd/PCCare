# PC Care

Mantenimiento de Windows 11 de código abierto, todo en una sola ventana: limpieza, rendimiento, actualizaciones de aplicaciones y drivers, red, seguridad e informe del equipo.

Es una alternativa libre a las suites de limpieza comerciales. No contiene código ni recursos de ninguna de ellas.

- Gratis, sin publicidad, sin cuentas y sin enviar datos a ningún servidor.
- Funciona con PowerShell que ya trae Windows. No instala nada.
- Empieza en **modo simulación**: muestra qué haría sin tocar nada, hasta que tú lo desactives.
- Si se cierra o se corta a mitad de una tarea, al abrirlo te ofrece continuar.

## Cómo usarlo (3 pasos)

1. Descarga el ZIP de la última versión en la sección **Releases** de este repositorio (archivo `PCCare-vX.Y.Z.zip`).
2. Haz clic derecho sobre el ZIP, elige **Extraer todo** y abre la carpeta que se crea. No ejecutes nada desde dentro del ZIP.
3. Haz doble clic en **`Iniciar PC Care.cmd`** y acepta el aviso de administrador.

Si Windows muestra "Windows protegió su PC" (SmartScreen), pulsa **Más información** y luego **Ejecutar de todas formas**. Aparece porque el programa no está firmado digitalmente; el código es público y puedes revisarlo completo antes.

Requisitos: Windows 10 u 11, PowerShell 5.1 (viene incluido) y permisos de administrador. Las actualizaciones de aplicaciones usan `winget`, que viene con Windows 11 y con las versiones recientes de Windows 10.

## Qué hace cada página

| Página | Qué hace |
|---|---|
| Panel | Resumen del estado del equipo y el botón **Cuidado inteligente** (limpia, vacía la caché DNS y optimiza la unidad). |
| Limpieza | Basura de Windows, navegadores y Papelera. Archivos grandes y duplicados (van a la Papelera, no se borran). Entradas inválidas del registro con respaldo `.reg` previo. |
| Rendimiento | Programas de inicio, diagnóstico de problemas comunes y TurboPC (alto rendimiento solo cerrando lo que tú marques). |
| Monitor | CPU, memoria, red, temperatura y salud de discos en tiempo real. |
| Seguridad | Antivirus, Defender, firewall, BitLocker, TPM, Secure Boot y más. Solo lectura. |
| Actualizaciones | Aplicaciones (winget y Microsoft Store) y drivers firmados de Windows Update, con punto de restauración y respaldo de drivers antes de instalar. |
| Red | Diagnóstico de Wi-Fi, cable o internet compartido por USB: latencia, pérdida de paquetes, DNS, MTU. Mejoras opcionales con archivo para revertirlas. |
| Informe del equipo | Auditoría de solo lectura que genera un `Informe.html` y archivos CSV para compartir. |
| Tareas | Qué está corriendo, qué dejaste marcado sin ejecutar, la cola completa y las tareas que quedaron a medias. |
| Historial | Registro de todo lo que hizo PC Care y en qué modo (simulación o real). |

## Tareas, cola y reanudación

Todo lo que ejecutas pasa por una cola, una tarea a la vez, para que el equipo no se congestione. En la página **Tareas** ves:

- La tarea en ejecución, con sus opciones y el tiempo que lleva.
- Lo que tienes marcado en otras páginas y todavía no ejecutaste.
- La cola completa con estado, modo, hora y duración. Se guarda en disco.
- Botones para pausar la cola o quitar lo que aún no empezó.

Si cierras PC Care, se apaga el equipo o falla algo, al volver a abrirlo aparecen las tareas que quedaron a medias:

| Tipo de tarea | Qué pasa al reabrir |
|---|---|
| Análisis y diagnósticos (solo lectura) | Se repiten solos al abrir. |
| Limpieza de basura | Se ofrece repetirla, marcada por defecto. Es segura de repetir. |
| Papelera, actualizaciones, drivers, mejoras de red | Se ofrece continuar. Lo que ya estaba corriendo **queda sin marcar** porque pudo quedar a medias. |
| Registro, TurboPC, reparación de red, instalar herramientas | Nunca se reanudan solas. Se repiten a mano. |

Una tarea guardada como simulación nunca se repite en modo real.

Limitación conocida: si cancelas o cierras mientras `winget` o el generador de informe ya están corriendo, ese programa externo puede terminar por su cuenta unos segundos.

## Seguridad: qué hace y qué no

- Arranca en modo simulación. Para aplicar cambios de verdad hay que desactivarlo arriba a la derecha y confirmar.
- La limpieza solo borra dentro de una lista cerrada de carpetas temporales y de caché.
- No toca Windows, Program Files, ProgramData ni AppData al buscar archivos grandes o duplicados.
- No usa repositorios de drivers de terceros: solo Windows Update, winget y las herramientas oficiales del fabricante.
- Antes de limpiar el registro exporta un respaldo, y antes de instalar drivers puede crear un punto de restauración.
- No envía información fuera del equipo. Las únicas conexiones son las de winget, Windows Update y las pruebas de red que tú inicias.
- Los datos propios se guardan en `%LOCALAPPDATA%\PCCare` (cola, configuración) y en `Documentos\PCCare` (historial, respaldos, informes).

Más detalle y cómo reportar un problema de seguridad en [SECURITY.md](SECURITY.md).

## Verificar la descarga

Cada release incluye un archivo `.sha256`. En PowerShell:

```powershell
Get-FileHash .\PCCare-vX.Y.Z.zip -Algorithm SHA256
```

El resultado debe coincidir con el del archivo `.sha256`.

## Probar que funciona en tu equipo

Haz doble clic en **`Autoprueba PC Care.cmd`**. Ejecuta los análisis en solo lectura y deja `PCCare_autoprueba_NOMBRE.log` en la misma carpeta. Para incluir drivers, informe de auditoría y red (tarda varios minutos), abre una consola en la carpeta y ejecuta `"Autoprueba PC Care.cmd" completa`.

Si algo falla, adjunta ese archivo al abrir un Issue.

## Problemas frecuentes

| Síntoma | Qué hacer |
|---|---|
| No se abre y no muestra nada | Ejecuta `Iniciar PC Care.cmd` otra vez y acepta el aviso de administrador. Si sigue igual, usa la autoprueba y abre un Issue con el log. |
| Dice que falta un archivo de `modulos` | Extrajiste solo `PCCare.ps1`. Extrae **toda** la carpeta del ZIP. |
| "La ejecución de scripts está deshabilitada" | Abre PC Care con `Iniciar PC Care.cmd`, que ya usa el modo correcto, en vez de hacer doble clic en el `.ps1`. |
| Las aplicaciones no aparecen | Comprueba que `winget --version` funciona en una consola. Instala "App Installer" desde Microsoft Store si no existe. |
| Aparece "PC Care ya está abierto" | Solo se permite una ventana a la vez. Búscala en la barra de tareas. |

## Desinstalar

No instala nada. Borra la carpeta de PC Care y, si quieres, `%LOCALAPPDATA%\PCCare` y `Documentos\PCCare`.

## Contribuir

Los aportes son bienvenidos. Lee [CONTRIBUTING.md](CONTRIBUTING.md).

## Licencia y aviso

Licencia MIT, ver [LICENSE](LICENSE). El software se entrega tal cual, sin garantía. Haz una copia de seguridad antes de aplicar cambios en modo real.

PC Care es un proyecto independiente. No está afiliado ni respaldado por IObit, Microsoft ni ningún otro fabricante. Los nombres de productos que se mencionan pertenecen a sus dueños.
