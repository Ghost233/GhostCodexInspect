import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const app = readFileSync(new URL('../js/app.js', import.meta.url), 'utf8')
  .replace(/^import .*;$/gm, '').replace(/^main\(\);$/m, '');

test('等待宿主回显期间，相同尺寸只发一次，避免 DOM 重建循环', () => {
  const pane = { clientWidth: 390, clientHeight: 740, classList: { contains: () => false } };
  const sent = [];
  let pending;
  const context = {
    window: { devicePixelRatio: 1, addEventListener() {} },
    document: { getElementById: () => pane },
    ResizeObserver: class { observe() {} },
    setTimeout(fn) { pending = fn; return 1; }, clearTimeout() {},
    client: { setViewport: (...args) => sent.push(args) },
  };
  runInNewContext(app + `
    currentMode = 'video';
    setupViewportSync(client, {}, {viewportWidth:1280,viewportHeight:720}, false);
    viewportSync();
  `, context);
  pending();
  runInNewContext('viewportSync();', context);
  pending();
  assert.deepEqual(sent, [[390, 740, 1]]);
  pane.clientWidth = 400;
  runInNewContext('viewportSync();', context);
  pending();
  assert.deepEqual(sent.at(-1), [400, 740, 1]);
});

for (const zoom of [10, 50, 100, 200]) {
  test(`DPR=3、${zoom}% 内容缩放保持手机物理像素密度`, () => {
    let callback;
    const sent = [];
    const pane = { clientWidth: 390, clientHeight: 740, classList: { contains: () => false } };
    runInNewContext(app + `
      currentMode='video'; currentZoom=${zoom};
      setupViewportSync(client, {}, {viewportWidth:1280,viewportHeight:720}, false);
      viewportSync();
    `, {
      window: { devicePixelRatio: 3, addEventListener() {} },
      document: { getElementById: () => pane },
      ResizeObserver: class { observe() {} },
      setTimeout(fn) { callback = fn; return 1; }, clearTimeout() {},
      client: { setViewport: (...args) => sent.push(args) },
    });
    callback();
    assert.equal(sent.length, 1);
    const [width,height,density] = sent[0];
    assert.equal(width, Math.round(390*100/zoom));
    assert.equal(height, Math.round(740*100/zoom));
    assert.ok(Math.abs(width*density-1170) <= 3, `实际像素宽度 ${width*density}`);
    assert.ok(Math.abs(height*density-2220) <= 3, `实际像素高度 ${height*density}`);
  });
}

test('逻辑尺寸已匹配仍补齐 DPR，确认后不重复发送，密度变化会重新同步', () => {
  let timer;
  let resize;
  const sent=[];
  const win={devicePixelRatio:3,addEventListener:(_,fn)=>{resize=fn;}};
  const view={viewportWidth:390,viewportHeight:740,deviceScaleFactor:1};
  const context={
    window:win,view,
    document:{getElementById:()=>({clientWidth:390,clientHeight:740,classList:{contains:()=>false}})},
    ResizeObserver:class{observe(){}},setTimeout(fn){timer=fn;return 1;},clearTimeout(){},
    client:{setViewport:(...args)=>sent.push(args)},
  };
  runInNewContext(app+`currentMode='video';setupViewportSync(client,{},view,false);viewportSync();`,context);
  timer();
  assert.deepEqual(sent,[[390,740,3]]);
  view.deviceScaleFactor=3;
  runInNewContext('viewportSync();',context);timer();
  assert.equal(sent.length,1);
  win.devicePixelRatio=2;
  resize();timer();
  assert.deepEqual(sent.at(-1),[390,740,2]);
});

test('高 DPR 大屏采集仍受物理像素上限保护', () => {
  let callback;
  let dimensions;
  runInNewContext(app+`currentMode='video';currentZoom=65;setupViewportSync(client,{}, {},false);viewportSync();`,{
    window:{devicePixelRatio:4,addEventListener(){}},
    document:{getElementById:()=>({clientWidth:1400,clientHeight:1601,classList:{contains:()=>false}})},
    ResizeObserver:class{observe(){}},setTimeout(fn){callback=fn;return 1;},clearTimeout(){},
    client:{setViewport:(...args)=>{dimensions=args;}},
  });
  callback();
  const [width,height,scale]=dimensions;
  assert.ok(width*scale<=7680);
  assert.ok(height*scale<=4320);
});
