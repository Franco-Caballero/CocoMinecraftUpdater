# Avisos y navegador: YAPYAP y CRACK

Inspección de los **ZIP publicados**, sin ejecutar juegos ni modificar instalaciones, solicitada por el anfitrión el 2026-11-08. No se encontraron instalaciones en las rutas predeterminadas/registradas durante esta revisión. Se leyeron por HTTP Range únicamente el directorio ZIP y las DLL requeridas: unos 10,7 MB para YAPYAP y 11,5 MB para CRACK; no se descargaron los paquetes completos. Las DLL extraídas en memoria coincidieron con los SHA-256 fijados en el catálogo y pasaron la lectura/CRC del ZIP.

| Juego | ZIP publicado SHA-256 | Protección encontrada en winmm.dll | Accesos .url en ZIP |
|---|---|---|---:|
| YAPYAP | `86f7b397ba13340c79428d6a4bf2e73228e7ea238bc0e8252b8978eb3593968b` | Dos imports `MessageBeep`, sin imports `MessageBox` | 0 |
| CRACK | `403e935434806d4cfaff3c1d508c5cb6e500c499cab5f079aaf95f2caf2c4174` | Dos imports `MessageBeep`, sin imports `MessageBox` | 0 |

DLL verificadas:

- YAPYAP `winmm.dll`: `1ef2c62bd00105afea1326f2df28bad16acb7ff712ea1f1cec4916164354bf57`; `OnlineFix64.dll`: `75f9bfddf4ab6ba940b1aafdad2de37627f7e061edb90969c5af1d6e5b1fb996`.
- CRACK `winmm.dll`: `350b435820a94644fac0116b841f5bb2b9c6ff632e8079429e4df16a1983dab4`; `OnlineFix64.dll`: `fe45ada8cc8f25bc6809dc2de345fb4b7a6a194afd13cb38da9698b4ae84461a`.
- Todos son PE x64. En los imports parseados y literales ANSI de las dos OnlineFix64 no apareció `ShellExecuteW/A`; **esto no demuestra ausencia de una apertura dinámica u otra ruta**. No se trazaron ni ejecutaron esas DLL en este examen.

Conclusión: ambos paquetes ya contienen una medida binaria para los MessageBox del proxy y eliminan accesos promocionales. La aplicación conserva además hashes de aceptación por versión en su tabla Online-Fix. **No están certificados como libres de aviso y navegador en un primer arranque limpio.** La evidencia previa de CRACK registró aviso y página en el primer intento y ausencia al reabrir en la misma cuenta tras registrar hashes; YAPYAP también tenía primer arranque limpio pendiente. No trasladar a estos títulos el resultado positivo observado de Party Animals.

Para cerrar la validación: identificar cualquier ruta promocional restante siguiendo la [guía maestra](AGENT_ADD_GAME.md#evitar-avisos-promocionales-y-aperturas-de-navegador-todos-los-juegos), preparar por hash exacto si procede y probar instalación/primer arranque aislados, avisando antes al anfitrión y sin borrar estado existente. No se aplicó ningún cambio a los paquetes de YAPYAP o CRACK durante esta revisión.
