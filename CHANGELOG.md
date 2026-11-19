# Cambios

## 2.0.0

- Todo se ejecuta desde la ventana principal: actualizaciones de aplicaciones y drivers, informe del equipo y diagnóstico de red ya no son programas aparte.
- Nueva página **Tareas**: tarea en ejecución, opciones marcadas, cola completa con estado y duración.
- Cola persistente en disco. Si PC Care se cierra a mitad de una tarea, al abrirlo se ofrece reanudarla según su riesgo.
- Pausa de la cola y opción de quitar lo que aún no empezó.
- Una tarea guardada en simulación nunca se repite en modo real.
- Una sola ventana a la vez para no pisar la cola guardada.
- Las tareas de actualizaciones, drivers, Store y red aceptan modo simulación.
- Autoprueba ampliada (cola, módulos, winget) y modo `-Completa` (drivers, informe y red).
- Validación automática en GitHub Actions.

## 1.1.0

- Primera versión pública del conjunto de herramientas: limpieza, rendimiento, monitor, seguridad e historial.
