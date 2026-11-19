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
