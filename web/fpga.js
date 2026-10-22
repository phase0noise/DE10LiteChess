/* Host-side transport and verification only. Never select an engine move here. */
(function(root){
  'use strict';
  const hex=bytes=>Array.from(bytes,b=>b.toString(16).padStart(2,'0')).join('');
  const unhex=text=>{
    if(typeof text!=='string'||text.length%2||!/^[0-9a-f]*$/i.test(text)) throw Error('Invalid Pico reply.');
    return Uint8Array.from(text.match(/../g)||[],b=>parseInt(b,16));
  };
  const u16=(a,i)=>(a[i]<<8)|a[i+1];
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
      return {busy:!!a[4],done:!!a[5],check:!!a[6],turn:a[7],count:u16(a,8),move:u16(a,10),cycles:u32(a,16),generation:u32(a,20),version:a[15]};
    }
    async setDepth(depth) {
      if(![0,2,3].includes(depth)) throw Error('Unsupported search depth.');
      const policy=await this.command(12,[0]);
      if(policy.length!==64) throw Error('Invalid policy page.');
      policy[10]=depth;
      await this.command(13,[0,...policy]);
    }
    async evaluate(game,{cancelled=()=>false,progress=()=>{},depth=3}={}) {
      const position=game.position,expected=position.positionBytes(),legal=position.legalMoves();
      await this.command(3);await this.setDepth(depth);await this.command(1,expected);
      const recent=game.history.slice(-8).reverse().map(h=>h.move);
      await this.command(17,[recent.length,...recent.flatMap(m=>[m>>8,m&255])]);
      if(cancelled()) throw Error('Stopped.');
      await this.command(2);
      const deadline=Date.now()+180000;
      let status;
      try {
        do {
          if(cancelled()) throw Error('Stopped.');
          if(Date.now()>deadline) throw Error('FPGA search timed out. Try a shorter lookahead.');
          status=await this.status();progress(status);
          if(!status.busy&&status.done) break;
          await new Promise(resolve=>setTimeout(resolve,120));
        } while(true);
        if(status.count>256) throw Error('Invalid FPGA candidate count.');
        if(!same(await this.command(5),expected)) throw Error('The FPGA position changed during search.');
        const actual=[];
        for(let page=0;page<Math.ceil(status.count/16);page++) {
          const a=await this.command(7,[page]);
          if(a.length!==64) throw Error('Invalid FPGA candidate page.');
          for(let i=0;i<16&&actual.length<status.count;i++) actual.push(u16(a,i*4));
        }
        const sorted=values=>values.slice().sort((a,b)=>a-b);
        if(!same(sorted(actual),sorted(legal))||new Set(actual).size!==actual.length) throw Error('FPGA legal moves disagree with the browser. No move was played.');
        if(!legal.length) return {move:null,cycles:status.cycles,nodes:0};
        if(!actual.includes(status.move)) throw Error('FPGA selected a move absent from its legal set.');
        const telemetry=await this.command(18);
        if(telemetry.length!==10) throw Error('Invalid FPGA search telemetry.');
        if(cancelled()) throw Error('Stopped.');
        const g=status.generation,m=status.move;
        await this.command(11,[g>>>24,(g>>>16)&255,(g>>>8)&255,g&255,m>>8,m&255]);
        const result=position.clone().make(m).positionBytes();
        if(!same(await this.command(5),result)) throw Error('FPGA move commit did not match the expected board. Reconnect to retry.');
        return {move:m,cycles:status.cycles,nodes:u32(telemetry,0)};
      } catch(error) {
        try {await this.command(3);} catch(_) {}
        throw error;
      }
    }
  }
  if(typeof module!=='undefined'&&module.exports) module.exports={Fpga,hex,unhex};
  root.FpgaChess={Fpga};
})(typeof globalThis!=='undefined'?globalThis:this);
