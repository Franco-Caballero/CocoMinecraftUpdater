import { ArrowRight, FileArchive, Gamepad2, X } from 'lucide-react';

type Props={
  onExplore:()=>void;
  onOpenPackage:()=>void;
  onDismiss:()=>void;
  catalogReady:boolean;
  installedCount:number;
  hostStudioAvailable?:boolean;
};

// Pure onboarding: no network installation, UAC, game modification or forced
// profile setup. The catalog and first game can be explored immediately.
export default function FirstRun({onExplore,onOpenPackage,onDismiss,catalogReady,installedCount,hostStudioAvailable=false}:Props){
  const carried=installedCount>0;
  const title=!catalogReady?'Todavía no hay juegos.':'Elige un juego y a jugar.';
  const body=hostStudioAvailable
    ?'Como anfitrión, puedes preparar juegos en Host Studio y revisar paquetes de prueba. Los amigos solo reciben juegos aprobados en el catálogo firmado.'
    :!catalogReady
      ?'La biblioteca aún no tiene juegos disponibles. Cuando el anfitrión apruebe y publique juegos en el catálogo verificado, aparecerán aquí solos. No necesitas recibir archivos de otras personas.'
      :'Instala cualquiera con un clic. Todo lo que ves lo aprobó el anfitrión, y los juegos nuevos aparecen solos.';
  return <section className="first-run" aria-labelledby="firstRunTitle">
    <div className="first-run-copy">
      <h2 id="firstRunTitle">{title}</h2>
      <p>{body}</p>
      <div className="first-run-actions">
        {hostStudioAvailable&&<button className="primary-button first-run-package-action" onClick={onOpenPackage}><FileArchive size={16}/> Revisar paquete local <ArrowRight size={15}/></button>}
        <button className={hostStudioAvailable?'secondary-button':'primary-button'} disabled={!catalogReady} onClick={onExplore}><Gamepad2 size={17}/> {carried?'Ver mis juegos':'Explorar juegos'}</button>
      </div>
    </div>
    <button className="first-run-dismiss" title="No volver a mostrar" aria-label="Ocultar bienvenida" onClick={onDismiss}><X size={17}/></button>
  </section>;
}
