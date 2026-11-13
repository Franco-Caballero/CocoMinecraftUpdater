# Auditoría de instalación SSH opcional — Coco Launcher / sandbox nazorepulgadora

Fecha de auditoría: 18 de octubre de 2026. Estado: **preparación local validada; no certificada en el sandbox**.

## Alcance y contrato

- Equipo destino previsto: nodo ZeroTier `5a84d2bb9e`, dirección local `10.77.37.116`, red Coco `58997fc5f3c0c001`.
- Host autorizado: `10.77.37.1`; su clave privada ed25519 permanece fuera del repositorio.
- El engine compartido distribuye **solo la clave pública** `CocoRemoteAccessHost.pub`. No se incorporan contraseñas, llaves privadas ni tokens ZeroTier.
- La opción `CONFIGURAR SSH` se presenta **solo tras verificar localmente** la identidad ZeroTier específica. El instalador elevado repite esa verificación.
- Instalar un servicio de administración remota **no** ocurre al abrir Coco Launcher. Requiere clic, diálogo de confirmación, UAC y `ACTIVAR` en el equipo de origen. Este límite es deliberado; no existe instalación SSH remota desatendida.
- Tras una activación autorizada, el servicio `sshd` puede funcionar por sí solo al cerrar Coco y en reinicios de Windows.
- Este mecanismo habilita SSH/SFTP; **no** crea un sincronizador, explorador encubierto ni envío indiscriminado de perfiles de Windows.

## Hallazgos y mitigaciones

| Prioridad | Riesgo comprobado / escenario | Estado actual |
|---|---|---|
| Crítica | `nazorepulgadora` sigue sin una instalación de prueba real. La IP/ping de ZeroTier no demuestran que SSH funcione. | **Abierto:** exige prueba en el equipo fuente y autenticación desde host. |
| Crítica | Una instalación 100 % sin fallos no puede garantizarse: UAC, GPO, Windows Update/FoD, antivirus, firewall, credenciales locales y estado de la máquina son externos al launcher. | **Limitación física:** fail-closed y diagnóstico, no promesa de éxito. |
| Alta | El engine se entrega a los demás jugadores. No deben recibir una puerta administrativa activada automáticamente. | **Mitigado:** el control de UI se oculta fuera del nodo indicado; el helper vuelve a comprobar identidad antes de modificar Windows. |
| Alta | Una clave pública inesperada o reemplazada alteraría a qué host se concede acceso. | **Mitigado:** clave pública embebida y pin exacto del material ed25519; clave privada no incluida. |
| Alta | `administrators_authorized_keys` con permisos de `Users`/identidades inesperadas impide o debilita autenticación. | **Mitigado:** DACL explícita con `SYSTEM` y `BUILTIN\Administradores` solamente; se revalida. |
| Alta | El archivo puede no terminar con salto de línea; agregar una clave pegada a la anterior la inutiliza. | **Mitigado y reproducido:** el sufijo agregado garantiza separador, duplicados evitados; pruebas LF/CRLF/sin final. |
| Alta | La instalación de OpenSSH puede dejar estado `NotPresent`, `InstallPending` o requerir reinicio. | **Mitigado parcialmente:** comprobar estado antes/después; detener si estado no seguro o requiere reinicio. |
| Alta | Instalar el componente crea una regla de Windows Firewall potencialmente amplia. | **Mitigado parcialmente:** regla propia de SSH restringida a host `10.77.37.1` y destino `10.77.37.116`, verificar sus filtros. Otras reglas preexistentes quedan fuera del alcance y deben auditarse. |
| Alta | Proceso diferente puede ocupar TCP 22 y un simple test de puerto dar falso positivo. | **Mitigado:** el listener debe pertenecer al PID del servicio `sshd` en ejecución. |
| Alta | Servidor `sshd` levantado no demuestra aceptación real de la clave ni SFTP. | **Abierto:** no anunciar certificación remota; prueba de extremo a extremo obligatoria. |
| Media | La IP puede no estar todavía asignada cuando se abre Coco. | **Mitigado parcialmente:** verificar nodo, red e IP antes de habilitar; si ZeroTier aún no está listo, el botón puede requerir reabrir Coco. |
| Media | Repetir instalación puede duplicar entradas de clave o reiniciar SSH sin necesidad. | **Mitigado:** clave idempotente, verifica unicidad; servicio existente `Running` no se reinicia gratuitamente. |
| Media | Un error a mitad de instalación deja parte del componente instalado. | **Abierto/controlado:** no se promete rollback de Windows; log por etapa, error explícito y reejecución segura donde sea posible. |
| Media | Al ejecutar UAC desde una cuenta estándar se necesitarán credenciales de administrador. | **Limitación de Windows:** no hay bypass. El usuario autorizado debe aceptar UAC/conocer una cuenta administrativa. |
| Media | Uso de un archivo de claves compartido entre cuentas administradoras: la clave puede autenticar frente a varios usuarios administradores. | **Riesgo residual:** aconsejar cuenta administrativa controlada y revisar `sshd_config`/permisos. |
| Media | Clave privada del host sin frase de contraseña; un atacante con acceso a ella y ZeroTier puede usarla. | **Riesgo residual:** proteger ACL y respaldos del host, evitar subirla a repositorios, considerar passphrase o agente. |
| Media | Configuración preexistente de `sshd_config` podría desactivar `PubkeyAuthentication`, cambiar puerto o `AuthorizedKeysFile`. | **Abierto:** una prueba externa real valida mejor que supuestos estáticos; no sobreescribir configuración ajena sin revisión. |

## Matriz de escenarios verificables

1. **Equipo equivocado / otro amigo:** el helper `-CheckTarget` rechaza, código `7`; no presentar botón ni intentar UAC.
2. **ZeroTier instalado pero sin `10.77.37.116`:** rechazar antes de tocar Windows.
3. **Clave pública ausente, inválida o manipulada:** rechazar por formato y pin exacto.
4. **Ventana de autorización cancelada:** no ejecutar instalador.
5. **UAC rechazado, permisos insuficientes o cuenta estándar:** mostrar error, no fingir activación.
6. **OpenSSH ya instalado:** no reinstalar componente. **No instalado:** usar característica opcional oficial de Windows.
7. **Windows Update sin acceso, GPO restrictiva, reinicio pendiente:** detenerse con causa, permitir reintento luego de corregir el requisito.
8. **Archivo de claves preexistente con/sin salto final:** conservar claves ajenas, agregar una única línea separada, DACL validada.
9. **Regla `OpenSSH-Server-In-TCP` existente:** actualizar y verificar filtro propio. Reglas adicionales de Windows permanecen bajo auditoría manual.
10. **SSH ya funcionando:** no reiniciarlo sin motivo. **Detenido:** arrancarlo y comprobar estado y PID del listener.
11. **Puerto TCP 22 ocupado o `sshd_config` incorrecto:** listener/PID/handshake deben fallar la certificación.
12. **Launcher cerrado, PC reiniciado, cambios de perfiles de red:** comprobar que `sshd` mantenga su inicio automático y que ZeroTier reconecte.
13. **WinSCP y acceso a archivos:** verificar SFTP manual desde host sin copiar carpetas masivamente.
14. **Revocación:** eliminar la clave pública concreta de `administrators_authorized_keys`, o deshabilitar `sshd` si no tiene otros usuarios.

## Pruebas realizadas localmente

- `tests/Test-CocoRemoteAccessSetup.ps1`: validación de clave ed25519, rechazo de claves malformadas, pin público, invariantes de consentimiento, restricción de nodo y empaquetado, casos de salto de línea e idempotencia.
- Pruebas de catálogo, lanzamiento, layout y test integrado con engine empaquetado.
- Parseo Windows PowerShell 5.1 de scripts modificados y `git diff --check`.
- Sonda local `-CheckTarget` ejecutada **en el host**: código `7`, correcto porque el host NO es `nazorepulgadora`.
- Prueba adversarial aislada de ACL sobre archivo temporal, revertida y limpiada; no se instaló `sshd` en el host.

Estas pruebas no sustituyen la instalación del componente en Windows del sandbox ni una sesión SFTP real.

## Criterios de aceptación pendientes antes de declarar producción

1. Publicar voluntariamente una nueva versión después de validar el diff, con hash de engine y política de distribución aprobada. **No se publicó en esta auditoría.**
2. En el sandbox, abrir la versión nueva, pulsar `CONFIGURAR SSH`, autorizar UAC y confirmar `ACTIVAR` localmente.
3. Revisar el log `%PROGRAMDATA%\CocoMinecraftUpdater\logs\ssh-setup.log` y estado del servicio.
4. En el sandbox consultar la huella de `%PROGRAMDATA%\ssh\ssh_host_ed25519_key.pub`; verificarla al primer acceso desde el host para evitar confiar a ciegas en la red.
5. Desde `10.77.37.1`, conectar con `ssh -o BatchMode=yes -i <clave_privada> <cuenta_admin>@10.77.37.116`, ejecutar un comando benigno de lectura y abrir SFTP con WinSCP.
6. Auditar desde el sandbox las reglas adicionales de firewall habilitadas para TCP 22 y validar que una máquina de prueba no autorizada no conecte.
7. Cerrar Coco Launcher y repetir conexión; reiniciar Windows del sandbox (solo cuando sea seguro) y repetir. Confirmar que no afectó Minecraft/experiencias.
8. Verificar visualmente el comportamiento en otro cliente Coco: el botón no aparece y no se ejecutó nada.

**Conclusión:** la opción SSH local con autorización expresa está mucho mejor defendida, pero **no hay base para afirmar que vaya a funcionar al 100 % en el primer arranque remoto ni que ya esté instalada**. Su único estado correcto antes de estas comprobaciones es *preparado para prueba en el sandbox, no certificado*.
