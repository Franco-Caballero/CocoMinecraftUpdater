/** Honest per-PHASE progress. Rust reports counters for individual download,
 * extraction and verification stages; they are not a single overall 0–100%.
 * Never turn a completed download into a completed installation. */
export type NativeStageName='obtener'|'extraer'|'verificar'|'aplicar'|'restaurar';
export type NativeStageView={
  steps:readonly {id:NativeStageName;label:string;state:'done'|'current'|'future'}[];
  currentLabel:string;isComplete:boolean;stageIndex:number;stageCount:number;
};
const ordinary:readonly {id:NativeStageName;label:string}[]=[
  {id:'obtener',label:'Descargar'},{id:'extraer',label:'Extraer'},
  {id:'verificar',label:'Verificar'},{id:'aplicar',label:'Aplicar'},
];

export function nativeStageView(phase:string):NativeStageView|null{
  if(typeof phase!=='string'||!phase)return null;
  if(phase==='cancelled'||phase==='failed')return null;
  const restoring=/(?:recover|rollback|rolling-back|restor)/i.test(phase);
  const recovered=/(?:-recovered|recovery-complete)$/.test(phase);
  if(restoring||recovered){
    return {steps:[{id:'restaurar',label:'Restaurar',state:recovered?'done':'current'}],
      currentLabel:recovered?'Recuperación verificada':'Recuperando archivos',
      isComplete:recovered,stageIndex:1,stageCount:1};
  }
  let stage=-1;
  const prepared=phase==='repair-prepared';
  const completed=phase==='completed'||phase==='complete';
  if(completed)stage=ordinary.length;
  else if(prepared)stage=2;
  else if(phase.endsWith('downloading'))stage=0;
  else if(phase.endsWith('extracting'))stage=1;
  else if(phase.endsWith('verifying'))stage=2;
  else if(phase.endsWith('committing')||phase.endsWith('installing'))stage=3;
  if(stage<0)return null;
  const currentLabel=prepared?'Archivos preparados, sin aplicar cambios':
    completed?'Operación confirmada':`${ordinary[Math.min(stage,ordinary.length-1)].label} · fase ${stage+1} de ${ordinary.length}`;
  return {steps:ordinary.map((step,index)=>({...step,
    state:completed||index<stage?'done':index===stage?'current':'future'})),
    currentLabel,isComplete:completed,stageIndex:Math.min(stage+1,ordinary.length),stageCount:ordinary.length};
}
