import { chromium, webkit } from 'playwright-core';
import assert from 'node:assert/strict';
const browser=await (process.env.NOTE_WEBKIT?webkit.launch():chromium.launch({channel:'chrome'}));
try{
 for(const [name,width,height] of [['phone',390,844],['ipad',1024,768],['narrow',320,568]]){
  const context=await browser.newContext({viewport:{width,height},hasTouch:true});const page=await context.newPage();
  await page.goto('http://localhost:8789/');await page.locator('[name=username]').fill('sync-test');await page.locator('#login [name=password]').fill('test-only-password-2026');await page.locator('#auth-submit').click();await page.locator('#workspace').waitFor({state:'visible'});
  if(width<700)await page.locator('#show-list').click();await page.locator('#new-note').click();await page.locator('#editor').fill('# 今天的笔记\n\n把想到的事情先写下来。\n\n- [ ] 整理数学笔记\n- [ ] 羽毛球训练\n\nKeep it simple. Keep writing.');
  await page.locator('#tag-menu summary').click();await page.locator('[data-tag=homework]').click();assert.equal(await page.locator('#tag-menu').getAttribute('open'),null);assert.match(await page.locator('#editor').inputValue(),/homework/);
  await page.locator('#preview-toggle').click();await page.locator('#preview').waitFor({state:'visible'});assert.equal(await page.locator('#preview-toggle').getAttribute('aria-label'),'编辑');assert.equal(await page.locator('#strike').isDisabled(),true);assert.equal(await page.locator('#preview .tag-homework').evaluate(el=>getComputedStyle(el).backgroundColor),'rgb(92, 158, 255)');
  await page.locator('#preview-toggle').click();await page.locator('#editor').waitFor({state:'visible'});assert.equal(await page.locator('#strike').isDisabled(),false);
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
  await page.screenshot({path:'.deploy/ui-'+name+'.png'});
  if(width<700){await page.locator('#show-list').click();await page.waitForTimeout(220);await page.screenshot({path:'.deploy/ui-'+name+'-list.png'});await page.locator('#settings').click();await page.locator('#account-dialog').waitFor({state:'visible'});await page.locator('#account-dialog .close').click();await page.locator('#close-list').click();}
  await context.close();console.log('PASS '+name+': layout, tags, preview, settings');
 }
}finally{await browser.close()}
