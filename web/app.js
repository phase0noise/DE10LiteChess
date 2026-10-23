(function(){
  'use strict';
  const {Game,decode,square}=ChessRules;
  const $=id=>document.getElementById(id),game=new Game(),fpga=new FpgaChess.Fpga();
  let human=0,flipped=false,selected=null,legal=[],busy=false,connected=false,cancel=false,claimed=false;
  let drag=null,suppressClick=false;
  const names=['','pawn','knight','bishop','rook','queen','king'];
  function applyTheme(theme) {
    const dark=theme!=='light';
    document.documentElement.dataset.theme=dark?'dark':'light';
    document.querySelector('meta[name="theme-color"]').content=dark?'#111c18':'#f6f4ed';
    $('theme').textContent=dark?'Light mode':'Dark mode';
    $('theme').setAttribute('aria-label',`Switch to ${dark?'light':'dark'} theme`);
    try {localStorage.setItem('fpga-chess-theme',dark?'dark':'light');} catch(_) {}
  }
  function save() {
    try{localStorage.setItem('fpga-chess-game',JSON.stringify({moves:game.history.map(h=>h.move),human,depth:Number($('depth').value),timeSeconds:Number($('time').value),claimed}));}catch(_){}
  }
  function restore() {
    try {
      const saved=JSON.parse(localStorage.getItem('fpga-chess-game'));
      if(saved&&Array.isArray(saved.moves)&&saved.moves.length<2000) {
        for(const move of saved.moves) game.push(move);
        human=saved.human===1?1:0;claimed=!!saved.claimed&&game.canClaim();
        if([0,2,3,4,5,6].includes(saved.depth)) $('depth').value=saved.depth;
        if([3,10,20,30].includes(saved.timeSeconds)) $('time').value=saved.timeSeconds;
      }
    } catch(_) {game.reset();}
    $('side').value=human;flipped=!!human;
  }
  function pieceElement(p) {
    const span=document.createElement('span');span.className='piece';
    span.style.backgroundPosition=`${((p&7)-1)*20}% ${(p&8)?100:0}%`;
    return span;
  }
  function render() {
    const p=game.position,outcome=claimed?{text:'Draw claimed',result:'1/2-1/2'}:game.outcome();
    legal=p.legalMoves();
    const last=game.history.length?decode(game.history.at(-1).move):null;
    const destinations=new Set(selected===null?[]:legal.filter(m=>decode(m).from===selected).map(m=>decode(m).to));
    const board=$('board');board.replaceChildren();
    for(let row=0;row<8;row++) for(let col=0;col<8;col++) {
      const x=flipped?7-col:col,y=flipped?row:7-row,s=y*8+x,piece=p.board[s];
      const button=document.createElement('button');button.className='square'+((x+y)%2===0?' dark':'');button.dataset.square=s;
      button.setAttribute('role','gridcell');button.setAttribute('aria-label',`${square(s)}${piece?' '+((piece&8)?'black ':'white ')+names[piece&7]:''}`);
      if(piece) button.append(pieceElement(piece));
      if(last&&(s===last.from||s===last.to)) button.classList.add('last');
      if(s===selected) button.classList.add('selected');
      if(destinations.has(s)) button.classList.add('legal');
      if((piece&7)===6&&(piece>>3)===p.turn&&p.inCheck()) button.classList.add('check');
      if(col===0) {const c=document.createElement('span');c.className='coord rank';c.textContent=String(y+1);button.append(c);}
      if(row===7) {const c=document.createElement('span');c.className='coord file';c.textContent='abcdefgh'[x];button.append(c);}
      button.onclick=()=>clickSquare(s);board.append(button);
    }
    $('human-caption').textContent=`Playing ${human?'black':'white'}`;
    $('engine-color').textContent=human?'WHITE':'BLACK';
    $('turn-label').textContent=outcome?'Game finished':busy?'Thinking…':p.turn===human?'Your move':'FPGA to move';
    if(!busy) $('status').textContent=outcome?outcome.text:!connected?'Connect to your FPGA':p.turn===human?(p.inCheck()?'Your king is in check.':'Your move.'):'The fabric is ready.';
    for(const id of ['new-game','side','depth','time','connect']) $(id).disabled=busy;
    $('undo').disabled=busy||!game.history.length;
    $('resume').hidden=busy||!!outcome||p.turn===human;
    $('resume').disabled=!connected;
    $('stop').hidden=!busy;
    $('claim').hidden=busy||!!outcome||p.turn!==human||!game.canClaim();
    const moves=$('moves');moves.replaceChildren();
    if(!game.history.length) {const empty=document.createElement('p');empty.className='empty-moves';empty.textContent='Every game starts with a possibility.';moves.append(empty);}
    for(let i=0;i<game.history.length;i+=2) {
      const row=document.createElement('div');row.className='move-row';
      for(const [j,text] of [`${i/2+1}.`,game.history[i].san,game.history[i+1]?.san||''].entries()) {const span=document.createElement('span');span.textContent=text;if(j===0)span.className='move-number';row.append(span);}
      moves.append(row);
    }
    moves.scrollTop=moves.scrollHeight;
  }
  function canMove() {return !busy&&connected&&game.position.turn===human&&!game.outcome()&&!claimed;}
  function squareAt(x,y) {
    const element=document.elementFromPoint(x,y)?.closest('.square');
    return element&&$('board').contains(element)?element:null;
  }
  function clearDrag() {
    const previous=drag;drag=null;
    if(!previous) return null;
    previous.ghost?.remove();
    $('board').classList.remove('dragging');
    $('board').querySelectorAll('.drag-origin,.drop-target').forEach(element=>element.classList.remove('drag-origin','drop-target'));
    if($('board').hasPointerCapture(previous.id)) $('board').releasePointerCapture(previous.id);
    return previous;
  }
  function cancelDrag() {if(clearDrag()?.moving) render();}
  const board=$('board');
  board.addEventListener('pointerdown',event=>{
    if(!event.isPrimary||event.button!==0||!canMove()||drag) return;
    const element=event.target.closest('.square');
    if(!element||!board.contains(element)) return;
    const from=Number(element.dataset.square),piece=game.position.board[from];
    if(!piece||(piece>>3)!==human) return;
    drag={id:event.pointerId,from,piece,position:game.position,x:event.clientX,y:event.clientY,moving:false,ghost:null};
  });
  window.addEventListener('pointermove',event=>{
    if(!drag||event.pointerId!==drag.id) return;
    if(busy||!connected||claimed||game.position!==drag.position) {cancelDrag();return;}
    if(!drag.moving) {
      if(Math.hypot(event.clientX-drag.x,event.clientY-drag.y)<7) return;
      selected=drag.from;render();drag.moving=true;
      const origin=board.querySelector(`[data-square="${drag.from}"]`);
      origin.classList.add('drag-origin');
      drag.size=origin.getBoundingClientRect().width;
      drag.ghost=pieceElement(drag.piece);drag.ghost.classList.add('drag-piece');
      drag.ghost.style.width=drag.ghost.style.height=`${drag.size}px`;
      document.body.append(drag.ghost);board.classList.add('dragging');
      board.setPointerCapture(event.pointerId);
    }
    event.preventDefault();
    drag.ghost.style.transform=`translate3d(${event.clientX-drag.size/2}px,${event.clientY-drag.size/2}px,0)`;
    board.querySelector('.drop-target')?.classList.remove('drop-target');
    const target=squareAt(event.clientX,event.clientY);
    if(target&&legal.some(move=>{const d=decode(move);return d.from===drag.from&&d.to===Number(target.dataset.square);})) target.classList.add('drop-target');
  },{passive:false});
  window.addEventListener('pointerup',event=>{
    if(!drag||event.pointerId!==drag.id) return;
    const target=squareAt(event.clientX,event.clientY),previous=clearDrag();
    if(!previous.moving) return;
    event.preventDefault();suppressClick=true;setTimeout(()=>{suppressClick=false;},0);
    selected=previous.from;
    const to=target?Number(target.dataset.square):null;
    if(to!==null&&legal.some(move=>{const d=decode(move);return d.from===selected&&d.to===to;})) clickSquare(to);
    else render();
  });
  window.addEventListener('pointercancel',event=>{if(drag?.id===event.pointerId) cancelDrag();});
  board.addEventListener('lostpointercapture',event=>{if(drag?.id===event.pointerId) cancelDrag();});
  window.addEventListener('blur',cancelDrag);
  document.addEventListener('visibilitychange',()=>{if(document.hidden) cancelDrag();});
  board.addEventListener('click',event=>{if(suppressClick){event.preventDefault();event.stopImmediatePropagation();suppressClick=false;}},{capture:true});
  board.addEventListener('contextmenu',event=>event.preventDefault());
  board.addEventListener('dragstart',event=>event.preventDefault());
  board.addEventListener('wheel',event=>event.preventDefault(),{passive:false});
  function message(text,error=false) {$('message').textContent=text;$('message').classList.toggle('error',error);}
  function connection(on) {
    connected=on;const element=$('connection');element.className='connection '+(on?'online':'offline');
    element.replaceChildren(document.createElement('i'),document.createTextNode(on?'FPGA connected':'FPGA disconnected'));
  }
  async function connect() {
    if(busy) return;busy=true;render();$('status').textContent='Connecting…';
    try {
      await fpga.status();await fpga.command(3);connection(true);
      message('Connected. The board is yours.');
    } catch(error) {connection(false);message(error.message,true);}
    finally {busy=false;render();}
  }
  async function engineTurn() {
    if(busy||!connected||game.position.turn===human||game.outcome()||claimed) return;
    busy=true;cancel=false;selected=null;render();$('status').textContent='The fabric is thinking…';message('Finding a reply on the FPGA.');
    try {
      const result=await fpga.evaluate(game,{depth:Number($('depth').value),timeSeconds:Number($('time').value),cancelled:()=>cancel,
        progress:status=>{if(status.searchDepth>=2) $('status').textContent=`Searching ${status.searchDepth} ply…`;}});
      if(result.move!==null) game.push(result.move);
      $('decision').textContent=`${(result.cycles/50000000).toFixed(2)} s`;
      $('nodes').textContent=result.nodes.toLocaleString();
      $('search-depth').textContent=result.depth?`${result.depth}${result.depth!==result.targetDepth?' / '+result.targetDepth:''} ply`:'—';
      $('cache-hits').textContent=(result.cacheHits||0).toLocaleString();save();
      message(game.outcome()?.text||(result.budgetExpired?`Your turn. Completed ${result.depth} ply in the time available.`:'Your turn. Take your time.'));
    } catch(error) {
      if(cancel) message('Search stopped. Play the FPGA turn when you are ready.');
      else {message(error.message,true);connection(false);}
    } finally {busy=false;render();}
  }
  async function choosePromotion(moves) {
    const dialog=$('promotion'),options=$('promotion-options');options.replaceChildren();
    return new Promise(resolve=>{
      const finish=move=>{dialog.close();dialog.oncancel=null;resolve(move);};
      for(const move of moves.slice().reverse()) {
        const pr=decode(move).promotion,button=document.createElement('button');
        button.setAttribute('aria-label',names[pr]);button.title=names[pr];button.append(pieceElement(pr|(human<<3)));button.onclick=()=>finish(move);options.append(button);
      }
      $('promotion-cancel').onclick=()=>finish(null);dialog.oncancel=event=>{event.preventDefault();finish(null);};dialog.showModal();
    });
  }
  async function clickSquare(s) {
    if(!canMove()) return;
    const p=game.position;
    if(selected!==null) {
      const choices=legal.filter(m=>{const d=decode(m);return d.from===selected&&d.to===s;});
      if(choices.length) {
        const move=choices.length>1?await choosePromotion(choices):choices[0];
        if(move===null) return;
        game.push(move);selected=null;save();render();
        if(!game.outcome()) await engineTurn();return;
      }
    }
    selected=p.board[s]&&(p.board[s]>>3)===human?(selected===s?null:s):null;render();
  }
  $('connect').onclick=connect;
  $('theme').onclick=()=>applyTheme(document.documentElement.dataset.theme==='dark'?'light':'dark');
  $('new-game').onclick=async()=>{
    cancelDrag();
    game.reset();claimed=false;human=Number($('side').value);flipped=!!human;selected=null;save();render();message('A fresh board. Make it yours.');
    await engineTurn();
  };
  $('side').onchange=()=>message('Your color will apply when you start a new game.');
  $('depth').onchange=save;
  $('time').onchange=save;
  $('flip').onclick=()=>{cancelDrag();flipped=!flipped;render();};
  $('undo').onclick=()=>{cancelDrag();game.undoTurn(human);selected=null;claimed=false;save();render();message('Previous turn restored.');};
  $('resume').onclick=engineTurn;
  $('stop').onclick=()=>{cancel=true;message('Stopping after the current command…');};
  $('claim').onclick=()=>{claimed=true;save();render();message('Draw claimed.');};
  $('download').onclick=()=>{
    const result=claimed?'1/2-1/2':game.outcome()?.result||'*';
    const url=URL.createObjectURL(new Blob([game.pgn(result)],{type:'application/x-chess-pgn'}));
    const a=document.createElement('a');a.href=url;a.download='fpga-chess.pgn';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
  };
  let theme='dark';try {theme=localStorage.getItem('fpga-chess-theme')||theme;} catch(_) {}
  applyTheme(theme);restore();render();connect();
})();
