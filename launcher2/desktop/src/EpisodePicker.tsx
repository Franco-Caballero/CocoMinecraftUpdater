import {Check,LoaderCircle,Play,RotateCcw} from 'lucide-react';
import {formatRemaining,progressFor,resumePoint,watchedFraction,type MediaProgress} from './media-progress';

export type MediaEpisode={id:string;title:string};

/** «Temporada 5 - Episodio 1 - Parte 1» reads as a season heading plus «Episodio 1 · Parte 1». */
export function episodeLabels(episodes:readonly MediaEpisode[]){
  const parts=episodes.map(episode=>episode.title.split(' - '));
  const shared=parts.length>1&&parts.every(part=>part.length>1&&part[0]===parts[0][0])?parts[0][0]:'';
  return {season:shared,labels:parts.map(part=>(shared?part.slice(1):part).join(' · '))};
}

/** What the main button plays: the episode in progress, else the one after the last watched. */
export function mediaPlan(id:string,episodes:readonly MediaEpisode[],movie:boolean){
  const progress=episodes.map(episode=>progressFor(id,episode.id));
  let index=progress.findIndex(entry=>resumePoint(entry)!==null);
  if(index<0){
    const lastWatched=progress.map(entry=>Boolean(entry?.finished)).lastIndexOf(true);
    index=lastWatched>=0&&lastWatched<episodes.length-1?lastWatched+1:0;
  }
  const episode=episodes[index];
  const current=progress[index]??null;
  const resume=resumePoint(current);
  const number=index+1;
  const label=movie
    ?(resume!==null?'Continuar':current?.finished?'Ver de nuevo':'Ver película')
    :(resume!==null?`Continuar E${number}`:`Ver episodio ${number}`);
  return {episode,resume,progress:current,label,remaining:resume!==null&&current?current.duration-resume:0};
}

type Props={id:string;episodes:readonly MediaEpisode[];movie:boolean;loadingId:string;disabled:boolean;
  onPlay:(episode:MediaEpisode,fromStart:boolean)=>void};

/** Movies get a «keep watching» card when there is something to keep; series get their episode
 * list, with what was watched, what is half way and what comes next. */
export function EpisodePicker({id,episodes,movie,loadingId,disabled,onPlay}:Props){
  const plan=mediaPlan(id,episodes,movie);
  if(movie){
    if(plan.resume===null||!plan.episode)return null;
    return <section className="coco-resume" aria-label="Seguir viendo">
      <div className="coco-resume-head"><span className="coco-media-eyebrow">Seguir viendo</span><small>Quedan {formatRemaining(plan.remaining)}</small></div>
      <i className="coco-resume-bar"><b style={{width:`${watchedFraction(plan.progress)*100}%`}}/></i>
      <button type="button" className="coco-resume-restart" disabled={disabled} onClick={()=>onPlay(plan.episode,true)}><RotateCcw size={14}/> Desde el inicio</button>
    </section>;
  }
  const {season,labels}=episodeLabels(episodes);
  return <section className="coco-episodes" aria-label="Episodios">
    <header className="coco-episodes-head"><span className="coco-media-eyebrow">{season||'Episodios'}</span><small>{episodes.length} {episodes.length===1?'episodio':'episodios'}</small></header>
    <ol>{episodes.map((episode,index)=>{
      const progress:MediaProgress|null=progressFor(id,episode.id);
      const resume=resumePoint(progress);
      const loading=loadingId===episode.id;
      const isNext=plan.episode?.id===episode.id;
      const status=loading?'Abriendo…':progress?.finished?'Visto':resume!==null&&progress?`Quedan ${formatRemaining(progress.duration-resume)}`:isNext?'Siguiente':'';
      return <li key={episode.id} style={{['--i' as string]:index}}>
        <button type="button" className={`coco-episode ${isNext?'is-next':''} ${progress?.finished?'is-watched':''} ${loading?'is-loading':''}`}
          disabled={disabled} aria-label={`Reproducir ${labels[index]}${status?`, ${status}`:''}`} onClick={()=>onPlay(episode,false)}>
          <span className="coco-episode-num" aria-hidden="true">{String(index+1).padStart(2,'0')}</span>
          <span className="coco-episode-copy"><strong>{labels[index]}</strong>{status&&<small>{status}</small>}</span>
          <span className="coco-episode-go" aria-hidden="true">{loading?<LoaderCircle className="spin" size={16}/>:progress?.finished?<Check size={16}/>:<Play size={15} fill="currentColor"/>}</span>
          {progress&&!progress.finished&&<i className="coco-episode-progress" style={{width:`${watchedFraction(progress)*100}%`}}/>}
        </button>
      </li>;
    })}</ol>
  </section>;
}
