'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');
const {Position,Game,uci}=require('../web/chess.js');
function perft(p,depth) {if(!depth)return 1;let n=0;for(const m of p.legalMoves())n+=perft(p.clone().make(m),depth-1);return n;}
assert.equal(perft(new Position(),1),20);
assert.equal(perft(new Position(),2),400);
assert.equal(perft(new Position(),3),8902);
const kiwipete=new Position('r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1');
assert.equal(perft(kiwipete,1),48);assert.equal(perft(kiwipete,2),2039);
const file=process.argv[2];
if(file) {
  const fixtures=JSON.parse(fs.readFileSync(file,'utf8'));
  for(const [i,f] of fixtures.entries()) {
    const p=new Position(f.fen);
    assert.deepEqual(p.legalMoves().map(uci).sort(),f.moves.map(x=>x.uci).sort(),`legal set ${i}: ${f.fen}`);
    assert.equal(p.inCheck(),f.check,`check at ${i}`);
    assert.equal(p.insufficient(),f.insufficient,`insufficient material at ${i}`);
    assert.deepEqual(Array.from(p.positionBytes()),f.bytes,`position bytes at ${i}`);
    for(const expected of f.moves) {
      const move=p.legalMoves().find(m=>uci(m)===expected.uci);
      assert.equal(p.san(move),expected.san,`SAN ${i}: ${expected.uci}`);
      assert.equal(p.clone().make(move).fen(),expected.fen,`move result ${i}: ${expected.uci}`);
    }
  }
  console.log(`Matched python-chess on ${fixtures.length} positions: all legal moves, SAN, resulting FEN, metadata and checks.`);
}
const game=new Game();
for(const text of ['g1f3','g8f6','f3g1','f6g8','g1f3','g8f6','f3g1','f6g8']) game.push(game.position.legalMoves().find(m=>uci(m)===text));
assert.equal(game.repetition(),3);assert(game.canClaim());
assert.equal(game.outcome(),null);
game.undoTurn(0);assert.equal(game.history.length,6);assert.equal(game.position.turn,0);
game.push(game.position.legalMoves().find(m=>uci(m)==='f3g1'));
assert.equal(game.repetition(),2);assert(game.canClaim(),'An intended move can produce the third repetition');
const ep=new Position('4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1');
assert.notEqual(ep.key(),new Position(ep.fen().replace(' d6 ',' - ')).key());
const pinnedEp=new Position('4r1k1/8/8/3pP3/8/8/8/4K3 w - d6 0 1');
assert.equal(pinnedEp.key(),new Position(pinnedEp.fen().replace(' d6 ',' - ')).key());
console.log('Rules, perft, repetition, en passant keys and undo passed.');
