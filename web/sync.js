export function editRecord(records,id,text,deleted=false,baseline=null){
 const previous=records[id];
 if(baseline&&previous&&(previous.text!==baseline.text||previous.deleted!==baseline.deleted)){
  // Another tab may have changed shared storage while this editor still displays old text.
  if(deleted)return id; // Do not delete that unseen edit.
  id=crypto.randomUUID();records[id]={id,text,deleted:false,version:0,dirty:true,mutation:crypto.randomUUID(),updated:Date.now(),conflict:true};return id;
 }
 records[id]={...previous,id,text,deleted,version:previous?.version||0,dirty:true,mutation:crypto.randomUUID(),updated:Date.now()};return id;
}
// Reads and writes are transactional so another browser tab cannot overwrite queued changes.
export async function synchronize(repo,api){
 const initial=await repo.read();let conflicts=0;
 for(const snapshot of Object.values(initial).filter(n=>n.dirty)){
  const result=await api.put(snapshot);
  await repo.update(records=>{
   const local=records[snapshot.id];if(!local)return;
   if(result.conflict){
    if(local.mutation!==snapshot.mutation)return;
    if(!snapshot.deleted){
     // Stable mutation ID makes retry after a lost response/create crash idempotent.
     const id=snapshot.mutation;
     records[id]={id,text:'# 冲突副本 / Conflict copy\n\n'+snapshot.text,version:0,deleted:false,dirty:true,mutation:crypto.randomUUID(),updated:Date.now(),conflict:true};conflicts++;
    }
    // A stale delete must never erase an intervening remote edit.
    if(result.note)records[snapshot.id]={...result.note,dirty:false};
    else delete records[snapshot.id];
   }else if(local.mutation===snapshot.mutation)records[snapshot.id]={...result.note,dirty:false,conflict:local.conflict};
   else records[snapshot.id]={...local,version:result.note.version};
  });
 }
 const incoming=await api.list();
 await repo.update(records=>{for(const n of incoming){const local=records[n.id];if(!local||(!local.dirty&&n.version>=local.version))records[n.id]={...n,dirty:false,conflict:local?.conflict};}});
 return {conflicts,pending:Object.values(await repo.read()).filter(n=>n.dirty).length};
}
export function openRepository(account){
 const ready=new Promise((resolve,reject)=>{const request=indexedDB.open('powvy-note',1);request.onupgradeneeded=()=>request.result.createObjectStore('accounts');request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);});
 async function transaction(write,fn){const db=await ready;return new Promise((resolve,reject)=>{const tx=db.transaction('accounts',write?'readwrite':'readonly'),store=tx.objectStore('accounts');let result;const get=store.get(account);get.onsuccess=()=>{const records=get.result||{};try{if(write){fn(records);store.put(records,account);}result=records;}catch(e){tx.abort();reject(e)}};tx.oncomplete=()=>resolve(result);tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error||Error('本机保存失败'));});}
 return {read:()=>transaction(false),update:fn=>transaction(true,fn)};
}
