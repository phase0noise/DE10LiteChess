/* Local browser integration with an explicitly simulated protocol endpoint.
 * This is a UI test, not physical-board acceptance or an FPGA simulation. */
'use strict';
const http=require('node:http'),fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {spawn}=require('node:child_process');
const {Position,Game,uci}=require('../web/chess.js');
const {hex,unhex}=require('../web/fpga.js');
const root=path.resolve(__dirname,'..');
let p=new Position(),done=false,generation=1,selected=0,requestedDepth=5;
function respondCommand(bytes){
  const sub=bytes[0];
  switch(sub){
    case 0:{
      const a=new Uint8Array(32);a.set([83,67,70,49]);a[5]=done?1:0;a[7]=p.turn;a[15]=4;a[28]=requestedDepth;a[29]=done?requestedDepth:0;
      const moves=p.legalMoves();selected=moves.find(m=>uci(m)==='e7e5')??moves[0];
      a[8]=moves.length>>8;a[9]=moves.length&255;a[10]=selected>>8;a[11]=selected&255;
      a[23]=generation;return a;
    }
    case 1:p.board=Uint8Array.from(bytes.slice(1,65));p.turn=bytes[65];p.rights=bytes[66];p.ep=bytes[67];generation++;return [0];
    case 2:done=true;return [0];
    case 3:done=false;return [0];
    case 5:return p.positionBytes();
    case 7:{const a=new Uint8Array(64),moves=p.legalMoves();for(let i=0;i<16;i++){const m=moves[bytes[1]*16+i]||0;a[i*4]=m>>8;a[i*4+1]=m&255;}return a;}
    case 11:p.make(selected);return [0];
    case 12:return new Uint8Array(64);
    case 13:requestedDepth=bytes[12];return [0];
    case 18:{const a=new Uint8Array(20);a[8]=requestedDepth;a[9]=4;a[10]=requestedDepth;a[11]=2;a[15]=7;return a;}
    default:return [0];
  }
}
const server=http.createServer((req,res)=>{
  if(req.url==='/api/command'){
    let body='';req.on('data',a=>body+=a);req.on('end',()=>{try{const payload=respondCommand(unhex(body));res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify({status:0,payload:hex(payload)}));}catch(e){res.writeHead(500);res.end(JSON.stringify({error:e.message}));}});return;
  }
  const name=req.url==='/'?'index.html':req.url.slice(1),file=path.join(root,'web',name);
  if(!['index.html','style.css','chess.js','fpga.js','app.js','pieces.png'].includes(name)){res.writeHead(404);res.end();return;}
  res.setHeader('Content-Type',name.endsWith('.js')?'application/javascript':name.endsWith('.css')?'text/css':name.endsWith('.png')?'image/png':'text/html');
  fs.createReadStream(file).pipe(res);
});
function delay(ms){return new Promise(resolve=>setTimeout(resolve,ms));}
async function run(){
  console.log('Starting browser smoke test with a simulated FPGA endpoint.');
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const port=server.address().port,debugPort=port+1;
  const chrome=process.env.CHROME||'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
  const browser=spawn(chrome,['--headless=new','--no-first-run','--no-default-browser-check','--disable-crash-reporter',`--remote-debugging-port=${debugPort}`,`--user-data-dir=${path.join(root,`.cache/browser-profile-${process.pid}`)}`,'about:blank'],{windowsHide:true,stdio:'ignore'});
  let socket;
  try {
    let pages;
    for(let i=0;i<60;i++){try{pages=await(await fetch(`http://127.0.0.1:${debugPort}/json`,{signal:AbortSignal.timeout(300)})).json();if(pages.some(p=>p.type==='page'))break;}catch(_){}await delay(100);}
    assert(pages,'Chrome did not expose its debugging endpoint');
    socket=new WebSocket(pages.find(p=>p.type==='page').webSocketDebuggerUrl);
    await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Browser WebSocket open timed out')),5000);socket.onopen=()=>{clearTimeout(timer);resolve();};socket.onerror=reject;});
    let id=0;const pending=new Map(),errors=[];
    socket.onmessage=event=>{const msg=JSON.parse(event.data);if(msg.id){const task=pending.get(msg.id);pending.delete(msg.id);msg.error?task.reject(Error(JSON.stringify(msg.error))):task.resolve(msg.result);}else if(msg.method==='Runtime.exceptionThrown')errors.push(msg.params);};
    const call=(method,params={})=>new Promise((resolve,reject)=>{const n=++id;const timer=setTimeout(()=>{pending.delete(n);reject(Error(`Browser command timed out: ${method}`));},5000);pending.set(n,{resolve:value=>{clearTimeout(timer);resolve(value);},reject});socket.send(JSON.stringify({id:n,method,params}));});
    const evaluate=async expression=>{const r=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw Error(JSON.stringify(r.exceptionDetails));return r.result.value;};
    async function wait(expression){for(let i=0;i<100;i++){if(await evaluate(expression))return;await delay(60);}throw Error(`Browser wait timed out: ${expression}`);}
    const center=s=>evaluate(`(()=>{const r=document.querySelector('[data-square="${s}"]').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()`);
    async function dragPiece(from,to,{touch=false,cancel=false}={}) {
      const start=typeof from==='number'?await center(from):from,end=typeof to==='number'?await center(to):to;
      if(touch) await call('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{...start,id:0}]});
      else {
        await call('Input.dispatchMouseEvent',{type:'mouseMoved',...start});
        await call('Input.dispatchMouseEvent',{type:'mousePressed',...start,button:'left',buttons:1,clickCount:1});
      }
      for(let step=1;step<=8;step++) {
        const point={x:start.x+(end.x-start.x)*step/8,y:start.y+(end.y-start.y)*step/8};
        if(touch) await call('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{...point,id:0}]});
        else await call('Input.dispatchMouseEvent',{type:'mouseMoved',...point,button:'left',buttons:1});
        await delay(18);
      }
      if(touch) await call('Input.dispatchTouchEvent',{type:cancel?'touchCancel':'touchEnd',touchPoints:[]});
      else await call('Input.dispatchMouseEvent',{type:'mouseReleased',...end,button:'left',buttons:0,clickCount:1});
      await delay(80);
    }
    const waitForReply=()=>wait('document.querySelectorAll(".move-row").length===1 && document.querySelector(".move-row").textContent.includes("e5") && !document.querySelector("#new-game").disabled');
    await call('Runtime.enable');await call('Page.enable');
    await call('Emulation.setDeviceMetricsOverride',{width:1200,height:950,deviceScaleFactor:1,mobile:false});
    await call('Page.navigate',{url:`http://127.0.0.1:${port}/`});
    await wait('document.querySelector("#connection.online")');
    console.log('Browser connected to the simulated endpoint.');
    assert.equal(await evaluate('document.querySelectorAll(".square").length'),64);
    assert.equal(await evaluate('document.querySelectorAll(".piece").length'),32);
    assert.equal(await evaluate('document.querySelector("#depth").value'),'5');
    assert.equal(await evaluate('document.querySelector("#time").value'),'10');
    assert.equal(await evaluate('document.documentElement.dataset.theme'),'dark');
    assert.equal(await evaluate('getComputedStyle(document.documentElement).colorScheme'),'dark');
    await evaluate('document.querySelector("#theme").click()');
    assert.equal(await evaluate('document.documentElement.dataset.theme'),'light');
    await call('Page.reload');await wait('document.querySelector("#connection.online")');
    assert.equal(await evaluate('document.documentElement.dataset.theme'),'light','Theme preference was not restored');
    await evaluate('document.querySelector("#theme").click()');
    assert.equal(await evaluate('document.querySelector(\'meta[name="theme-color"]\').content'),'#111c18');
    await evaluate('document.querySelector(\'[data-square="12"]\').click()');
    assert.equal(await evaluate('document.querySelectorAll(".legal").length'),2);
    await evaluate('document.querySelector(\'[data-square="28"]\').click()');
    await waitForReply();
    assert.equal(await evaluate('document.querySelector("#turn-label").textContent'),'Your move');
    assert.equal(await evaluate('document.querySelector("#search-depth").textContent'),'5 ply');
    assert.equal(await evaluate('document.querySelector("#cache-hits").textContent'),'7');
    fs.writeFileSync(path.join(root,'.cache/browser-desktop.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:true})).data,'base64'));
    await evaluate('document.querySelector("#undo").click()');assert.equal(await evaluate('document.querySelectorAll(".move-row").length'),0);
    await dragPiece(12,36); // e2-e5 is illegal.
    assert.equal(await evaluate('document.querySelectorAll(".move-row").length'),0);
    assert(await evaluate('document.querySelector(\'[data-square="12"] .piece\')'));
    await dragPiece(12,{x:1180,y:200}); // Dropping outside the board cancels.
    assert.equal(await evaluate('document.querySelectorAll(".move-row").length'),0);
    assert.equal(await evaluate('document.querySelectorAll(".drag-piece,.drag-origin,.drop-target").length'),0);
    await dragPiece(12,28);await waitForReply();
    assert(await evaluate('document.querySelector(\'[data-square="28"] .piece\')'),'Mouse drag did not move the pawn');
    await evaluate('document.querySelector("#undo").click()');
    await evaluate('document.querySelector("#flip").click()');assert.equal(await evaluate('document.querySelector(".square").dataset.square'),'7');
    await call('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:true});
    await call('Emulation.setTouchEmulationEnabled',{enabled:true,maxTouchPoints:1});
    await delay(150);
    assert(await evaluate('document.documentElement.scrollWidth<=window.innerWidth'),'Mobile layout overflowed');
    const scrollBefore=await evaluate('window.scrollY'),empty=await center(27);
    await dragPiece(empty,{x:empty.x,y:empty.y-110},{touch:true});
    assert.equal(await evaluate('window.scrollY'),scrollBefore,'Touching an empty square scrolled the page');
    await dragPiece(12,28,{touch:true});await waitForReply();
    assert.equal(await evaluate('window.scrollY'),scrollBefore,'Dragging a piece scrolled the page');
    assert(await evaluate('document.querySelector(\'[data-square="28"] .piece\')'),'Touch drag on a flipped board failed');
    await evaluate('document.querySelector("#undo").click()');
    await dragPiece(12,28,{touch:true,cancel:true});
    assert.equal(await evaluate('document.querySelectorAll(".move-row").length'),0,'A cancelled gesture played a move');
    assert.equal(await evaluate('document.querySelectorAll(".drag-piece,.drag-origin,.drop-target").length'),0);
    await evaluate('document.querySelector(\'[data-square="27"]\').click()');
    await dragPiece(12,12,{touch:true});
    assert.equal(await evaluate('document.querySelectorAll(".legal").length'),2,'A touch tap did not select the pawn');
    await dragPiece(28,28,{touch:true});await waitForReply();
    assert.equal(await evaluate('window.scrollY'),scrollBefore,'Tap-to-move scrolled the page');
    await dragPiece({x:8,y:700},{x:8,y:300},{touch:true});await delay(300);
    assert(await evaluate('window.scrollY>30'),'Scrolling outside the board was blocked');
    await evaluate('window.scrollTo(0,0)');await delay(150);
    fs.writeFileSync(path.join(root,'.cache/browser-mobile.png'),Buffer.from((await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:true})).data,'base64'));
    const promotionGame=new Game();
    for(const text of ['a2a4','h7h5','a4a5','h5h4','a5a6','h4h3','a6b7','h3g2']) {
      const move=promotionGame.position.legalMoves().find(move=>uci(move)===text);assert.notEqual(move,undefined);promotionGame.push(move);
    }
    await evaluate(`localStorage.setItem('fpga-chess-game',${JSON.stringify(JSON.stringify({moves:promotionGame.history.map(h=>h.move),human:0,depth:3,claimed:false}))})`);
    await call('Page.reload');await wait('document.querySelector("#connection.online")');
    await dragPiece(49,56,{touch:true});await wait('document.querySelector("#promotion").open');
    await evaluate('document.querySelector("#promotion-cancel").click()');
    assert(await evaluate('document.querySelector(\'[data-square="49"] .piece\')'),'Cancelling promotion removed the pawn');
    await dragPiece(49,56,{touch:true});await wait('document.querySelector("#promotion").open');
    await evaluate('document.querySelector(\'#promotion-options [aria-label="queen"]\').click()');
    await wait('!document.querySelector("#new-game").disabled && document.querySelectorAll(".move-row").length===5');
    assert.equal(await evaluate('document.querySelector(\'[data-square="56"]\').getAttribute("aria-label")'),'a8 white queen');
    // Saved history survives reload; disconnection is an error, never a software opponent.
    await call('Page.reload');await wait('document.querySelector("#connection.online")');
    assert.equal(await evaluate('document.querySelectorAll(".square").length'),64);
    assert.equal(await evaluate('document.querySelector(\'[data-square="56"]\').getAttribute("aria-label")'),'a8 white queen');
    assert.equal(await evaluate('document.documentElement.dataset.theme'),'dark');
    assert.deepEqual(errors,[],'Browser raised JavaScript exceptions');
    console.log('Desktop/mobile browser: themes and persistence, tap/mouse/touch moves, illegal/outside/cancelled drops, flipped-board dragging, promotion, board scroll lock, outside scrolling and reload passed.');
  }finally{if(socket)socket.close();browser.kill();server.close();}
}
run().catch(error=>{console.error(error);server.close();process.exitCode=1;});
