import {test} from 'node:test';import assert from 'node:assert/strict';
import {synchronize,editRecord} from '../web/sync.js';
const repo=records=>({records,async read(){return structuredClone(this.records)},async update(fn){fn(this.records)}});
test('conflicts keep the local text and remote revision, deletion does not erase an edit',async()=>{
 const id=crypto.randomUUID(),mutation=crypto.randomUUID();const store=repo({[id]:{id,text:'my edit',version:1,dirty:true,deleted:false,mutation}});
 await synchronize(store,{put:async()=>({conflict:true,note:{id,text:'',version:2,deleted:true}}),list:async()=>[{id,text:'',version:2,deleted:true}]});
 assert.equal(store.records[id].deleted,true);assert.ok(store.records[mutation].text.endsWith('my edit'));assert.equal(store.records[mutation].dirty,true);assert.ok(store.records[mutation].conflict);
});
test('typing during upload preserves new content while advancing accepted base revision',async()=>{
 const id=crypto.randomUUID();const store=repo({[id]:{id,text:'one',version:0,dirty:true,deleted:false,mutation:crypto.randomUUID()}});
 await synchronize(store,{put:async()=>{editRecord(store.records,id,'two');return {note:{id,text:'one',deleted:false,version:1}}},list:async()=>[{id,text:'one',deleted:false,version:1}]});
 assert.equal(store.records[id].text,'two');assert.equal(store.records[id].dirty,true);assert.equal(store.records[id].version,1);
});
test('lost response and offline failure retain pending state; retry does not duplicate notes',async()=>{
 const id=crypto.randomUUID();const store=repo({[id]:{id,text:'one',version:0,dirty:true,deleted:false,mutation:crypto.randomUUID()}});
 await assert.rejects(synchronize(store,{put:async()=>{throw Error('offline')},list:async()=>[]}));assert.equal(store.records[id].dirty,true);
 await synchronize(store,{put:async()=>({note:{id,text:'one',version:1,deleted:false}}),list:async()=>[{id,text:'one',version:1,deleted:false}]});assert.equal(Object.keys(store.records).length,1);assert.equal(store.records[id].dirty,false);
});
test('stale editor cannot borrow a newer shared version or erase another offline draft',()=>{
 const id=crypto.randomUUID(),baseline={id,text:'v1',version:1,mutation:'a',deleted:false};
 for(const newer of [{text:'other tab saved',version:2,mutation:'b'},{text:'other tab offline',version:1,mutation:'b'}]){
  const records={[id]:{...baseline,...newer,dirty:true}};
  const target=editRecord(records,id,'stale editor change',false,baseline);
  assert.notEqual(target,id);assert.equal(records[id].text,newer.text);assert.equal(records[target].text,'stale editor change');assert.equal(records[target].version,0);
 }
});
