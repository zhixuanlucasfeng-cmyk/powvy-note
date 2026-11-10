import {test} from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFileSync} from 'node:fs';
import worker from '../cloud/worker.js';
function fixture(){const db=new DatabaseSync(':memory:');db.exec(readFileSync(new URL('../cloud/schema.sql',import.meta.url),'utf8'));
 const DB={prepare(sql){return {bind(...args){return {
  async first(){return db.prepare(sql).get(...args)||null},
  async all(){return {results:db.prepare(sql).all(...args)}},
  async run(){return db.prepare(sql).run(...args)}
 }}}}};
 const env={SETUP_KEY:'test-setup-key',DB,ASSETS:{fetch:()=>new Response('asset')}};
 const api=async(path,body,token='',headers={})=>{const r=await worker.fetch(new Request('https://note.example/api/'+path,{method:body?'POST':'GET',headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{}),...headers},...(body?{body:JSON.stringify(body)}:{})}),env);return {status:r.status,data:await r.json(),cookie:r.headers.get('set-cookie')}};
 const put=async(id,body,token)=>{const r=await worker.fetch(new Request('https://note.example/api/notes/'+id,{method:'PUT',headers:{'Content-Type':'application/json',Authorization:'Bearer '+token},body:JSON.stringify(body)}),env);return {status:r.status,data:await r.json()}};return{db,env,api,put};}
test('setup/login/session, CAS and recovery protect notes',async()=>{
 const {api,put,db}=fixture();const password='correct horse battery';const recoveryCode='a'.repeat(48);
 assert.equal((await api('setup',{username:'lucas',password,recoveryCode})).status,403);
 assert.equal((await api('setup',{username:'lucas',password,recoveryCode},{},{'X-Setup-Key':'test-setup-key',Origin:'https://evil.example'})).status,403);
 const setup=await api('setup',{username:'lucas',password,recoveryCode,native:true},'',{'X-Setup-Key':'test-setup-key'});assert.equal(setup.status,200);const token=setup.data.token;assert.ok(token);
 assert.equal((await api('setup',{username:'other',password,recoveryCode},'',{'X-Setup-Key':'test-setup-key'})).status,409);
 assert.equal((await api('login',{username:'lucas',password:'incorrect',native:true})).status,401);
 const web=await api('login',{username:'lucas',password,native:true},'',{Origin:'https://note.example'});assert.equal(web.status,200);assert.ok(web.cookie.includes('HttpOnly'));assert.equal(web.data.token,undefined);
 assert.equal((await api('notes')).status,401);
 assert.equal((await api('notes',null,token,{'X-Powvy-User':'other-account'})).status,401,'stale tab cannot use another account cookie');
 const id=crypto.randomUUID();const a=await put(id,{text:'original',deleted:false,baseVersion:0},token);assert.equal(a.status,200);assert.equal(a.data.note.version,1);
 assert.equal((await put(id,{text:'original',deleted:false,baseVersion:0},token)).data.note.version,1,'lost response retry is idempotent');
 assert.equal((await put(id,{text:'remote edit',deleted:false,baseVersion:1},token)).data.note.version,2);
 assert.equal((await put(id,{text:'local edit',deleted:false,baseVersion:1},token)).status,409);
 const del=await put(id,{text:'',deleted:true,baseVersion:2},token);assert.equal(del.data.note.deleted,true);
 assert.equal((await put(id,{text:'stale',deleted:false,baseVersion:2},token)).status,409);
 db.prepare('INSERT INTO users VALUES (?,?,?,?,?,NULL)').run('other','other','x','x','x');
 const otherToken='other-session';const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(otherToken)))).map(x=>x.toString(16).padStart(2,'0')).join('');db.prepare('INSERT INTO sessions VALUES (?,?,?,?)').run(hash,'other',Date.now()+100000,'x');
 assert.deepEqual((await api('notes',null,otherToken)).data.notes,[]);
 assert.equal((await api('password',{oldPassword:password,password:'new longer password'},token)).status,200);
 assert.equal((await api('me',null,token)).status,401,'password change revokes sessions');
 const recovered=await api('recover',{username:'lucas',password:'another password here',recoveryCode,newRecoveryCode:'b'.repeat(48)});assert.equal(recovered.status,200);
 assert.equal((await api('recover',{username:'lucas',password,recoveryCode,newRecoveryCode:'c'.repeat(48)})).status,401);
 const login=await api('login',{username:'lucas',password:'another password here',native:true});assert.equal(login.status,200);
 assert.equal((await api('logout',{},login.data.token)).status,200);assert.equal((await api('me',null,login.data.token)).status,401);
});
test('auth throttling and invalid input are bounded',async()=>{const {api}=fixture();for(let n=0;n<10;n++)await api('login',{username:'absent',password:'wrong'});assert.equal((await api('login',{username:'absent',password:'wrong'})).status,429);});
