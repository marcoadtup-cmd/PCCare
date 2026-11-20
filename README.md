# PC Care

Mantenimiento de Windows 11 de código abierto, todo en una sola ventana: limpieza, rendimiento, actualizaciones de aplicaciones y drivers, red, seguridad e informe del equipo.

Es una alternativa libre a las suites de limpieza comerciales. No contiene código ni recursos de ninguna de ellas.

- Gratis, sin publicidad, sin cuentas y sin enviar datos a ningún servidor.
- Funciona con PowerShell que ya trae Windows. No instala nada.
- Empieza en **modo simulación**: muestra qué haría sin tocar nada, hasta que tú lo desactives.
- Si se cierra o se corta a mitad de una tarea, al abrirlo te ofrece continuar.

## Cómo usarlo

Las versiones nuevas se publican en la sección **Releases** de este repositorio: https://github.com/marcoadtup-cmd/PCCare/releases/latest. Dentro del programa, la página **Acerca de y ayuda** abre ese enlace con un clic.

### Opción A: instalador para Windows de 64 bits (recomendado)

1. Descarga `PCCare-Setup-X.Y.Z-x64.exe` (el número de versión va en el nombre del archivo).
2. Verifica el SHA256 (ver más abajo) y ejecútalo. Acepta el aviso de administrador.
3. Abre **PC Care** desde el menú Inicio.

### Opción B: versión portable (sin instalar)

1. Descarga `PCCare-X.Y.Z-portable.zip`.
2. Clic derecho, **Extraer todo**. No ejecutes nada desde dentro del ZIP.
3. Doble clic en **`Iniciar PC Care.cmd`** y acepta el aviso de administrador.

Si Windows muestra "Windows protegió su PC" (SmartScreen), pulsa **Más información** y luego **Ejecutar de todas formas**. Aparece porque el instalador aún no está firmado digitalmente (ver **Firma digital**). Está compilado por GitHub Actions a partir del código público de este repositorio, y puedes comprobarlo con la verificación de más abajo.

Requisitos: Windows 11 (probado) o Windows 10 (compatible, sin pruebas propias todavía), PowerShell 5.1 (viene incluido) y permisos de administrador. El instalador es solo para 64 bits; la versión portable funciona igual en el mismo sistema. Las actualizaciones de aplicaciones usan `winget`, que viene con Windows 11 y con las versiones recientes de Windows 10.

## Idioma / Language

PC Care se ve en **español** o **inglés**. Cambia el idioma con la lista de la barra superior; PC Care ofrece reiniciarse para aplicarlo. Si no eliges, usa el idioma de Windows. Los informes HTML también salen en el idioma elegido.

PC Care comes in **Spanish** or **English**. Change it with the list in the top bar; PC Care offers to restart to apply it. If you do not choose, it uses the Windows language. HTML reports also follow the chosen language.

Para forzar un idioma al abrir desde una consola: `PCCare.ps1 -Idioma en` o `-Idioma es`. Para sumar otro idioma, copia `modulos\idioma\en.tsv`, traduce la segunda columna y abre un Pull Request (ver [CONTRIBUTING.md](CONTRIBUTING.md)).

## Firma digital y política de firma de código

**Estado: en preparación.** El proceso de firma ya está integrado en la publicación de versiones, pero las releases salen **sin firma** hasta que SignPath Foundation apruebe el proyecto [POR CONFIRMAR]. Cuando esté activo, el instalador aparecerá firmado por **SignPath Foundation** (el certificado se emite a la fundación, no a NOVALTEK) y esta sección se actualizará.

Free code signing provided by [SignPath.io](https://signpath.io), certificate by [SignPath Foundation](https://signpath.org).

**Política de firma de código (Code signing policy)**

| Tema | Regla |
|---|---|
| Qué se firma | Solo el instalador `PCCare-Setup-X.Y.Z-x64.exe`, compilado por GitHub Actions desde este repositorio. La versión portable (ZIP) no se firma: se verifica con su SHA256 y su attestation. |
| Quién compila | Únicamente el flujo `publicar.yml` al crear una etiqueta `vX.Y.Z`. No se firma nada compilado en un equipo personal. |
| Roles | Autor, revisor y aprobador: Marco, dueño del proyecto (NOVALTEK). Todo cambio de terceros entra por Pull Request revisado y aprobado por él. [POR CONFIRMAR: SignPath puede exigir roles distintos] |
| Aprobación | Cada firma de una release se aprueba a mano en SignPath. Con la autenticación en dos pasos activa en SignPath y en GitHub. |
| Qué no se firma | Código de terceros, herramientas que identifiquen o exploten vulnerabilidades ni nada ajeno a este proyecto. |

**Privacidad.** PC Care no envía información a ningún servidor ni tiene telemetría. Solo se conecta a internet cuando tú inicias una acción que lo necesita (winget, Windows Update, la medición de velocidad opcional, abrir una página de GitHub). Este programa no transfiere datos a otros sistemas en red salvo que el usuario lo pida.

**Cambios en el sistema.** En modo real, PC Care modifica el equipo (archivos temporales, programas de inicio, plan de energía, registro con respaldo, drivers, red). El modo simulación está activo por defecto y cada acción pide confirmación. Se desinstala desde Configuración, Aplicaciones.

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

Cada release incluye un archivo `.sha256` por descarga. Cuando el instalador esté firmado, también puedes ver la firma con clic derecho, Propiedades, Firmas digitales. En PowerShell:

```powershell
Get-FileHash .\PCCare-Setup-X.Y.Z-x64.exe -Algorithm SHA256
```

El resultado debe coincidir con el del archivo `.sha256`. Además, cada archivo lleva una certificación de origen de GitHub. Con la herramienta `gh` puedes comprobar que lo compiló este repositorio y no otro:

```powershell
gh attestation verify .\PCCare-Setup-X.Y.Z-x64.exe --repo marcoadtup-cmd/PCCare
```

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

- Instalador: Configuración, Aplicaciones, **PC Care**, Desinstalar (o el acceso **Desinstalar PC Care** del menú Inicio).
- Portable: borra la carpeta.

En ambos casos tus datos se conservan. Si quieres quitarlos también, borra `%LOCALAPPDATA%\PCCare` y `Documentos\PCCare`.

## Contribuir

Los aportes son bienvenidos. Lee [CONTRIBUTING.md](CONTRIBUTING.md).

## Contacto

Para consultas, ideas o reportes que no sean públicos: **marcoadtup@gmail.com**. Para errores y mejoras, usa los Issues de este repositorio.

## Licencia y aviso

Licencia MIT, ver [LICENSE](LICENSE). El software se entrega tal cual, sin garantía. Haz una copia de seguridad antes de aplicar cambios en modo real.

PC Care es un proyecto de NOVALTEK, independiente. No está afiliado ni respaldado por IObit, Microsoft ni ningún otro fabricante. Los nombres de productos que se mencionan pertenecen a sus dueños.
