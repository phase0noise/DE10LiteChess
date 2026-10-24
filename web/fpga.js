/* Host-side transport and verification only. Never select an engine move here. */
(function(root){
  'use strict';
  const hex=bytes=>Array.from(bytes,b=>b.toString(16).padStart(2,'0')).join('');
  const unhex=text=>{
    if(typeof text!=='string'||text.length%2||!/^[0-9a-f]*$/i.test(text)) throw Error('Invalid Pico reply.');
    return Uint8Array.from(text.match(/../g)||[],b=>parseInt(b,16));
  };
  const u16=(a,i)=>(a[i]<<8)|a[i+1];
  const i16=(a,i)=>{const n=u16(a,i);return n&0x8000?n-0x10000:n;};
  const u32=(a,i)=>((a[i]*0x1000000)+(a[i+1]<<16)+(a[i+2]<<8)+a[i+3])>>>0;
  const same=(a,b)=>a.length===b.length&&Array.from(a).every((v,i)=>v===b[i]);
  class Fpga {
    constructor(fetcher=(...args)=>fetch(...args)) {this.fetcher=fetcher;this.queue=Promise.resolve();}
    command(sub,data=[]) {
      const run=async()=>{
        const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),5000);
        try {
          const response=await this.fetcher('/api/command',{method:'POST',headers:{'Content-Type':'text/plain'},body:hex([sub,...data]),signal:controller.signal,cache:'no-store'});
          const value=await response.json();
          if(!response.ok) throw Error(value.error||`Pico HTTP ${response.status}`);
          if(value.status!==0) throw Error(value.status===3?'FPGA is busy or its position changed. Reconnect and retry.':`FPGA command ${sub} failed (status ${value.status}).`);
          return unhex(value.payload);
        } finally {clearTimeout(timer);}
      };
      const task=this.queue.catch(()=>{}).then(run);this.queue=task;return task;
    }
    async status() {
      const a=await this.command(0);
      if(a.length!==32||String.fromCharCode(...a.slice(0,4))!=='SCF1'||a[15]<3) throw Error('Program the DE10-Lite chess image first.');
      this.version=a[15];
      return {busy:!!a[4],done:!!a[5],check:!!a[6],turn:a[7],count:u16(a,8),move:u16(a,10),score:i16(a,12),state:a[14],cycles:u32(a,16),generation:u32(a,20),version:a[15],searchDepth:a[15]>=4?a[28]:0,completedDepth:a[15]>=4?a[29]:0};
    }
    async setDepth(depth,timeSeconds=10) {
      if(![0,2,3,4,5,6].includes(depth)) throw Error('Unsupported search depth.');
      if(!Number.isInteger(timeSeconds)||timeSeconds<1||timeSeconds>60) throw Error('Think time must be 1 to 60 seconds.');
      if(this.version===undefined) await this.status();
      if(depth>3&&this.version<4) throw Error('Load the expanded DE10-Lite FPGA image to use deeper search.');
      const policy=await this.command(12,[0]);
      if(policy.length!==64) throw Error('Invalid policy page.');
      policy[10]=depth;
      if(this.version>=4) policy[40]=timeSeconds;
      await this.command(13,[0,...policy]);
    }
    async telemetry() {
      const a=await this.command(18);
      if(![10,20].includes(a.length)) throw Error('Invalid FPGA search telemetry.');
      return {nodes:u32(a,0),cutoffs:u32(a,4),targetDepth:a[8],quiescence:a[9],
        depth:a.length===20?a[10]:a[8],cacheEnabled:a.length===20?!!(a[11]&2):false,
        budgetExpired:a.length===20&&!!(a[11]&1),
        cacheHits:a.length===20?u32(a,12):0,cacheStores:a.length===20?u32(a,16):0};
    }
    async evaluate(game,{cancelled=()=>false,progress=()=>{},stage=()=>{},depth=5,timeSeconds=10}={}) {
      const position=game.position,expected=position.positionBytes(),legal=position.legalMoves();
      try {
        stage('upload');
        await this.command(3);await this.setDepth(depth,timeSeconds);await this.command(1,expected);
        const recent=game.history.slice(-8).reverse().map(h=>h.move);
        await this.command(17,[recent.length,...recent.flatMap(m=>[m>>8,m&255])]);
        if(cancelled()) throw Error('Stopped.');
        await this.command(2);stage('field');
        const deadline=Date.now()+180000;
        let status,telemetry=null,lastSample=0;
        do {
          if(cancelled()) throw Error('Stopped.');
          if(Date.now()>deadline) throw Error('FPGA search timed out. Try a shorter lookahead.');
          status=await this.status();
          const sampled=Date.now()-lastSample>=500||(!status.busy&&status.done);
          if(sampled) {telemetry=await this.telemetry();lastSample=Date.now();}
          progress({...status,telemetry,sampled});
          if(!status.busy&&status.done) break;
          await new Promise(resolve=>setTimeout(resolve,120));
        } while(true);
        stage('verify');
        if(status.count>256) throw Error('Invalid FPGA candidate count.');
        if(!same(await this.command(5),expected)) throw Error('The FPGA position changed during search.');
        const actual=[],candidates=[];
        for(let page=0;page<Math.ceil(status.count/16);page++) {
          const a=await this.command(7,[page]);
          if(a.length!==64) throw Error('Invalid FPGA candidate page.');
          for(let i=0;i<16&&actual.length<status.count;i++) {
            const move=u16(a,i*4);actual.push(move);candidates.push({move,score:i16(a,i*4+2)});
          }
        }
        const sorted=values=>values.slice().sort((a,b)=>a-b);
        if(!same(sorted(actual),sorted(legal))||new Set(actual).size!==actual.length) throw Error('FPGA legal moves disagree with the browser. No move was played.');
        if(!legal.length) return {move:null,cycles:status.cycles,nodes:0};
        if(!actual.includes(status.move)) throw Error('FPGA selected a move absent from its legal set.');
        const field=await this.command(4);
        if(field.length!==80) throw Error('Invalid FPGA field snapshot.');
        const index=actual.indexOf(status.move),explanations=await this.command(14,[Math.floor(index/4)]),offset=(index%4)*18;
        if(explanations.length!==72||u16(explanations,offset)!==status.move||i16(explanations,offset+2)!==status.score) throw Error('FPGA explanation does not match its selected move.');
        const parts=Array.from({length:7},(_,i)=>i16(explanations,offset+4+i*2));
        if(cancelled()) throw Error('Stopped.');
        stage('commit');
        const g=status.generation,m=status.move;
        await this.command(11,[g>>>24,(g>>>16)&255,(g>>>8)&255,g&255,m>>8,m&255]);
        const result=position.clone().make(m).positionBytes();
        if(!same(await this.command(5),result)) throw Error('FPGA move commit did not match the expected board. Reconnect to retry.');
        return {...telemetry,move:m,cycles:status.cycles,score:status.score,candidates,parts,
          field:Array.from(field.slice(16),n=>n>127?n-256:n),
          attacks:{white:Array.from(field.slice(0,8)),black:Array.from(field.slice(8,16))}};
      } catch(error) {
        try {await this.command(3);} catch(_) {}
        throw error;
      }
    }
  }
  if(typeof module!=='undefined'&&module.exports) module.exports={Fpga,hex,unhex};
  root.FpgaChess={Fpga};
})(typeof globalThis!=='undefined'?globalThis:this);
