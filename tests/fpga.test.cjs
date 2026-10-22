'use strict';
const assert=require('node:assert/strict');
const {Game,uci,decode}=require('../web/chess.js');
const {Fpga,hex,unhex}=require('../web/fpga.js');
assert.deepEqual(Array.from(unhex(hex([0,255,1,128]))),[0,255,1,128]);
assert.throws(()=>unhex('xz'));
function fixture({badLegal=false,badBoard=false,timeout=false}={}) {
  const game=new Game(),calls=[];let position=game.position.clone(),generation=2,done=false,stopped=false;
  const fetcher=async(url,request)=>{
    const a=unhex(request.body),sub=a[0];calls.push(sub);
    let out=[];
    switch(sub) {
      case 0: {
        out=new Uint8Array(32);out.set([83,67,70,49]);out[4]=timeout?1:0;out[5]=done?1:0;out[15]=3;
        const moves=position.legalMoves(),best=moves.find(m=>uci(m)==='e2e4')??moves[0];
        out[8]=moves.length>>8;out[9]=moves.length&255;out[10]=best>>8;out[11]=best&255;
        out[20]=generation>>>24;out[21]=(generation>>>16)&255;out[22]=(generation>>>8)&255;out[23]=generation&255;break;
      }
      case 1: generation++;break;
      case 2: done=true;break;
      case 3: stopped=true;done=false;break;
      case 5: out=position.positionBytes();if(badBoard)out[0]^=1;break;
      case 7: {
        out=new Uint8Array(64);const moves=position.legalMoves();
        for(let i=0;i<16;i++) {const move=moves[a[1]*16+i]||0;out[i*4]=move>>8;out[i*4+1]=move&255;}
        if(badLegal) out[0]=127;break;
      }
      case 11: {
        const move=(a[5]<<8)|a[6];assert.equal(move,position.legalMoves().find(m=>uci(m)==='e2e4'));
        position.make(move);break;
      }
      case 12: out=new Uint8Array(64);break;
      case 18: out=Uint8Array.from([0,0,1,0,0,0,0,4,3,1]);break;
      default:out=[0];
    }
    return {ok:true,json:async()=>({status:0,payload:hex(out)})};
  };
  return {game,calls,device:new Fpga(fetcher),stopped:()=>stopped};
}
(async()=>{
  const good=fixture();const evaluation=await good.device.evaluate(good.game);
  assert.equal(uci(evaluation.move),'e2e4');assert.equal(evaluation.nodes,256);
  assert(good.calls.includes(7));assert(good.calls.includes(11));
  for(const options of [{badLegal:true},{badBoard:true}]) {
    const f=fixture(options);await assert.rejects(()=>f.device.evaluate(f.game));
    assert(!f.calls.includes(11),'A failed independent check must prevent FPGA commit');assert(f.stopped());
  }
  const cancelled=fixture();await assert.rejects(()=>cancelled.device.evaluate(cancelled.game,{cancelled:()=>true}),/Stopped/);
  assert(!cancelled.calls.includes(11));
  const broken=new Fpga(async()=>({ok:false,json:async()=>({error:'No FPGA reply'})}));
  await assert.rejects(()=>broken.status(),/No FPGA reply/);
  console.log('Transport, legal-set verification, board readback, commit guards, cancellation and disconnected hardware checks passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
