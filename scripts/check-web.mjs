import {chromium,webkit} from 'playwright-core';
import {readFileSync,mkdirSync} from 'node:fs';
import assert from 'node:assert/strict';
const base=process.env.NOTE_TEST_URL||'http://localhost:8789';
if(!['localhost','127.0.0.1'].includes(new URL(base).hostname))throw Error('This test creates accounts: local server only');
const key=readFileSync('cloud/.dev.vars','utf8').match(/SETUP_KEY="([^"]+)"/)[1];
const browser=await (process.env.NOTE_WEBKIT?webkit.launch({headless:true}):chromium.launch({channel:'chrome',headless:true}));
const ipad=await browser.newContext({viewport:{width:1024,height:768},hasTouch:true}),phone=await browser.newContext({viewport:{width:390,height:844},isMobile:true,hasTouch:true});
try{
 const a=await ipad.newPage(),b=await phone.newPage();const errors=[];a.on('pageerror',e=>errors.push(e.message));b.on('pageerror',e=>errors.push(e.message));
 await a.goto(base+'/#setup='+key);await a.locator('#login [name=username]').fill('sync-test');await a.locator('#login [name=password]').fill('test-only-password-2026');await a.locator('#recovery-saved').check();await a.locator('#auth-submit').click();
 await a.waitForTimeout(1000);
 if(await a.locator('#auth-error').textContent()==='账号已经创建，请登录'){await a.locator('#recover-mode').click();await a.locator('#auth-submit').click();}
 await a.locator('#workspace').waitFor({state:'visible'});
 await a.evaluate(()=>navigator.serviceWorker.ready);await a.waitForFunction(()=>!!navigator.serviceWorker.controller);
 await a.locator('#new-note').click();await a.locator('#editor').fill('# Browser sync check\n\n- [ ] shared task');await a.locator('#sync-now').click();await a.waitForFunction(()=>document.querySelector('#status').textContent.startsWith('已同步'));
 await b.goto(base);await b.locator('#login [name=username]').fill('sync-test');await b.locator('#login [name=password]').fill('test-only-password-2026');await b.locator('#auth-submit').click();await b.locator('#workspace').waitFor({state:'visible'});await b.waitForFunction(()=>document.querySelector('#editor').value.includes('shared task'));
 assert.ok(await b.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'no horizontal overflow on iPhone');
 await ipad.setOffline(true);await a.locator('#editor').fill('# Browser sync check\n\niPad offline text');await a.waitForTimeout(1300);await a.reload();await a.locator('#workspace').waitFor({state:'visible'});assert.ok((await a.locator('#editor').inputValue()).includes('iPad offline text'),'offline reload restores pending note');
 await b.locator('#editor').fill('# Browser sync check\n\niPhone remote text');await b.locator('#sync-now').click();await b.waitForFunction(()=>document.querySelector('#status').textContent.startsWith('已同步'));
 await ipad.setOffline(false);await a.waitForFunction(()=>document.querySelector('#notice').textContent.includes('冲突'));await a.waitForFunction(()=>document.querySelector('#status').textContent.startsWith('已同步'));
 const all=await a.evaluate(async()=> (await (await fetch('/api/notes')).json()).notes);assert.ok(all.some(n=>n.text.includes('iPad offline text')));assert.ok(all.some(n=>n.text.includes('iPhone remote text')));
 await ipad.setOffline(true);await a.locator('#editor').fill('pending logout check');await a.waitForTimeout(300);await a.locator('#settings').click();await a.locator('#logout').click();await a.waitForFunction(()=>document.querySelector('#account-error').textContent.includes('未同步'));await a.locator('#account-dialog .close').click();await ipad.setOffline(false);
 mkdirSync('.deploy',{recursive:true});await a.screenshot({path:'.deploy/ipad.png'});await b.screenshot({path:'.deploy/iphone.png'});assert.deepEqual(errors,[]);console.log('PASS: setup/login, two devices, offline reload, conflict preservation, logout guard, iPhone layout');
}finally{await browser.close();}
