/** Actionable UI diagnostics for native operations. A Windows error alone does
 * not establish that Defender quarantined a file; never recommend disabling
 * protection or silently changing Windows permissions. */
export type NativeFailureKind='space'|'locked'|'permissions'|'integrity'|'network'|'source'|'recovery'|'cancelled'|'unknown';
export type NativeFailureAdvice={kind:NativeFailureKind;summary:string;detail:string};

function nativeDetail(error:unknown):string{
  const value=error instanceof Error?error.message:typeof error==='string'?error:String(error??'');
  return value.replace(/[\u0000-\u001f\u007f]/g,' ').replace(/https?:\/\/\S+/gi,'[dirección remota omitida]')
    .replace(/\b(?:token|password|authorization|signature|key)=\S+/gi,'[dato protegido]')
    .trim().slice(0,400)||'No se recibieron detalles adicionales.';
}

export function nativeFailureGuidance(error:unknown,action:'install'|'repair'|'prepare'|'upgrade'|'recover'):NativeFailureAdvice{
  const detail=nativeDetail(error);
  const raw=detail.toLocaleLowerCase('es');
  const start=action==='install'?'La instalación':action==='upgrade'?'La actualización':action==='recover'?'La recuperación':action==='prepare'?'La preparación':'La reparación';
  const advice=(kind:NativeFailureKind,info:string):NativeFailureAdvice=>({kind,summary:`${start} no se completó. ${info}`,detail});
  if(/(?:sha-?256|checksum|digest|integridad|firma inválida|hash mismatch|hash incorrect|tamper|archivo corrupto|zip corrupt)/i.test(raw))
    return advice('integrity','El contenido no superó la comprobación de integridad. No ejecutes ni fuerces ese archivo; revisa su procedencia y vuelve a obtener una copia válida.');
  if(/(?:espacio insuficiente|sin espacio|not enough space|insufficient (?:disk |free )?space|disk full|no space left|os error 112|error_disk_full|0x80070070)/i.test(raw))
    return advice('space','No queda espacio libre suficiente en el volumen de destino. Libera espacio sin borrar partidas y vuelve a intentarlo.');
  if(/(?:sharing violation|being used by another process|en uso por otro proceso|archivo en uso|os error 32|error_sharing_violation|0x80070020|file is locked)/i.test(raw))
    return advice('locked','Windows mantiene un archivo ocupado. Cierra el juego y las aplicaciones que lo estén usando; Coco conservará la recuperación disponible.');
  if(/(?:access denied|permission denied|acceso denegado|permiso denegado|os error 5\b|error_access_denied|0x80070005|carpeta protegida)/i.test(raw))
    return advice('permissions','Windows denegó acceso a la carpeta o archivo. Revisa sus permisos y, si sospechas un bloqueo del antivirus, consulta el Historial de protección de Seguridad de Windows. Coco no necesita desactivar Defender.');
  if(/(?:content-range|content-length del fragmento|etag cambi[oó]|http 416|status 416|origen rechaz[oó] rango|no soporta las descargas parciales|redirigi[oó].*no cifrada|redirect.*http)/i.test(raw))
    return advice('source','El servidor entregó un rango, una identidad de archivo o una redirección incompatible. Coco detuvo la transferencia sin confiar en esos bytes. Reintenta cuando el origen sea válido; no fuerces ni sustituyas archivos de caché manualmente.');
  if(/(?:timed? ?out|timeout|error 429|http 429|http 5\d\d|status 429|status 5\d\d|connection reset|dns|tls|certificado|sin conexión|network|conexión rechazada|fallaron.*mirror)/i.test(raw))
    return advice('network','La descarga o conexión se interrumpió. Revisa la conexión e inténtalo de nuevo; la caché verificada permite reutilizar lo ya obtenido.');
  if(/(?:journal|rollback|recovery|required|recuperación pendiente|transacci[oó]n interrumpida)/i.test(raw))
    return advice('recovery','Puede quedar una transacción pendiente. Revisa la opción Recuperar en la ficha del juego antes de repetir la operación.');
  if(/(?:cancelled|canceled|cancelada|cancelado|cancelación solicitada)/i.test(raw))
    return advice('cancelled','Se atendió una cancelación. Comprueba el estado del juego antes de volver a intentarlo.');
  return advice('unknown','Comprueba el estado de la instalación o usa Recuperar si aparece una operación interrumpida. No se borrarán partidas automáticamente.');
}
