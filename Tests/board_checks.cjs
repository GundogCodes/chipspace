const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(require('node:path').join(__dirname, '../Web/app.js'), 'utf8');
const code = source.slice(source.indexOf('function partition('), source.indexOf('function renderBoard('));
const ctx = vm.createContext({});
vm.runInContext(code, ctx);
for (const weights of [[1], [1, 1], [40.9, 23.3, 17.3, 13.4, 9.7, 8.4, 7.7], Array.from({length: 80}, (_,i) => 1 + ((i * 37) % 97))]) {
  const total = weights.reduce((a,b)=>a+b,0);
  for (const [width,height] of [[400,280],[1000,390],[320,360]]) {
    const rects = ctx.partition(weights.map(weight=>({weight})),0,0,width,height);
    assert.equal(rects.length, weights.length);
    let area=0;
    for (const r of rects) {
      assert.ok(r.w>0 && r.h>0 && r.x>=-1e-8 && r.y>=-1e-8);
      assert.ok(r.x+r.w<=width+1e-7 && r.y+r.h<=height+1e-7);
      assert.ok(Math.abs(r.w*r.h/(width*height)-r.weight/total)<1e-10);
      area+=r.w*r.h;
    }
    assert.ok(Math.abs(area-width*height)<1e-6);
    for(let i=0;i<rects.length;i++) for(let j=i+1;j<rects.length;j++) {
      const a=rects[i],b=rects[j];
      const overlapX=Math.min(a.x+a.w,b.x+b.w)-Math.max(a.x,b.x);
      const overlapY=Math.min(a.y+a.h,b.y+b.h)-Math.max(a.y,b.y);
      assert.ok(overlapX<1e-7 || overlapY<1e-7);
    }
  }
}
vm.runInContext(source.slice(source.indexOf('const splitPaths ='), source.indexOf('function getBoardTiles(')), ctx);
ctx.children = new Map([['parent', [{id:'a',path:'~/a',bytes:75,category:'caches'},{id:'b',path:'~/b',bytes:75,category:'caches'}]]]);
const parent={id:'parent',path:'~/.cache',bytes:100,category:'caches'};
assert.equal(ctx.frontier(parent).reduce((a,b)=>a+b.weight,0),100);
ctx.children.set('parent',[{id:'a',path:'~/a',bytes:30,category:'caches'}]);
const parts=ctx.frontier(parent);
assert.equal(parts.reduce((a,b)=>a+b.weight,0),100);
assert.equal(parts.find(p=>p.residual).weight,70);
console.log('PASS: proportional rectangle areas, bounds, no overlaps, complete coverage, parent/child normalization, and residual allocation.');
