/* Coco Launcher 2: a self-contained UI study. No engine integration or system actions. */
(() => {
  'use strict';

  const paths = {
    home: '<path d="m3 10 9-7 9 7v10a1 1 0 0 1-1 1h-5v-7H9v7H4a1 1 0 0 1-1-1z"/>',
    grid: '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
    activity: '<path d="M3 12h4l3-8 4 16 3-8h4"/>',
    heart: '<path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1.1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8Z"/>',
    settings: '<path d="M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8Z"/><path d="M19.5 12a7.5 7.5 0 0 0-.1-1.3l2-1.5-2-3.5-2.3.9a7 7 0 0 0-2.2-1.3L14.5 3h-4l-.4 2.3a7 7 0 0 0-2.2 1.3l-2.3-.9-2 3.5 2 1.5a8 8 0 0 0 0 2.6l-2 1.5 2 3.5 2.3-.9a7 7 0 0 0 2.2 1.3l.4 2.3h4l.4-2.3a7 7 0 0 0 2.2-1.3l2.3.9 2-3.5-2-1.5c.1-.4.1-.8.1-1.3Z"/>',
    search: '<circle cx="10.8" cy="10.8" r="7.1"/><path d="m16 16 5 5"/>',
    chevronDown: '<path d="m6 9 6 6 6-6"/>',
    sparkles: '<path d="m12 3 1.9 6.1L20 11l-6.1 1.9L12 19l-1.9-6.1L4 11l6.1-1.9L12 3ZM20 18l.6 1.4L22 20l-1.4.6L20 22l-.6-1.4L18 20l1.4-.6L20 18Z"/>',
    flask: '<path d="M9 3h6M10 3v7l-5.8 8.6A2 2 0 0 0 5.9 22h12.2a2 2 0 0 0 1.7-3.4L14 10V3M7.5 16h9"/>',
    x: '<path d="M18 6 6 18M6 6l12 12"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5m0-8h.01"/>',
    play: '<path d="m8 5 11 7-11 7z"/>',
    arrowRight: '<path d="M4 12h16m-7-7 7 7-7 7"/>',
    arrowUpRight: '<path d="M7 17 17 7M8 7h9v9"/>',
    box: '<path d="m12 2 9 5-9 5-9-5 9-5ZM3 7v10l9 5 9-5V7M12 12v10"/>',
    layers: '<rect x="3" y="3" width="18" height="6" rx="2"/><rect x="3" y="11" width="18" height="10" rx="2"/>',
    film: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 4v16M17 4v16M3 9h4m-4 6h4m10-6h4m-4 6h4"/>',
    monitor: '<rect x="3" y="4" width="18" height="14" rx="2"/><path d="M8 22h8m-4-4v4"/>',
    check: '<path d="m5 12 4 4L19 6"/>',
    pause: '<path d="M9 5v14M15 5v14"/>',
    refresh: '<path d="M20 11a8 8 0 0 0-14-5L3 9m0-6v6h6M4 13a8 8 0 0 0 14 5l3-3m0 6v-6h-6"/>',
  };
  const icon = name => `<svg aria-hidden="true" viewBox="0 0 24 24">${paths[({ 'chevron-down':'chevronDown', 'arrow-right':'arrowRight', 'arrow-up-right':'arrowUpRight' })[name] || name] || paths.info}</svg>`;
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const experiences = Array.isArray(window.COCO_EXPERIENCES) ? window.COCO_EXPERIENCES.filter(x => x && x.id && x.name) : [];
  const byId = new Map(experiences.map(x => [x.id, x]));
  const featured = ['cobbleverse', 'into-the-backrooms', 'big-walk'].map(id => byId.get(id)).filter(Boolean);
  const category = x => x.workflow === 'coco-media' ? 'media' : x.workflow === 'coco-standalone' ? 'standalone' : 'minecraft';
  const categoryLabel = x => category(x) === 'media' ? 'Cine y series' : category(x) === 'standalone' ? 'Juego cooperativo' : 'Minecraft';
  const imageUrl = x => `../../${encodeURI(x.image || 'assets/experiences/coco-original.jpg')}`;
  const meta = x => category(x) === 'minecraft' ? [x.minecraftVersion, x.loader].filter(Boolean).join(' · ') || 'Minecraft' : category(x) === 'media' ? 'Biblioteca audiovisual' : 'Experiencia independiente';
  const count = type => experiences.filter(x => category(x) === type).length;
  const storageKey = 'coco2-ui-prototype-favorites';
  let stored = [];
  try { stored = JSON.parse(localStorage.getItem(storageKey) || '[]'); } catch {}
  const state = {view:'home',filter:'all',search:'',sort:'catalog',hero:0,favorites:new Set(Array.isArray(stored)?stored:[]),motion:true,detail:null,demo:false};
  const page = document.getElementById('pageContent');
  const drawer = document.getElementById('detailDrawer');
  const overlay = document.getElementById('overlay');
  const search = document.getElementById('search');

  function hydrateIcons(root=document){root.querySelectorAll('[data-icon]').forEach(el => { el.innerHTML = icon(el.dataset.icon); });}
  function setView(view){
    if(!['home','library','favorites','activity','settings'].includes(view)) return;
    state.view=view;state.filter='all';state.search=view==='library'||view==='favorites'?state.search:'';
    if(view!=='library'&&view!=='favorites')search.value='';
    document.getElementById('breadcrumbTitle').textContent={home:'Inicio',library:'Biblioteca',favorites:'Favoritos',activity:'Actividad',settings:'Preferencias'}[view];
    document.querySelectorAll('[data-view]').forEach(el=>{const active=el.dataset.view===view;el.classList.toggle('active',active);if(active)el.setAttribute('aria-current','page');else el.removeAttribute('aria-current');});
    closeDetail();render();document.getElementById('mainContent').scrollTop=0;window.scrollTo({top:0,behavior:'instant'});
  }
  function filtered(base=experiences){
    const term=state.search.trim().toLocaleLowerCase('es').normalize('NFD').replace(/[\u0300-\u036f]/g,'');
    let items=base.filter(x=>state.filter==='all'||category(x)===state.filter).filter(x=>!term||`${x.name} ${x.description} ${meta(x)}`.toLocaleLowerCase('es').normalize('NFD').replace(/[\u0300-\u036f]/g,'').includes(term));
    if(state.sort==='alpha')items=items.sort((a,b)=>a.name.localeCompare(b.name,'es'));
    if(state.sort==='type')items=items.sort((a,b)=>category(a).localeCompare(category(b)));
    return items;
  }
  function card(x,index){
    const fav=state.favorites.has(x.id);
    return `<article class="experience-card" style="--index:${Math.min(index,15)}">
      <button class="card-image-button" data-detail="${escape(x.id)}" aria-label="Ver ${escape(x.name)}"><img src="${escape(imageUrl(x))}" alt="Portada de ${escape(x.name)}" loading="${index>5?'lazy':'eager'}"><span class="card-type">${escape(categoryLabel(x))}</span></button>
      <div class="card-body"><div class="card-title" title="${escape(x.name)}">${escape(x.name)}</div><div class="card-meta">${escape(meta(x))}</div><div class="card-actions"><button class="card-open" data-detail="${escape(x.id)}">Explorar experiencia ${icon('arrowUpRight')}</button><button class="favorite-button ${fav?'active':''}" data-favorite="${escape(x.id)}" aria-label="${fav?'Quitar de':'Agregar a'} favoritos" aria-pressed="${fav}">${icon('heart')}</button></div></div>
    </article>`;
  }
  function cards(items){return items.length?`<div class="experience-grid">${items.map(card).join('')}</div>`:`<div class="experience-grid"><div class="empty">${icon('search')}<strong>No encontramos experiencias</strong><p>Prueba otra búsqueda o cambia el filtro.</p></div></div>`;}
  function filters(){return `<div class="filter-row" aria-label="Filtrar experiencias">${[['all','Todas'],['minecraft','Minecraft'],['standalone','Juegos'],['media','Cine y series']].map(([key,label])=>`<button class="filter-button ${state.filter===key?'active':''}" data-filter="${key}" aria-pressed="${state.filter===key}">${label}</button>`).join('')}<select class="filter-sort" id="sortSelect" aria-label="Ordenar experiencias"><option value="catalog" ${state.sort==='catalog'?'selected':''}>Orden del catálogo</option><option value="alpha" ${state.sort==='alpha'?'selected':''}>Nombre A–Z</option><option value="type" ${state.sort==='type'?'selected':''}>Tipo de experiencia</option></select></div>`;}
  function hero(){
    const x=featured[state.hero % featured.length];if(!x)return '';
    return `<section class="hero" aria-label="Experiencia destacada"><img class="hero-image" src="${escape(imageUrl(x))}" alt="" fetchpriority="high"><div class="hero-grain"></div><div class="hero-content"><span class="hero-chip">${icon('sparkles')} SELECCIÓN COCO</span><h1>${escape(x.name)}</h1><p>${escape(x.description || 'Descubre una nueva aventura con tu grupo.')}</p><div class="hero-buttons"><button class="primary-button" data-detail="${escape(x.id)}">${icon('arrowUpRight')} Explorar experiencia</button><button class="secondary-button" data-view="library">Ver biblioteca ${icon('arrowRight')}</button></div></div><div class="hero-dots" aria-label="Elegir destacada">${featured.map((f,i)=>`<button data-hero="${i}" class="${i===state.hero?'active':''}" aria-label="Destacar ${escape(f.name)}" aria-pressed="${i===state.hero}"></button>`).join('')}</div></section>`;
  }
  function renderHome(){
    const homeItems=filtered();
    return `<div class="eyebrow" style="margin:6px 0 14px">TU HUB DE EXPERIENCIAS</div>${hero()}<div class="summary-strip"><div class="summary-item"><span class="summary-icon">${icon('layers')}</span><span><strong>${experiences.length}</strong><small>Experiencias en catálogo</small></span></div><div class="summary-item"><span class="summary-icon">${icon('box')}</span><span><strong>${count('minecraft')}</strong><small>Mundos de Minecraft</small></span></div><div class="summary-item"><span class="summary-icon">${icon('monitor')}</span><span><strong>${count('standalone')}</strong><small>Juegos independientes</small></span></div><div class="summary-item"><span class="summary-icon">${icon('film')}</span><span><strong>${count('media')}</strong><small>Cine y series</small></span></div></div><section><div class="section-head"><div><span class="eyebrow">EXPLORA Y DESCUBRE</span><h2>Experiencias para compartir</h2><p class="subhead">Carátulas reales del catálogo actual.</p></div><button class="link-button" data-view="library">Toda la biblioteca ${icon('arrowRight')}</button></div>${cards(homeItems.slice(0,8))}</section>`;
  }
  function renderLibrary(favorites=false){const items=filtered(favorites?experiences.filter(x=>state.favorites.has(x.id)):experiences);return `<div class="simple-page"><span class="eyebrow">${favorites?'TU COLECCIÓN PERSONAL':'EL UNIVERSO COCO'}</span><h1>${favorites?'Tus favoritos':'Todas las experiencias'}</h1><p class="welcome-copy">${favorites?'Guarda las experiencias que más te interesan. Esta preferencia es solo local y pertenece a la maqueta.':'Un mismo lugar para los mundos de Minecraft, juegos cooperativos, películas y series. Cada experiencia conservará su instalación y configuración independientes.'}</p>${filters()}${cards(items)}</div>`;}
  function renderActivity(){return `<div class="simple-page"><span class="eyebrow">ESTADOS DEL FUTURO LAUNCHER</span><h1>Actividad</h1><p class="welcome-copy">Un vistazo al lugar donde aparecerán el progreso de descargas, reparaciones y sesiones reales. Los eventos de abajo son ejemplos estáticos del diseño, no acciones registradas.</p><div class="activity-panel"><div class="activity-row"><span class="summary-icon">${icon('box')}</span><span><strong>Instalación y verificación</strong><p>Progreso por archivos, reanudación y verificación de integridad.</p></span><span class="activity-tag">DISEÑO</span></div><div class="activity-row"><span class="summary-icon">${icon('activity')}</span><span><strong>Conectividad y sesiones</strong><p>Estado real de la sesión del anfitrión y la red, actualizado por el servicio local.</p></span><span class="activity-tag">DISEÑO</span></div><div class="activity-row"><span class="summary-icon">${icon('refresh')}</span><span><strong>Actualizaciones</strong><p>Descargas verificadas, recuperación automática y reinicio seguro.</p></span><span class="activity-tag">DISEÑO</span></div></div></div>`;}
  function renderSettings(){return `<div class="simple-page"><span class="eyebrow">PERSONALIZA TU ESPACIO</span><h1>Preferencias</h1><p class="welcome-copy">Una muestra del estilo que podrían tener los ajustes. Solo el interruptor de animaciones funciona en esta vista previa; los ajustes de juego requieren una integración posterior.</p><div class="settings-grid"><div class="settings-card"><h3>Movimiento e interacciones</h3><p>Transiciones entre pantallas, aparición de tarjetas y microanimaciones al interactuar.</p><button class="toggle-button" id="settingsMotion">${icon(state.motion?'check':'pause')} Animaciones ${state.motion?'activadas':'desactivadas'}</button></div><div class="settings-card"><h3>Identidad local</h3><p>Nombre e imagen de tu jugador. Coco Launcher 2 conservará la identidad offline estable.</p><button class="toggle-button" disabled>${icon('info')} Pendiente de conexión al motor</button></div><div class="settings-card"><h3>Instalaciones</h3><p>Cada experiencia administrada mantiene sus archivos, mods y partidas en su carpeta propia.</p><button class="toggle-button" disabled>${icon('box')} Administrar instancias</button></div><div class="settings-card"><h3>Rendimiento</h3><p>Indicadores de preparación, consumo, descargas, diagnósticos y recuperación.</p><button class="toggle-button" disabled>${icon('activity')} Diagnóstico del sistema</button></div></div></div>`;}
  function render(){
    const content = state.view==='home'?renderHome():state.view==='library'?renderLibrary():state.view==='favorites'?renderLibrary(true):state.view==='activity'?renderActivity():renderSettings();
    page.innerHTML=content;page.style.animation='none';void page.offsetWidth;page.style.animation='';
    document.getElementById('totalCount').textContent=experiences.length;
  }
  function openDetail(id){
    const x=byId.get(id);if(!x)return;
    state.detail=id;state.demo=false;
    drawer.innerHTML=`<div class="drawer-hero"><img src="${escape(imageUrl(x))}" alt="Portada de ${escape(x.name)}"><button class="drawer-close" data-close aria-label="Cerrar detalles">${icon('x')}</button></div><div class="drawer-copy"><div class="eyebrow">${escape(categoryLabel(x))}</div><h2>${escape(x.name)}</h2><p>${escape(x.description || 'Una experiencia en la biblioteca de Coco.')}</p><div class="drawer-chips"><span>${escape(meta(x))}</span><span>${escape(x.workflow)}</span><span>Instalación aislada</span></div><div class="drawer-actions"><button class="primary-button" data-demo="${escape(id)}">${icon('play')} Mostrar instalación (demo)</button><button class="secondary-button" data-favorite="${escape(id)}">${icon('heart')}</button></div><div id="demoSlot"></div><p class="drawer-note">Prototipo visual. Este botón no descarga archivos, no inicia juegos y no modifica tu instalación.</p></div>`;
    drawer.hidden=false;overlay.hidden=false;document.body.style.overflow='hidden';drawer.querySelector('[data-close]').focus();
  }
  function closeDetail(){drawer.hidden=true;overlay.hidden=true;drawer.innerHTML='';document.body.style.overflow='';state.detail=null;state.demo=false;}
  function showDemo(){const slot=document.getElementById('demoSlot');if(!slot)return;slot.innerHTML=`<div class="demo-progress"><strong>Vista de instalación · ejemplo animado</strong><p>Descargando y verificando archivos… Los porcentajes son ilustrativos.</p><div class="progress-track"><div class="progress-fill"></div></div></div>`;state.demo=true;}
  function saveFavorites(){try{localStorage.setItem(storageKey,JSON.stringify([...state.favorites]));}catch{}}
  function toggleFavorite(id){if(!byId.has(id))return;state.favorites.has(id)?state.favorites.delete(id):state.favorites.add(id);saveFavorites();render();if(state.detail){const current=state.detail;openDetail(current);}else notify(state.favorites.has(id)?'Añadido a favoritos':'Quitado de favoritos');}
  let toastTimer;
  function notify(message){const toast=document.getElementById('toast');toast.textContent=message;toast.classList.add('visible');clearTimeout(toastTimer);toastTimer=setTimeout(()=>toast.classList.remove('visible'),2300);}
  function setMotion(value){state.motion=!!value;document.body.dataset.motion=state.motion?'on':'off';if(state.view==='settings')render();notify(`Animaciones ${state.motion?'activadas':'desactivadas'}`);}
  document.addEventListener('click',ev=>{
    const target=ev.target.closest('button');if(!target)return;
    if(target.hasAttribute('data-close')){closeDetail();return;}
    if(target.dataset.view){setView(target.dataset.view);return;}
    if(target.dataset.detail){openDetail(target.dataset.detail);return;}
    if(target.dataset.favorite){toggleFavorite(target.dataset.favorite);return;}
    if(target.dataset.filter){state.filter=target.dataset.filter;render();return;}
    if(target.dataset.hero!==undefined){state.hero=Number(target.dataset.hero)||0;render();return;}
    if(target.dataset.demo){showDemo();return;}
    if(target.id==='motionButton'||target.id==='settingsMotion'){setMotion(!state.motion);return;}
    if(target.id==='dismissNotice'){document.querySelector('.notice').hidden=true;return;}
  });
  document.getElementById('sortSelect')?.addEventListener('change',()=>{});
  document.addEventListener('change',ev=>{if(ev.target.id==='sortSelect'){state.sort=ev.target.value;render();}});
  search.addEventListener('input',()=>{state.search=search.value;if(state.search&&state.view!=='library'&&state.view!=='favorites'){setView('library');state.search=search.value;}render();});
  overlay.addEventListener('click',closeDetail);
  window.addEventListener('keydown',ev=>{
    if(ev.key==='Escape'&&!drawer.hidden){closeDetail();return;}
    if((ev.ctrlKey||ev.metaKey)&&ev.key.toLowerCase()==='k'){ev.preventDefault();search.focus();search.select();}
  });
  hydrateIcons();render();
})();
