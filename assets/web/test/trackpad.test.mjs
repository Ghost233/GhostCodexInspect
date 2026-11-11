import test from 'node:test';
import assert from 'node:assert/strict';
import { Trackpad } from '../js/trackpad.js';

class Element {
  constructor() { this.style={};this.listeners={};this.classList={toggle(){}}; }
  appendChild() {}
  addEventListener(name,fn) { this.listeners[name]=fn; }
  setPointerCapture() {}
  getBoundingClientRect() { return {left:10,top:20,width:300,height:200}; }
  emit(name,options={}) { this.listeners[name]({pointerId:1,pointerType:'touch',clientX:30,clientY:40,preventDefault(){},...options}); }
}
globalThis.document={createElement:()=>new Element()};
globalThis.ResizeObserver=class{observe(){}};

function setup(t,editable=()=>false) {
  let now=1000,scale=2;
  t.mock.method(performance,'now',()=>now);
  const target=new Element(),sent=[],focused=[];
  const pad=new Trackpad(target,{getRect:()=>target.getBoundingClientRect(),
    toSource:({clientX,clientY})=>({x:(clientX-10)*scale,y:(clientY-20)*scale}),
    send:(m)=>sent.push(m),keyboard:{focus:(p)=>focused.push(p),blur(){}},isEditable:editable});
  pad.setMode('trackpad');
  t.after(()=>pad.cancel());
  return {pad,target,sent,focused,advance:(ms)=>{now+=ms;},zoom:(v)=>{scale=v;}};
}

test('滑动只移动光标，抬手再滑动接着移动，不按下左键',t=>{
  const {target,sent}=setup(t);
  target.emit('pointerdown');target.emit('pointermove',{clientX:70,clientY:60});target.emit('pointerup');
  assert.deepEqual(sent.map(m=>m.action),['move']);
  assert.equal(sent[0].buttons,0);
  const first=sent[0].x;
  target.emit('pointerdown',{clientX:20});target.emit('pointermove',{clientX:40});target.emit('pointerup');
  assert.ok(sent[1].x>first);
});

test('轻点在光标位置点击，并按光标命中的输入框唤起键盘',t=>{
  const {target,sent,focused}=setup(t,p=>p.x>200);
  target.emit('pointerdown');target.emit('pointerup');
  assert.deepEqual(sent.map(m=>m.action),['down','up']);
  assert.equal(sent[0].x,299);
  assert.equal(sent[0].y,199);
  assert.equal(focused[0].y,119.5);
});

test('双击后按住移动保持左键，抬手释放',t=>{
  const {target,sent,advance}=setup(t);
  target.emit('pointerdown');target.emit('pointerup');advance(100);
  target.emit('pointerdown');target.emit('pointermove',{clientX:80});target.emit('pointerup');
  assert.equal(sent[2].clickCount,2);
  assert.equal(sent[3].action,'move');assert.equal(sent[3].buttons,1);
  assert.equal(sent.at(-1).action,'up');assert.equal(sent.at(-1).buttons,0);
});

test('双指轻点只产生右键，双指滑动产生滚轮且不移动光标',t=>{
  const {target,sent}=setup(t);
  target.emit('pointerdown');target.emit('pointerdown',{pointerId:2});
  target.emit('pointerup');target.emit('pointerup',{pointerId:2});
  assert.deepEqual(sent.map(m=>[m.action,m.button]),[['down','right'],['up','right']]);
  sent.length=0;
  target.emit('pointerdown');target.emit('pointerdown',{pointerId:2});
  target.emit('pointermove',{clientY:80});target.emit('pointermove',{pointerId:2,clientY:80});
  target.emit('pointerup');target.emit('pointerup',{pointerId:2});
  assert.equal(sent.length,2);
  assert.ok(sent.every(m=>m.kind==='wheel'&&m.deltaY<0&&m.x===299));
});

for (const scale of [0.5,1,2]) {
  test(`模拟鼠标：双指以三倍速度立即滚动，缩放 ${scale} 和光标停在边缘均不减速`,t=>{
    const {pad,target,sent,zoom}=setup(t);
    zoom(scale);
    const project=pad.toSource;
    pad.toSource=e=>e.clientX>309 || e.clientY>219 ? null : project(e);
    pad.position={x:1,y:1};
    target.emit('pointerdown');
    target.emit('pointerdown',{pointerId:2,clientX:130});
    target.emit('pointermove',{clientX:50,clientY:80});
    assert.equal(sent.length,1);
    target.emit('pointermove',{pointerId:2,clientX:150,clientY:80});
    assert.equal(sent.length,2);
    assert.ok(sent.every(m=>m.kind==='wheel'));
    assert.equal(sent.reduce((sum,m)=>sum+m.deltaX,0),-60*scale);
    assert.equal(sent.reduce((sum,m)=>sum+m.deltaY,0),-120*scale);
    assert.ok(sent.every(m=>m.x===299*scale && m.y===199*scale));
    target.emit('pointerup');target.emit('pointerup',{pointerId:2});
    assert.equal(sent.length,2,'抬手后不能继续补发旧滚动事件');
  });
}

test('拖拽锁定持续到按钮释放，取消手势和切换模式均释放按键',t=>{
  const {pad,target,sent}=setup(t);
  pad.toggleDrag();target.emit('pointerdown');target.emit('pointermove',{clientX:80});target.emit('pointerup');
  assert.equal(pad.dragLocked,true);assert.equal(sent.at(-1).buttons,1);
  pad.toggleDrag();assert.equal(sent.at(-1).action,'up');assert.equal(sent.at(-1).buttons,0);
  pad.toggleDrag();target.emit('pointerdown');target.emit('pointercancel');
  assert.equal(pad.dragLocked,false);assert.equal(sent.at(-1).action,'up');
  pad.toggleDrag();pad.setMode('direct');
  assert.equal(sent.at(-1).buttons,0);
});

test('缩放改变后重新投影坐标，光标保持原来屏幕位置',t=>{
  const {pad,zoom}=setup(t);
  const before=pad.point();zoom(4);const after=pad.point();
  assert.equal(after.x,before.x);assert.equal(after.source.x,before.source.x*2);
});

test('重绘 iframe 获取焦点不取消手势，真正离开页面仍释放按键',t=>{
  const listeners={};
  const originalListener=globalThis.addEventListener, originalFocus=document.hasFocus;
  let focused=true;
  globalThis.addEventListener=(type,fn)=>{listeners[type]=fn;};
  document.hasFocus=()=>focused;
  t.after(()=>{globalThis.addEventListener=originalListener;document.hasFocus=originalFocus;});
  const {pad,sent}=setup(t);
  pad.lastTap=1000;
  listeners.blur();
  assert.equal(pad.lastTap,1000,'焦点仍在同一页面内，不应丢掉双击状态');
  pad.toggleDrag();
  focused=false;
  listeners.blur();
  assert.equal(pad.pressed,false);
  assert.equal(sent.at(-1).action,'up');
  focused=true;
  pad.toggleDrag();
  listeners.pagehide();
  assert.equal(pad.pressed,false);
});
