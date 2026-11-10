import {copyFileSync,readFileSync,writeFileSync} from 'node:fs';
copyFileSync(new URL('../windows/md.js',import.meta.url),new URL('../web/md.js',import.meta.url));

import {createHash} from 'node:crypto';
const hash=createHash('sha256');for(const f of ['index.html','app.js','sync.js','md.js','style.css','manifest.webmanifest','icon.svg','icon-192.png','icon-512.png','power-theme.css','power-display.ttf','power-mono.ttf','chainsaw-city.webp'])hash.update(readFileSync(new URL('../web/'+f,import.meta.url)));
const file=new URL('../web/sw.js',import.meta.url);writeFileSync(file,readFileSync(file,'utf8').replace(/const CACHE='[^']+'/,`const CACHE='powvy-note-${hash.digest('hex').slice(0,16)}'`));
