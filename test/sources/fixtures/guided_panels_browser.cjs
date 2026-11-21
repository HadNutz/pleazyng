// Actual browser rendering: authored frame order, overview, rotation and resume.
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require(process.env.PLEZY_PLAYWRIGHT_PATH || '../../../tools/reader-tests/node_modules/playwright');
const root = path.resolve(__dirname,'../../..');
const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="1000"><rect width="1600" height="1000" fill="#263346"/><rect x="800" y="0" width="800" height="1000" fill="#466a8a"/><rect x="900" y="50" width="200" height="250" fill="#cc9d61"/></svg>';
(async()=>{
  const server = http.createServer((request,response)=>{
    if(request.url==='/fixture.svg'){response.setHeader('Content-Type','image/svg+xml');response.end(svg);return;}
    if(request.url.startsWith('/assets/reader/') && !request.url.includes('..')){
      response.setHeader('Content-Type','application/javascript');response.end(fs.readFileSync(path.join(root,request.url)));return;
    }
    response.setHeader('Content-Type','text/html');
    response.end('<style>html,body{margin:0;width:100%;height:100%;background:#111}</style><script type="module">'+
      'import {ComicReader} from "/assets/reader/comic-reader.js";window.events=[];window.reader=new ComicReader();document.body.append(reader);'+
      'window.reopen=async cfi=>reader.open({direction:"rtl",metadata:{},pages:[{name:"fixture",archiveIndex:2,width:1600,height:1000,frames:[[800,0,1600,1000],[900,50,1100,300],[0,0,800,1000]]},{name:"splash",archiveIndex:0,width:1600,height:1000}]},'+
      '{title:"Guided fixture",interfaceLocale:"en",cfi,settings:{comicMode:"panels",direction:"auto",zoom:"fit-page"}},(type,data)=>events.push({type,...data}),()=>"/fixture.svg");await reopen();</script>');
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  let browser;
  try {
    browser=await chromium.launch({executablePath:process.env.PLEZY_CHROME_PATH,headless:true,args:['--no-sandbox']});
    const page=await browser.newPage({viewport:{width:400,height:850}}),errors=[];
    page.on('pageerror',error=>errors.push(error.message));
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.waitForFunction(()=>window.reader?.shadowRoot.querySelector('img')?.naturalWidth===1600);
    assert.equal(await page.evaluate(()=>reader.panel),0);
    await page.evaluate(()=>reader.next());
    assert.equal(await page.evaluate(()=>reader.panel),1);
    const saved=await page.evaluate(()=>events.filter(e=>e.type==='location').at(-1).cfi);
    assert.match(saved,/^plezy-comic:2:-1:0:p1$/);
    // The inset rectangle is magnified into a bounded, centered viewport.
    const bounds=await page.evaluate(()=>{const r=reader.shadowRoot.querySelector('figure').getBoundingClientRect();return {w:r.width,h:r.height};});
    assert.ok(bounds.w<=400.1 && bounds.h<=850.1 && bounds.w>300);
    await page.keyboard.press('Enter');
    assert.equal(await page.evaluate(()=>reader.overview),true);
    await page.keyboard.press('Enter');
    await page.setViewportSize({width:850,height:400});
    assert.equal(await page.evaluate(()=>reader.panel),1);
    await page.evaluate(cfi=>reopen(cfi),saved);
    assert.equal(await page.evaluate(()=>reader.panel),1);
    await page.evaluate(()=>{reader.next();reader.next();});
    assert.equal(await page.evaluate(()=>reader.index),1);
    assert.equal(await page.evaluate(()=>reader.panel),undefined);
    await page.evaluate(()=>reader.goTo('splash'));
    assert.match(await page.evaluate(()=>events.filter(e=>e.type==='location').at(-1).cfi),/^plezy-comic:0:/);
    await page.evaluate(cfi=>reader.goTo(cfi),saved);
    assert.equal(await page.evaluate(()=>reader.index),0);
    assert.equal(await page.evaluate(()=>reader.panel),1);
    assert.deepEqual(errors,[]);
    if(process.env.PLEZY_PANEL_SCREENSHOT){await page.evaluate(cfi=>reopen(cfi),saved);await page.screenshot({path:process.env.PLEZY_PANEL_SCREENSHOT});}
    console.log('Guided panels: actual crop, authored RTL order, overview, rotation, resume and splash fallback passed');
  } finally {await browser?.close();await new Promise(resolve=>server.close(resolve));}
})().catch(error=>{console.error(error);process.exitCode=1;});
