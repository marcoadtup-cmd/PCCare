# Registro de cambios

Cada mejora se anota aquí **antes** de aceptarse, con fecha y hora de Lima (UTC-5). Las versiones nuevas van arriba.

## Cómo se escribe una entrada

```
## X.Y.Z - AAAA-MM-DD HH:MM (hora de Lima)

Autor: nombre o usuario de GitHub
Revisado por: quien aprobó el cambio

### Nuevos módulos
### Mejoras
### Correcciones
### Actualizaciones
### Seguridad
```

Se omiten los apartados que no apliquen.

## 2.5.0 - 2026-11-27 12:45 (hora de Lima)

Autor: NOVALTEK
Revisado por: pendiente de revisión de NOVALTEK

### Nuevos módulos
- **Antivirus activo y escaneo con Microsoft Defender** (`modulos\Proteccion.ps1`). En Seguridad, PC Care detecta qué antivirus protege el equipo (SecurityCenter2) y el estado de Defender (activo, desactivado o en modo pasivo). Si Defender puede escanear, ofrece escaneo rápido, completo o de una carpeta. Si la protección la administra otro antivirus (por ejemplo Kaspersky o ESET), lo dice y no intenta escanear con Defender. El escaneo solo corre en modo real, porque Defender aplica su propia configuración (cuarentena); las amenazas detectadas se listan en la misma tarjeta.
- **Resumen honesto, impacto y último análisis** (`modulos\Resumen.ps1`). En el Panel: riesgos reales, espacio recuperable y actualizaciones disponibles se muestran por separado, sin sumarlos en una sola cifra de "problemas". El registro va aparte y se aclara que limpiarlo no acelera el equipo.

### Mejoras
- Ficha del equipo en el Panel: modelo, procesador, memoria RAM, versión de Windows y espacio del disco del sistema.
- Puntos de color en el menú (Limpieza, Rendimiento, Seguridad y Actualizaciones) en dos niveles: rojo para riesgos críticos y ámbar para lo mejorable. El espacio recuperable nunca es rojo.
- "Lo que PC Care ya hizo aquí": suma real de espacio liberado y acciones aplicadas en modo real (limpieza, Papelera, registro, arranque y acciones de diagnóstico). Se guarda en `%LOCALAPPDATA%\PCCare\impacto.json`. Las simulaciones no cuentan.
- Último análisis guardado en `%LOCALAPPDATA%\PCCare\ultimo_analisis.json`, con botón para ver sus resultados al abrir PC Care sin volver a analizar. Solo se guarda cuando hay riesgos y basura analizados, para no pisar un análisis completo con uno parcial.
- La ventana de tareas al abrir muestra el tiempo aproximado de cada tarea.
- La tarea de seguridad al abrir también detecta el antivirus activo.
- El análisis por categoría y el análisis de todo juntos ya existían (ventana de tareas al abrir con casillas y botón "Analizar todo"); se mantienen.

### Correcciones
- Seguridad marcaba "Crítico: la protección en tiempo real está desactivada" en equipos protegidos por otro antivirus. Ahora, si hay otro antivirus activo, la fila de Defender queda "Al día" con el nombre de quien protege, y no se evalúa la antigüedad de las firmas de Defender.

### Actualizaciones
- Versión 2.5.0.
- 76 textos nuevos en inglés en `modulos\idioma\en.tsv`.
- Autoprueba: antivirus activo (solo lectura), decisión de escaneo, escaneo en simulación (no se inicia), resumen separado, niveles de color, impacto acumulado, último análisis (incluido archivo dañado) y ficha del equipo.

## 2.4.0 - 2026-11-26 15:05 (hora de Lima)

Autor: NOVALTEK
Revisado por: NOVALTEK

### Nuevos módulos
- **Ventana de tareas al abrir.** Al abrir PC Care aparece una lista de tareas (restauración, basura, seguridad, programas de inicio, diagnóstico, programas en memoria y registro), todas marcadas y de solo lectura. Con **GO** se ejecutan solo las marcadas; cada fila muestra su estado (en espera, en curso, ✓ Listo, ✖ Error) y hay una barra de avance. El botón **Detalle** de cada fila abre una sub-ventana con cómo terminó la tarea, el resultado y los mensajes que dejó. Código de la lista y los estados en `modulos\Inicio.ps1`.

### Mejoras
- Antes, al abrir, el análisis se lanzaba solo sin avisar. Ahora tú decides qué ejecutar y cuándo.
- La casilla "Mostrar esta ventana al abrir PC Care" se recuerda por equipo en `config.json`. Si la desmarcas, las tareas se ejecutan solas como en versiones anteriores.
- Textos de la ventana traducidos al inglés.
- La autoprueba comprueba la lista de tareas al abrir (ids únicos, que cada tarea exista) y la lógica de estados y de detalle.

### Actualizaciones
- Versión 2.4.0.

## 2.3.0 - 2026-11-20 17:45 (hora de Lima)

Autor: NOVALTEK
Revisado por: NOVALTEK

### Nuevos módulos
- **`PCCare.exe`, lanzador sin ventana de consola.** Programa pequeño (C#, se compila con el `csc.exe` que ya trae Windows, no instala nada) que abre PC Care sin mostrar PowerShell ni ventanas negras. Pide permisos de administrador una sola vez (UAC), pasa los argumentos (`-Idioma`, `-AutoPrueba`, etc.) y, si PC Care termina con error, lo muestra en un cuadro y lo anota en `%LOCALAPPDATA%\PCCare\lanzador.log`. Antes ese texto salía en la consola. Código en `lanzador\Program.cs`. Es la fase 1 del paso a una aplicación compilada; el motor sigue siendo PowerShell.
- El instalador y los accesos directos del menú Inicio y del escritorio abren ahora `PCCare.exe`. El ZIP portable lo incluye. `Iniciar PC Care.cmd` sigue funcionando y usa el lanzador si lo encuentra.

### Mejoras
- Al cambiar el idioma, PC Care se reabre por el lanzador (sin consola).
- CI: nuevo trabajo **lanzador** (obligatorio) que compila `PCCare.exe` y comprueba: programa de ventana sin consola, producto y versión, permiso de administrador, paso de argumentos con espacios, código de salida, registro de errores y aviso cuando falta `PCCare.ps1`.
- La prueba del instalador ahora instala `PCCare.exe`, lo compara con el compilado y abre la autoprueba con él.

### Actualizaciones
- Versión 2.3.0.

## 2.2.0 - 2026-11-20 08:33 (hora de Lima)

Autor: NOVALTEK
Revisado por: NOVALTEK

### Nuevos módulos
- **Interfaz en español e inglés.** Lista **Idioma / Language** en la barra superior (junto al botón de simulación). Cambiarla guarda la elección en `%LOCALAPPDATA%\PCCare\config.json` y ofrece reiniciar PC Care para aplicarla (si hay tareas en curso, se aplica la próxima vez que se abra). Sin elección guardada, usa el idioma de Windows: español si es español, inglés en cualquier otro caso. También se puede forzar con `PCCare.ps1 -Idioma en` o `-Idioma es`.
- `modulos\Idioma.ps1` (motor) y `modulos\idioma\en.tsv` (diccionario ES a EN, 800 entradas). Se traduce solo lo que se ve: botones, menús, tablas, mensajes, confirmaciones y el informe HTML (se abre una copia `Informe_EN.html`). Los datos internos, el historial y los archivos de configuración siguen en español para que nada dependa del idioma. Si falta una traducción se muestra el texto en español.
- **Proceso de firma digital** del instalador con SignPath Foundation, integrado en `publicar.yml`. Se activa solo cuando el proyecto esté aprobado en SignPath y existan la variable `SIGNPATH_ORGANIZATION_ID` y el secreto `SIGNPATH_API_TOKEN` en el repositorio. Cada versión se firma tras una aprobación manual, se comprueba que la firma sea válida y el `.sha256` publicado es el del archivo firmado. Sin esa configuración, la release sale sin firma como hasta ahora.
- `pruebas\Idioma.Tests.ps1`: pruebas del sistema de idiomas.

### Mejoras
- CI: nuevo paso **obligatorio** que ejecuta las pruebas de idiomas (diccionario bien formado, plantillas, XAML traducido válido, informe) y bloquea el cambio si fallan.
- El instalador de prueba también compara `modulos\idioma\en.tsv` con el del repositorio.
- Las notas de cada release indican si el instalador está firmado y, en ese caso, incluyen la atribución a SignPath. Están en español e inglés.
- README y SECURITY: sección de firma digital, política de firma de código, roles y declaración de privacidad.

### Correcciones
- Las notas de la release mostraban tildes rotas ("VersiÃ³n"). El paso que las genera ahora corre en PowerShell 7, que lee el script en UTF-8.

### Actualizaciones
- Versión 2.2.0.

## 2.1.0 - 2026-11-19 17:25 (hora de Lima)

Autor: NOVALTEK
Revisado por: NOVALTEK

### Nuevos módulos
- Página **Acerca de y ayuda**: versión instalada, datos del equipo para soporte (con botón copiar), contacto y enlaces al repositorio para descargar la última versión, ver todas las versiones, reportar un problema y leer la política de seguridad. Solo abre direcciones del repositorio oficial y solo cuando el usuario pulsa un botón; PC Care sigue sin consultar internet por su cuenta.
- **Instalador para Windows de 64 bits** (`PCCare-Setup-X.Y.Z-x64.exe`, la versión va en el nombre). Instala en Archivos de programa, crea accesos en el menú Inicio, acceso opcional en el escritorio y desinstalador. Conserva los datos del usuario al desinstalar.

### Mejoras
- La release publica ahora el instalador y la versión portable (`PCCare-X.Y.Z-portable.zip`), cada uno con su `.sha256` y una certificación de origen de GitHub (`gh attestation verify`).
- CI: nuevo trabajo `instalador` que compila, instala, compara cada archivo con el repositorio y desinstala en silencio en cada cambio. Al publicar, la etiqueta debe coincidir con la versión del programa.
- Limpieza de navegadores: ahora incluye Vivaldi y Chromium, y avisa antes de limpiar y en el resultado cuando hay navegadores abiertos.

### Correcciones
- El selector de modo simulación/real era una casilla que, en modo real, quedaba sin marca y parecía desactivada. Ahora es un botón de estado: verde "SIMULACIÓN ACTIVA" o naranja "MODO REAL ACTIVO", con el texto de lo que hace al pulsarlo.
- Limpiar el caché de navegadores dejaba parte de los archivos sin borrar mientras el navegador estaba abierto, sin explicar por qué. Ahora se indica qué navegadores están abiertos y que hay que cerrarlos y repetir la limpieza.

### Seguridad
- Los enlaces del programa se abren con el navegador del usuario (sin permisos de administrador) y se bloquean si no pertenecen al repositorio oficial. La autoprueba lo verifica.

## 2.0.4 - 2026-11-19 13:50 (hora de Lima)

Autor: NOVALTEK
Revisado por: NOVALTEK

### Correcciones
- La autoprueba de la 2.0.3 localizó el punto exacto del fallo: `ArgumentException: Los tipos de argumentos no coinciden` al convertir la lista de tareas con `@($Registros)` en Windows PowerShell 5.1. Guardar la cola ahora copia los registros por posición a una lista simple y el serializador recorre listas y diccionarios sin enumeradores. `Set-TareasInterrumpidas` también recorre por posición.
- El mensaje de error de la cola indica ahora un paso más preciso (contar, copiar, convertir, escribir o reemplazar).

## 2.0.3 - 2026-11-19 13:35 (hora de Lima)

Autor: NOVALTEK
Revisado por: NOVALTEK

### Correcciones
- La autoprueba de la 2.0.2 mostró el motivo real del fallo al guardar la cola: `ArgumentException: Los tipos de argumentos no coinciden`, un error de `ConvertTo-Json` en Windows PowerShell 5.1. La cola ahora se escribe con un serializador JSON propio, mínimo y predecible (`ConvertTo-TextoJson`), que no depende de `ConvertTo-Json`. El formato del archivo no cambia.
- Si el guardado vuelve a fallar, el mensaje indica en qué paso ocurrió (crear carpeta, convertir a JSON, escribir o reemplazar) y la línea del código.

## 2.0.2 - 2026-11-19 13:05 (hora de Lima)

Autor: NOVALTEK
Revisado por: NOVALTEK

### Correcciones
- La autoprueba de la versión 2.0.1 falló en "Cola persistente (guardar y recuperar)" con "no se pudo guardar la cola". Guardar la cola ahora reintenta hasta 3 veces (un antivirus puede tener el archivo abierto un instante), reemplaza el archivo sin depender de `Move-Item` y registra el motivo exacto del fallo. La autoprueba muestra ese motivo junto a la ruta usada, para poder corregir la causa real si vuelve a ocurrir.
- `Cola.ps1`, `Ejecutores.ps1` y `AuditoriaPC.ps1` se habían publicado sin BOM UTF-8 y con saltos de línea LF. Windows PowerShell 5.1 lee un archivo sin BOM como ANSI y los acentos de los mensajes podían verse dañados. Ahora los tres llevan BOM UTF-8 y saltos CRLF, igual que el resto. La validación automática "Archivos con BOM UTF-8" había detectado el problema en la 2.0.1.

### Seguridad
- El flujo "Exigir CHANGELOG" no se aplica a los Pull Requests de `dependabot[bot]` (solo suben la versión de una acción oficial de GitHub). Siguen necesitando tu revisión y aprobación como cualquier otro cambio.

## 2.0.1 - 2026-11-19 12:05 (hora de Lima)

Autor: NOVALTEK
Revisado por: NOVALTEK

### Correcciones
- Las páginas Red e Informe decían "Diagnosticando..." o "Generando..." aunque la tarea solo estaba esperando en la cola detrás de otra (por ejemplo una actualización de aplicaciones). Ahora muestran "EN COLA", cuántas tareas esperan antes y cuál se está ejecutando, y cambian a "Diagnosticando..." cuando realmente empieza.

### Mejoras
- Las tareas pueden definir un aviso que se muestra al iniciar (`-AlIniciar`).

## 2.0.0 - 2026-11-19 11:50 (hora de Lima)

Autor: NOVALTEK
Revisado por: NOVALTEK

### Nuevos módulos
- Cola persistente de tareas (`modulos\Cola.ps1`) con política de reanudación por tipo de tarea.
- Página **Tareas**: tarea en ejecución, opciones marcadas, cola completa con estado y duración.
- Página **Actualizaciones**: aplicaciones (winget y Microsoft Store) y drivers de Windows Update dentro de la ventana principal.
- Páginas **Red** e **Informe del equipo** integradas, con las herramientas de diagnóstico de red y auditoría.

### Mejoras
- Todo se ejecuta desde la ventana principal; ya no hay programas aparte.
- Pausa de la cola y opción de quitar lo que aún no empezó.
- Una sola ventana a la vez para no pisar la cola guardada.
- Las tareas de actualizaciones, drivers, Store y red aceptan modo simulación.
- Autoprueba ampliada (cola, módulos, winget) y modo `-Completa`.

### Seguridad
- Una tarea guardada en simulación nunca se repite en modo real.
- Lo que estaba a medias al cerrar queda sin marcar para que el usuario decida.

### Actualizaciones
- Validación automática de sintaxis en GitHub Actions.

## 1.1.0

- Primera versión pública del conjunto de herramientas: limpieza, rendimiento, monitor, seguridad e historial.
