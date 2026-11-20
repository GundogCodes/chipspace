'use strict';
const $ = s => document.querySelector(s);
const $$ = s => [...document.querySelectorAll(s)];
const el = (tag, cls, value) => { const n = document.createElement(tag); if (cls) n.className = cls; if (value !== undefined) n.textContent = value; return n; };
const gib = n => (n / 1073741824).toFixed(1);
const size = n => n >= 1073741824 ? `${gib(n)} GiB` : n >= 1048576 ? `${(n / 1048576).toFixed(1)} MiB` : `${Math.round(n / 1024).toLocaleString()} KiB`;
const cats = { development: 'Development', models: 'AI models', caches: 'Caches & logs', apps: 'Application data', system: 'System support', personal: 'Personal data' };
let token = location.hash.slice(1) || sessionStorage.getItem('chipspace-token') || '';
if (token) sessionStorage.setItem('chipspace-token', token);
history.replaceState(null, '', '/');
let state = null, selected = null, category = 'all', folder = null, limit = 12, descending = true, view = 'storage', lastKey = '', staleAfterCleanup = false;
let currentTicket = null, modalBusy = false, pollTimer, toastTimer, itemsByID = new Map(), children = new Map(), boardTiles = [], boardRemainder = [];

async function api(path, body) {
  const res = await fetch('/api/' + path, { method: body === undefined ? 'GET' : 'POST', headers: { Authorization: 'Bearer ' + token, ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) }, body: body === undefined ? undefined : JSON.stringify(body) });
  const data = await res.json(); if (!res.ok) throw new Error(data.error || 'The operation could not be completed.'); return data;
}
function notify(message) { $('#toast').textContent = message; $('#toast').classList.remove('hidden'); clearTimeout(toastTimer); toastTimer = setTimeout(() => $('#toast').classList.add('hidden'), 7000); }
function showNotice(message) { $('#notice').textContent = message; $('#notice').classList.toggle('hidden', !message); }
function busy() { return state && ['scanning', 'working'].includes(state.phase); }
function setView(next) {
  view = next; $$('.view').forEach(v => v.classList.toggle('hidden', v.id !== next + '-view'));
  $$('.nav').forEach(n => n.classList.toggle('active', n.dataset.view === next)); if (next === 'activity') renderActivity(); if (next === 'storage') requestAnimationFrame(renderBoard);
}
function rebuildIndex() {
  itemsByID = new Map(state.items.map(i => [i.id, i])); children = new Map();
  for (const i of state.items) { const p = i.parentId || ''; if (!children.has(p)) children.set(p, []); children.get(p).push(i); }
  for (const a of children.values()) a.sort((a,b) => b.bytes-a.bytes);
}
const splitPaths = new Set(['~/.cache', '~/.cache/huggingface', '~/.cache/huggingface/hub', '~/.ollama', '~/.npm', '~/Library/Developer/Xcode', '~/Library/Developer/CoreSimulator', '~/Library/Caches', '/Library', '/Library/Developer', '/System/Library/AssetsV2']);
function frontier(node, budget = node.bytes) {
  const kids = (children.get(node.id) || []).filter(x => x.bytes > 0);
  if (!kids.length || !splitPaths.has(node.path)) return [{ item: node, weight: budget, category: node.category }];
  const total = kids.reduce((a,b) => a+b.bytes,0); const scale = Math.min(1, node.bytes / Math.max(total,1));
  const relative = budget / Math.max(node.bytes,1);
  const parts = kids.flatMap(k => frontier(k, k.bytes*scale*relative));
  const residual = budget - parts.reduce((a,b) => a+b.weight,0);
  if (residual > 0.5) parts.push({ item: node, weight: residual, category: node.category, residual: true });
  return parts;
}
function getBoardTiles() {
  const all = (children.get('') || []).filter(i => i.bytes > 0).flatMap(i => frontier(i)).filter(i=>category==='all'||i.category===category).sort((a,b) => b.weight-a.weight);
  const total = all.reduce((a,b) => a+b.weight,0);
  const width = $('#chips').getBoundingClientRect().width;
  const maximum = width < 500 ? 6 : width < 700 ? 8 : 11;
  const top = all.filter((x,i) => i < maximum && x.weight / Math.max(total,1) > .012);
  const remaining = all.filter(x => !top.includes(x));
  boardRemainder = [...new Map(remaining.map(x=>[x.item.id,x.item])).values()];
  if (remaining.length) top.push({ item: { id: 'other', name: 'Smaller folders', bytes: remaining.reduce((a,b)=>a+b.weight,0) }, weight: remaining.reduce((a,b)=>a+b.weight,0), category: 'system', other: true });
  return top.sort((a,b) => b.weight-a.weight);
}
// Binary area partition: no minimum-width inflation or overlapping rectangles.
function partition(entries, x, y, w, h) {
  if (!entries.length) return [];
  if (entries.length === 1) return [{ ...entries[0], x,y,w,h }];
  const total = entries.reduce((a,b)=>a+b.weight,0); let cut=1, sum=entries[0].weight;
  while (cut < entries.length-1 && Math.abs(sum+entries[cut].weight-total/2) < Math.abs(sum-total/2)) sum += entries[cut++].weight;
  const r = sum / Math.max(total,1);
  return w >= h ? [...partition(entries.slice(0,cut),x,y,w*r,h),...partition(entries.slice(cut),x+w*r,y,w*(1-r),h)] : [...partition(entries.slice(0,cut),x,y,w,h*r),...partition(entries.slice(cut),x,y+h*r,w,h*(1-r))];
}
function renderBoard() {
  if (!state || view !== 'storage') return;
  const board = $('#chips'); const { width, height } = board.getBoundingClientRect(); if (!width || !height) return;
  board.replaceChildren(); boardTiles=getBoardTiles(); $('#empty-board').classList.toggle('hidden',boardTiles.length>0);
  $('#empty-board h3').textContent=state.items.length?'Nothing mapped here.':'Meet your storage.';
  $('#empty-board p').textContent=state.items.length?'No measured folders in this category. Try another category or review scan coverage.':'Start a scan to turn hidden folders into something you can see.';
  for (const t of partition(boardTiles,0,0,width,height)) {
    const b=el('button',`chip ${t.category}${selected===t.item.id?' selected':''}${t.w<150||t.h<100?' compact':''}${t.w<70||t.h<50?' tiny':''}`);
    Object.assign(b.style,{left:t.x+'px',top:t.y+'px',width:t.w+'px',height:t.h+'px'});
    const name = t.residual ? 'Other in '+t.item.name : t.item.name;
    b.append(el('small','',t.other?'OTHER MAPPED':(cats[t.category]||'Storage').toUpperCase()),el('strong','',name),el('em','',size(t.weight)));
    b.title=`${name} — ${size(t.weight)}${t.item.complete===false?' (partial scope)':''}`;
    b.setAttribute('aria-label',b.title); b.setAttribute('aria-pressed',String(selected===t.item.id));
    b.onclick=()=>{ if(t.other){folder='__other__';$('#search').value='';$('#reviewable').checked=false;limit=12;renderRows();$('#folder-rows').scrollIntoView({behavior:'smooth',block:'nearest'});}else select(t.item.id); };
    board.append(b);
  }
}
function renderFilters() { $$('.legend button').forEach(b=>b.classList.toggle('selected',b.dataset.category===category)); }
function select(id) { selected=id; renderInspector(); renderRows(); renderBoard(); if(innerWidth<781) $('#inspector').scrollIntoView({behavior:'smooth',block:'start'}); }
function explore(id) { folder=id;limit=12;$('#search').value='';category='all';$('#reviewable').checked=false;renderFilters();renderRows();$('#folder-rows').scrollIntoView({behavior:'smooth',block:'nearest'}); }
function renderRows() {
  if(!state) return;
  const query=$('#search').value.toLowerCase().trim(); let rows=folder==='__other__'?boardRemainder:folder?(children.get(folder)||[]):state.items;
  rows=rows.filter(i=>!i.removed&&(category==='all'||i.category===category)&&(!$('#reviewable').checked||i.action==='conditional')&&(!query||(i.name+' '+i.path).toLowerCase().includes(query)));
  rows=rows.sort((a,b)=>descending?b.bytes-a.bytes:a.bytes-b.bytes);
  const target=$('#folder-rows');target.replaceChildren();
  $('#folder-caption').textContent=folder?'Contents of the selected folder':`Folder measurements · nested rows overlap`;
  $('#root').classList.toggle('hidden',!folder);$('#breadcrumb').textContent=folder==='__other__'?'Smaller mapped folders':folder?(itemsByID.get(folder)?.path||''): `${rows.length.toLocaleString()} locations`;
  $('#sort').textContent=descending?'SIZE ↓':'SIZE ↑';
  for(const i of rows.slice(0,limit)) {
    const row=el('button','folder-row'+(selected===i.id?' selected':''));row.setAttribute('aria-label',`${i.name}, ${size(i.bytes)}, ${i.action==='conditional'?'review cleanup':'inspect only'}`);
    const name=el('span');const title=el('span','row-title');title.append(el('i','dot '+i.category),document.createTextNode(i.name));name.append(title,el('span','row-path',i.path));
    row.append(name,el('span','row-size',size(i.bytes)),el('span','handling '+i.action,i.action==='conditional'?'Review cleanup':!i.complete?'Partial · inspect':'Inspect only'));
    row.onclick=()=>select(i.id);target.append(row);
  }
  if(!rows.length) target.append(el('p','empty-message',state.items.length?'No folders match this view. Try another filter.':'Your first scan will fill in the folder index.'));
  $('#show-more').classList.toggle('hidden',rows.length<=limit);$('#show-more').textContent=`SHOW ${Math.min(30,Math.max(0,rows.length-limit))} MORE FOLDERS`;
}
function renderInspector() {
  const i=itemsByID.get(selected); if(!i)return;
  const root=$('#inspector-content'); root.replaceChildren(); const card=el('div','inspector-inner');
  card.append(el('div','kind',cats[i.category]||'Storage'),el('h3','',i.name));
  const count=el('div','inspect-size',gib(i.bytes));count.append(el('small','','GiB'));card.append(count,el('p','inspect-path',i.path));
  if(i.delta!==undefined&&i.delta!==0)card.append(el('p','subnote',`${i.delta>0?'+':'−'}${size(Math.abs(i.delta))} since the previous complete measurement.`));
  if(!i.complete)card.append(el('p','subnote','Partial scan scope. This is a lower bound; cleanup rechecks this specific folder.'));
  const section=(label,body)=>{const s=el('section','inspect-section');s.append(el('h4','',label),el('p','',body));return s;};
  card.append(section('WHAT LIVES HERE',i.explanation));
  const safety=el('div','safety '+i.action);
  safety.append(el('strong','',i.removed?'Already handled':i.action==='conditional'?'Removable, with conditions':'Manage with care'),el('p','',i.removed?'This item was removed from its original location. Rescan to update its size.':i.action==='conditional'?'Recognized optional data. Read the consequences before deciding.':'Direct deletion is disabled. This may contain app state, personal files, or system-managed data.'));card.append(safety);
  card.append(section('BEFORE YOU REMOVE IT',i.advice));
  const actions=el('div','inspect-actions');
  const add=(label,cls,handler)=>{const b=el('button',cls,label);b.onclick=handler;b.disabled=busy()||i.removed;actions.append(b);};
  if(i.action==='conditional'&&!i.removed){add('REVIEW & MOVE TO TRASH','primary',()=>review(i.id,'trash'));add('Permanently delete instead','danger-link',()=>review(i.id,'delete'));}
  if(i.path.includes('CoreSimulator')||i.path.includes('iOSSimulatorRuntime'))add('MANAGE SIMULATORS','primary',showSimulators);
  if((children.get(i.id)||[]).length)add('EXPLORE CONTENTS','secondary',()=>explore(i.id));
  add('SHOW IN FINDER','secondary',()=>api('reveal',{id:i.id}).catch(e=>notify(e.message)));
  card.append(actions,el('p','subnote','A size estimate is not a promise of space recovered. Nothing is removed without your confirmation.'));root.append(card);
}
function renderActivity(){const t=$('#activity-list');t.replaceChildren();for(const a of state?.activity||[]){const row=el('article','activity-entry');const body=el('div');body.append(el('h3','',a.label),el('p','',a.detail));const time=el('time','',new Date(a.date*1000).toLocaleString());row.append(time,body);t.append(row);}if(!t.children.length)t.append(el('p','empty-message','No activity yet. Your scan and cleanup history will appear here.'));}
function renderState(){
  const used=Math.max(0,state.total-state.free);$('#used').replaceChildren(document.createTextNode(gib(used)),el('small','','GiB'));$('#free').replaceChildren(document.createTextNode(gib(state.free)),el('small','','GiB'));
  $('#capacity-bar').style.width=(used/Math.max(state.total,1)*100)+'%';$('#capacity-note').textContent=`${gib(state.total)} GiB total · ${Math.round(used/Math.max(state.total,1)*100)}% occupied`;
  const mapped=(children.get('')||[]).reduce((a,b)=>a+b.bytes,0);$('#mapped').replaceChildren(document.createTextNode(state.items.length?gib(mapped):'—'),el('small','','GiB'));
  $('#mapped-note').textContent=state.items.length?`${state.items.length.toLocaleString()} locations · folder allocation`:'Run a scan to map your folders';
  $('#scan-date').textContent=state.date?`SCANNED ${new Date(state.date*1000).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'})}`:'AWAITING FIRST SCAN';
  $('#footer-machine').textContent=state.machine.toUpperCase();$('#connection').textContent='CONNECTED / LOCAL';$('#scan').disabled=busy();$('#scan-label').textContent=state.phase==='scanning'?'SCANNING…':state.phase==='working'?'WORKING…':state.items.length?'RESCAN DRIVE':'SCAN THIS MAC';
  $('#progress').classList.toggle('hidden',!busy());$('#progress-text').textContent=state.message;
  $('#coverage').classList.toggle('hidden',!state.errors);
  if(state.phase==='error')showNotice(state.message);
  else if(staleAfterCleanup)showNotice('Cleanup completed. The board still shows the previous scan. Rescan to measure what changed.');
  else showNotice('');
}
async function refresh(){
  clearTimeout(pollTimer);
  try{
    const next=await api('state');const priorPhase=state?.phase;const oldDate=state?.date;state=next;const key=String(state.date)+':'+state.items.filter(i=>i.removed).length;
    if(key!==lastKey){const previousPath=itemsByID.get(selected)?.path;lastKey=key;rebuildIndex();selected=state.items.find(i=>i.path===previousPath)?.id||getBoardTiles().find(t=>!t.other)?.item.id||null;folder=null;staleAfterCleanup=state.items.some(i=>i.removed)||state.activity.some(a=>a.date>state.date&&['Moved to Trash','Removed item','Cleanup needs attention'].includes(a.label));renderRows();renderBoard();renderInspector();}
    renderState();if(priorPhase!==state.phase)renderInspector();if(view==='activity')renderActivity();
  }catch(e){$('#connection').textContent='DISCONNECTED';showNotice(e.message);$('#scan').disabled=true;}
  pollTimer=setTimeout(refresh,busy()?1300:5000);
}
function openModal(title,kicker='REVIEW ITEM'){currentTicket=null;modalBusy=false;$('#modal-title').textContent=title;$('#modal-kicker').textContent=kicker;$('#modal-body').replaceChildren();if(!$('#modal').open)$('#modal').showModal();return $('#modal-body');}
function closeModal(){if(modalBusy)return;currentTicket=null;$('#modal').close();}
async function review(id,mode,kind='file'){
  const body=openModal('Checking this item…','CLEANUP / REVIEW');body.append(el('p','','Measuring this exact item and checking the cleanup policy.'));modalBusy=true;
  try{const prepared=await api('prepare',{id,mode,kind});modalBusy=false;currentTicket=prepared;renderConfirmation(prepared);}catch(e){modalBusy=false;$('#modal-title').textContent='This item needs a closer look.';body.replaceChildren(el('p','error-text',e.message));}
}
function renderConfirmation(t){
  $('#modal-title').textContent=t.name;const body=$('#modal-body');body.replaceChildren();body.append(el('div','confirm-size',size(t.bytes)),el('p','',t.consequence));
  const check=el('label','confirm-check');const checkbox=el('input');checkbox.type='checkbox';checkbox.id='closed-app';check.append(checkbox,document.createTextNode('I have closed the owning app, builds, tests, and model servers, and understand what will be removed.'));body.append(check);
  const label=el('label','confirm-label',`Type ${t.phrase} to confirm this one item.`);const input=el('input','confirm-input');input.id='confirmation';input.autocomplete='off';input.spellcheck=false;input.placeholder=t.phrase;label.append(input);body.append(label);
  const error=el('p','error-text');body.append(error);const buttons=el('div','confirm-actions');const cancel=el('button','secondary','CANCEL');cancel.onclick=closeModal;const confirm=el('button','primary',t.mode==='trash'?'MOVE TO TRASH':'DELETE PERMANENTLY');confirm.id='confirm-action';confirm.disabled=true;
  const validate=()=>{confirm.disabled=!checkbox.checked||input.value!==t.phrase;};checkbox.onchange=validate;input.oninput=validate;
  confirm.onclick=async()=>{if(confirm.disabled)return;modalBusy=true;confirm.disabled=true;cancel.disabled=true;input.disabled=true;checkbox.disabled=true;confirm.textContent='WORKING…';try{const result=await api('execute',{ticket:t.ticket,confirmation:input.value,closed:checkbox.checked});modalBusy=false;staleAfterCleanup=true;closeModal();notify(result.message);await refresh();}catch(e){modalBusy=false;error.textContent=e.message;cancel.disabled=false;confirm.textContent='REVIEW AGAIN';confirm.disabled=false;confirm.onclick=closeModal;}};
  buttons.append(cancel,confirm);body.append(buttons);input.focus();
}
async function showSimulators(){const body=openModal('Simulator workbench','APPLE XCODE / MANAGED CLEANUP');body.append(el('p','','Reading Apple’s live simulator inventory…'));try{const data=await api('simulators');let kind='runtime';const draw=()=>{body.replaceChildren();body.append(el('p','',kind==='runtime'?'Runtime packages are simulator operating systems. Remove only OS builds you no longer test.':'Devices contain test apps and their local data. They are separate from runtime packages.'));const tabs=el('div','sim-tabs');for(const k of ['runtime','device']){const b=el('button',kind===k?'active':'',k==='runtime'?'OS runtimes':'Test devices');b.onclick=()=>{kind=k;draw();};tabs.append(b);}body.append(tabs);const matches=data.items.filter(i=>i.kind===kind);for(const s of matches){const row=el('div','sim-row');const text=el('div');text.append(el('strong','',s.name),el('small','',s.detail),el('small','',size(s.bytes)));const b=el('button','secondary',s.enabled?'REVIEW':'UNAVAILABLE');b.disabled=!s.enabled;b.onclick=()=>review(s.id,'delete',s.kind);row.append(text,b);body.append(row);}if(!matches.length)body.append(el('p','','No installed items in this group.'));};draw();}catch(e){body.replaceChildren(el('p','error-text',e.message));}}
function coverage(){const body=openModal('Scan coverage','READ ACCESS / DIAGNOSTICS');body.append(el('p','','The scan includes common storage locations for this user. These scopes were partial, blocked, or timed out. To improve coverage, add Chipspace in System Settings → Privacy & Security → Full Disk Access, quit the app, and reopen it.'));body.append(el('pre','coverage-text',state?.errors||'No reported scan errors.'));}

$('#scan').onclick=async()=>{try{$('#scan').disabled=true;await api('scan',{});staleAfterCleanup=false;await refresh();}catch(e){notify(e.message);await refresh();}};
$$('.nav').forEach(b=>b.onclick=()=>setView(b.dataset.view));$('.brand').onclick=e=>{e.preventDefault();setView('storage');};$('#help').onclick=()=>setView('about');
$$('.legend button').forEach(b=>b.onclick=()=>{category=b.dataset.category;folder=null;limit=12;renderFilters();renderRows();renderBoard();});
$('#search').oninput=()=>{limit=12;renderRows();};$('#reviewable').onchange=()=>{limit=12;renderRows();};$('#sort').onclick=()=>{descending=!descending;renderRows();};$('#show-more').onclick=()=>{limit+=30;renderRows();};$('#root').onclick=()=>{folder=null;limit=12;renderRows();};
$('#coverage-detail').onclick=coverage;$('#close-modal').onclick=closeModal;$('#modal').addEventListener('cancel',e=>{if(modalBusy)e.preventDefault();else currentTicket=null;});
new ResizeObserver(()=>requestAnimationFrame(renderBoard)).observe($('#chips'));
refresh();
