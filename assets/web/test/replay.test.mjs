import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const source=readFileSync(new URL('../js/replay.js',import.meta.url),'utf8')
  .replace(/^import .*;$/gm,'').replace('export class DomReplaySession','class DomReplaySession');

test('手机时钟落后宿主时，首屏不等待手机时间追上宿主', () => {
  let baseline;
  const host = {getBoundingClientRect:()=>({width:0,height:0})};
  runInNewContext(source + `
    const session = new DomReplaySession(host);
    session.handleDomMessage('meta',{type:4,timestamp:100000,data:{width:390,height:782}});
    session.handleDomMessage('full',{type:2,timestamp:100010,data:{}});
  `, {host,Date:{now:()=>1000},window:{addEventListener(){}},
    Replayer:class {startLive(value){baseline=value;}}});
  assert.equal(baseline, 99010);
});
