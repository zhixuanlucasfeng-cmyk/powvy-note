const enc=new TextEncoder();
const hex=b=>Array.from(new Uint8Array(b),v=>v.toString(16).padStart(2,'0')).join('');
const random=()=>hex(crypto.getRandomValues(new Uint8Array(32)));
const digest=async s=>hex(await crypto.subtle.digest('SHA-256',enc.encode(s)));
const json=(data,status=200,headers={})=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store','X-Content-Type-Options':'nosniff',...headers}});
const fail=(status,message)=>{throw Object.assign(new Error(message),{status})};
const query=(env,sql,...args)=>env.DB.prepare(sql).bind(...args);
async function passwordHash(password,salt){const key=await crypto.subtle.importKey('raw',enc.encode(password),'PBKDF2',false,['deriveBits']);return hex(await crypto.subtle.deriveBits({name:'PBKDF2',salt:enc.encode(salt),iterations:100000,hash:'SHA-256'},key,256));}
function equal(a,b){if(typeof a!=='string'||typeof b!=='string'||a.length!==b.length)return false;let n=0;for(let i=0;i<a.length;i++)n|=a.charCodeAt(i)^b.charCodeAt(i);return n===0;}
function credentials(b){const username=String(b.username||'').trim().toLowerCase();if(!/^[a-z0-9_\-]{3,32}$/.test(username))fail(400,'用户名需为 3–32 位字母、数字、下划线或短横线');if(typeof b.password!=='string'||b.password.length<12||b.password.length>128)fail(400,'密码需为 12–128 个字符');return username;}
function recovery(code){if(typeof code!=='string'||!/^[-a-zA-Z0-9_]{40,128}$/.test(code))fail(400,'恢复码格式不正确');return code;}
async function body(req){if(!req.headers.get('content-type')?.startsWith('application/json'))fail(415,'需要 JSON 请求');const reader=req.body?.getReader();if(!reader)return {};let size=0,chunks=[];while(true){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>270000){await reader.cancel();fail(413,'内容过大');}chunks.push(value);}const bytes=new Uint8Array(size);let pos=0;for(const c of chunks){bytes.set(c,pos);pos+=c.length;}try{const b=JSON.parse(new TextDecoder().decode(bytes));if(!b||typeof b!=='object'||Array.isArray(b))throw Error();return b;}catch{fail(400,'无效 JSON');}}
async function limit(env,key,max){const now=Date.now(),window=Math.floor(now/900000);const row=await query(env,'INSERT INTO attempts(key,count,expires) VALUES (?,1,?) ON CONFLICT(key) DO UPDATE SET count=count+1 RETURNING count',await digest(key+':'+window),now+900000).first();if(row.count>max)fail(429,'尝试次数过多，请 15 分钟后再试');}
function cookie(token,req,age=2592000){return `powvy_session=${token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${age}${new URL(req.url).protocol==='https:'?'; Secure':''}`;}
function tokenOf(req){return req.headers.get('authorization')?.replace(/^Bearer /,'')||req.headers.get('cookie')?.match(/(?:^|;\s*)powvy_session=([^;]+)/)?.[1]||'';}
async function current(req,env){const token=tokenOf(req);if(!token)fail(401,'请先登录');const user=await query(env,'SELECT users.id,users.username FROM sessions JOIN users ON users.id=sessions.user_id WHERE sessions.hash=? AND sessions.expires>? AND sessions.credential_version=users.password_hash',await digest(token),Date.now()).first();if(!user)fail(401,'登录已过期，请重新登录');return user;}
async function session(req,env,user,native){const token=random();await query(env,'INSERT INTO sessions(hash,user_id,expires,credential_version) VALUES (?,?,?,?)',await digest(token),user.id,Date.now()+2592000000,user.password_hash).run();return json({user:{id:user.id,username:user.username},...(native&&!req.headers.has('origin')?{token}:{})},200,{'Set-Cookie':cookie(token,req)});}
const note=r=>r?{...r,deleted:!!r.deleted}:null;
export default {async fetch(req,env){try{
 const url=new URL(req.url),path=url.pathname;
 if(!path.startsWith('/api/'))return env.ASSETS.fetch(req);
 const origin=req.headers.get('origin');if((origin&&origin!==url.origin)||req.headers.get('sec-fetch-site')==='cross-site')fail(403,'不允许跨站请求');
 if(!['GET','POST','PUT'].includes(req.method))fail(405,'不支持的请求方法');
 if(path==='/api/health'&&req.method==='GET')return json({ok:true});
 if(req.method==='POST'&&['/api/login','/api/setup','/api/recover'].includes(path)){
  const b=await body(req),username=String(b.username||'').trim().toLowerCase();
  await limit(env,'ip:'+String(req.headers.get('cf-connecting-ip')||'local'),100);
  await limit(env,path+':'+username,10);
  await query(env,'DELETE FROM attempts WHERE expires<?',Date.now()).run();
  await query(env,'DELETE FROM sessions WHERE expires<?',Date.now()).run();
  if(path==='/api/setup'){
   if(!env.SETUP_KEY||!equal(await digest(req.headers.get('x-setup-key')||''),await digest(env.SETUP_KEY)))fail(403,'需要私人初始化链接');
   credentials(b);recovery(b.recoveryCode);
   const id=crypto.randomUUID(),salt=random(),hash=await passwordHash(b.password,salt);
   const created=await query(env,'INSERT OR IGNORE INTO users(id,username,password_hash,salt,recovery_hash) VALUES (?,?,?,?,?) RETURNING id',id,username,hash,salt,await digest(b.recoveryCode)).first();
   if(!created)fail(409,'账号已经创建，请登录');
   return session(req,env,{id,username,password_hash:hash},b.native===true);
  }
  const user=await query(env,'SELECT * FROM users WHERE username=?',username).first();
  if(path==='/api/recover'){
   credentials(b);recovery(b.recoveryCode);recovery(b.newRecoveryCode);
   const oldHash=await digest(b.recoveryCode);if(!user||!equal(oldHash,user.recovery_hash))fail(401,'用户名或恢复码不正确');
   const salt=random(),hash=await passwordHash(b.password,salt);
   const changed=await query(env,'UPDATE users SET salt=?,password_hash=?,recovery_hash=? WHERE id=? AND recovery_hash=? RETURNING id',salt,hash,await digest(b.newRecoveryCode),user.id,oldHash).first();
   if(!changed)fail(401,'恢复码已使用');
   await query(env,'DELETE FROM sessions WHERE user_id=?',user.id).run();return json({ok:true});
  }
  if(typeof b.password!=='string'||b.password.length>128)fail(401,'用户名或密码不正确');
  const hash=await passwordHash(b.password,user?.salt||'missing-user-salt');
  if(!user||!equal(hash,user.password_hash))fail(401,'用户名或密码不正确');
  return session(req,env,user,b.native===true);
 }
 const user=await current(req,env);
 const expected=req.headers.get('x-powvy-user');if(expected&&expected!==user.id)fail(401,'账号已切换，请重新登录；本机更改仍保留');
 if(path==='/api/me'&&req.method==='GET')return json({user});
 if(path==='/api/logout'&&req.method==='POST'){await query(env,'DELETE FROM sessions WHERE hash=?',await digest(tokenOf(req))).run();return json({ok:true},200,{'Set-Cookie':cookie('',req,0)});}
 if(path==='/api/password'&&req.method==='POST'){
  await limit(env,'password:'+user.id,10);const b=await body(req);credentials({username:user.username,password:b.password});
  const record=await query(env,'SELECT * FROM users WHERE id=?',user.id).first();
  if(typeof b.oldPassword!=='string'||b.oldPassword.length>128||!equal(await passwordHash(b.oldPassword,record.salt),record.password_hash))fail(401,'原密码不正确');
  const salt=random();const changed=await query(env,'UPDATE users SET password_hash=?,salt=? WHERE id=? AND password_hash=? RETURNING id',await passwordHash(b.password,salt),salt,user.id,record.password_hash).first();if(!changed)fail(409,'密码已变更，请重新登录');
  await query(env,'DELETE FROM sessions WHERE user_id=?',user.id).run();return json({ok:true},200,{'Set-Cookie':cookie('',req,0)});
 }
 if(path==='/api/notes'&&req.method==='GET'){const rows=await query(env,'SELECT id,text,version,deleted,updated FROM notes WHERE user_id=? ORDER BY updated DESC',user.id).all();return json({notes:rows.results.map(note)});}
 if(path.startsWith('/api/notes/')&&req.method==='PUT'){
  const id=path.slice('/api/notes/'.length);if(!/^[0-9a-f-]{36}$/i.test(id))fail(400,'笔记 ID 无效');
  const b=await body(req);if(typeof b.text!=='string'||enc.encode(b.text).length>200000||typeof b.deleted!=='boolean'||!Number.isSafeInteger(b.baseVersion)||b.baseVersion<0)fail(400,'笔记内容或版本无效（单篇上限 200KB）');
  const now=Date.now();let saved;
  if(b.baseVersion===0){
   const quota=await query(env,'SELECT COUNT(*) AS n, COALESCE(SUM(LENGTH(CAST(text AS BLOB))),0) AS bytes FROM notes WHERE user_id=?',user.id).first();
   if(quota.n>=1000||quota.bytes+enc.encode(b.text).length>20000000)fail(413,'笔记空间已满，请先导出整理');
   saved=await query(env,'INSERT OR IGNORE INTO notes(user_id,id,text,version,deleted,updated) VALUES (?,?,?,1,?,?) RETURNING id,text,version,deleted,updated',user.id,id,b.text,Number(b.deleted),now).first();
  }else saved=await query(env,'UPDATE notes SET text=?,deleted=?,version=version+1,updated=? WHERE user_id=? AND id=? AND version=? RETURNING id,text,version,deleted,updated',b.text,Number(b.deleted),now,user.id,id,b.baseVersion).first();
  if(saved)return json({note:note(saved)});
  const remote=await query(env,'SELECT id,text,version,deleted,updated FROM notes WHERE user_id=? AND id=?',user.id,id).first();
  if(remote&&remote.text===b.text&&!!remote.deleted===b.deleted)return json({note:note(remote)});
  return json({error:'这篇笔记已在另一台设备修改',note:note(remote)},409);
 }
 return json({error:'未找到接口'},404);
 }catch(e){return json({error:e.status?e.message:'服务暂时不可用，请稍后重试'},e.status||500);}}};
