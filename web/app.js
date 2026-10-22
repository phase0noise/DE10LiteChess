(function(){
  'use strict';
  const {Game,decode,square}=ChessRules;
  const $=id=>document.getElementById(id),game=new Game(),fpga=new FpgaChess.Fpga();
  let human=0,flipped=false,selected=null,legal=[],busy=false,connected=false,cancel=false,claimed=false;
  const names=['','pawn','knight','bishop','rook','queen','king'];
  function save() {
    try{localStorage.setItem('fpga-chess-game',JSON.stringify({moves:game.history.map(h=>h.move),human,depth:Number($('depth').value),claimed}));}catch(_){}
  }
  function restore() {
    try {
      const saved=JSON.parse(localStorage.getItem('fpga-chess-game'));
      if(saved&&Array.isArray(saved.moves)&&saved.moves.length<2000) {
        for(const move of saved.moves) game.push(move);
        human=saved.human===1?1:0;claimed=!!saved.claimed&&game.canClaim();
        if([0,2,3].includes(saved.depth)) $('depth').value=saved.depth;
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
    for(const id of ['new-game','side','depth','connect']) $(id).disabled=busy;
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
      const result=await fpga.evaluate(game,{depth:Number($('depth').value),cancelled:()=>cancel});
      if(result.move!==null) game.push(result.move);
      $('decision').textContent=`${(result.cycles/50000000).toFixed(2)} s`;
      $('nodes').textContent=result.nodes.toLocaleString();save();
      message(game.outcome()?.text||'Your turn. Take your time.');
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
    if(busy||!connected||game.position.turn!==human||game.outcome()||claimed) return;
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
  $('new-game').onclick=async()=>{
    game.reset();claimed=false;human=Number($('side').value);flipped=!!human;selected=null;save();render();message('A fresh board. Make it yours.');
    await engineTurn();
  };
  $('side').onchange=()=>message('Your color will apply when you start a new game.');
  $('depth').onchange=save;
  $('flip').onclick=()=>{flipped=!flipped;render();};
  $('undo').onclick=()=>{game.undoTurn(human);selected=null;claimed=false;save();render();message('Previous turn restored.');};
  $('resume').onclick=engineTurn;
  $('stop').onclick=()=>{cancel=true;message('Stopping after the current command…');};
  $('claim').onclick=()=>{claimed=true;save();render();message('Draw claimed.');};
  $('download').onclick=()=>{
    const result=claimed?'1/2-1/2':game.outcome()?.result||'*';
    const url=URL.createObjectURL(new Blob([game.pgn(result)],{type:'application/x-chess-pgn'}));
    const a=document.createElement('a');a.href=url;a.download='fpga-chess.pgn';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
  };
  restore();render();connect();
})();
