# Historial técnico del updater

Última revisión: 2026-07-26 (America/Santiago).

Consulta este archivo sólo al investigar regresiones del bootstrap, Bridge, Publisher, caché o actualización automática. La operación vigente está en `OPERACION.md`.

## Cronología resumida

- **0.5.35–0.5.37:** se corrigieron falso error inicial y detección de JVM, un `File.Replace` inválido con backup nulo y el orden de publicación/instalación. El Publisher pasó a instalar el EXE local antes de actualizar el host.
- **0.5.38–0.5.39:** se eliminaron salidas booleanas visibles, se corrigió UI/Bridge y se prohibieron degradaciones comparando `FileVersion`. Un helper antiguo ya no puede reemplazar un EXE más nuevo.
- **0.5.40:** `NetworkOnly` y la actualización completa recibieron mutex separados para que la red silenciosa no bloqueara la ventana ni el cierre de Minecraft. ZeroTier conserva serialización compatible con engines antiguos.
- **0.5.42:** un cliente real reveló que `ps2exe` esperaba EOF del pipe de entrada y que la elevación ocultaba progreso. Bridge pasó a cerrar su entrada, reutilizar autorizadores sanos, mostrar progreso elevado y producir diagnósticos del engine. También se mejoró la selección del proceso/GameDir y se desactivó TLSkinCape incompatible en perfiles TLauncher aplicables.
- **0.5.42, contenido:** se retiró `inventoryextended` con respaldo específico porque duplicaba de forma rota el inventario.
- **0.5.43:** el Publisher pasó a hidratar y verificar manifiesto, ZIP y engine del caché rápido antes de publicar y a archivar helpers bootstrap obsoletos.
- **0.5.44:** `ProcessBuilder.Redirect.DISCARD` resultó inválido como entrada en Java 25. Bridge conserva `PIPE` y cierra inmediatamente `process.getOutputStream()` para entregar EOF sin bloquear Minecraft.

## Contratos derivados

- La sustitución del EXE canónico no bloquea el engine; puede quedar una copia pendiente verificada y nunca degradar versión.
- El updater valida versión/Fabric y `--gameDir`; una instancia compatible abierta vence a un destino persistido obsoleto.
- Ante actualización visible, cierra únicamente el cliente objetivo, primero normalmente y después de ocho segundos por fuerza si no responde.
- Red y actualización tienen estados/mutex separados, pero ZeroTier se serializa.
- `NetworkOnly` no altera el pack cuando está sano y no existe monitor periódico permanente.
- El Publisher hidrata el caché local del mismo release antes de hacerlo público.
- La UI visible termina en `TODO LISTO` y espera `ACEPTAR`/Enter; los chequeos automáticos sanos permanecen silenciosos.
- Errores del bootstrap y engine generan un diagnóstico de Escritorio sin secretos.

Estos contratos tienen pruebas de regresión. No simplificarlos por intuición: identifica primero qué incidente evitaba cada uno.
