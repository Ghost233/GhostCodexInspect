import test from 'node:test';
import assert from 'node:assert/strict';
import { KeyboardForwarder, InputCaptureLayer, bindPointerInput } from '../js/input.js';
import { VideoView } from '../js/video.js';

class Element {
  constructor(tagName) {
    this.tagName = tagName;
    this.listeners = new Map();
    this.children = [];
    this.value = '';
    this.style = {};
    this.classList = { add() {}, remove() {}, toggle() {} };
  }
  setAttribute() {}
  appendChild(child) { this.children.push(child); }
  querySelector(tag) { return this.children.find((child) => child.tagName === tag); }
  addEventListener(type, handler) {
    if (!this.listeners.has(type)) this.listeners.set(type, []);
    this.listeners.get(type).push(handler);
  }
  emit(type, init = {}) {
    const event = { type, currentTarget: this, target: this, preventDefault() {}, ...init };
    for (const handler of this.listeners.get(type) || []) handler(event);
  }
  focus() { globalThis.document.activeElement = this; }
  getBoundingClientRect() { return { left: 10, top: 20, width: 300, height: 200 }; }
  setPointerCapture() {}
  releasePointerCapture() {}
}

globalThis.document = { createElement: (tag) => new Element(tag), activeElement: null };
globalThis.ResizeObserver = class { observe() {} };

for (const mode of ['DOM', 'video']) {
  test(`${mode}: 手机触摸普通区域产生完整点击，不展开键盘`, () => {
    document.activeElement = null;
    const host = new Element('div');
    const messages = [];
    const client = { sendInput: (message) => messages.push(message) };
    let target;
    let keyboard;
    if (mode === 'DOM') {
      host.appendChild(new Element('iframe'));
      const capture = new InputCaptureLayer(host, { scale: 0.5 }, client);
      target = capture.overlay;
      keyboard = capture.keyboard;
    } else {
      const view = new VideoView(host, client);
      view.viewportWidth = 600;
      view.viewportHeight = 400;
      target = host;
      keyboard = view._keyboard;
    }
    const touch = { pointerId: 1, pointerType: 'touch', isPrimary: true,
      clientX: 60, clientY: 50, button: 0 };
    target.emit('pointerdown', touch);
    target.emit('pointerup', touch);
    assert.deepEqual(messages, [
      { kind: 'mouse', action: 'down', x: 100, y: 60, button: 'left', clickCount: 1 },
      { kind: 'mouse', action: 'up', x: 100, y: 60, button: 'left', clickCount: 1 },
    ]);
    assert.notEqual(document.activeElement, keyboard.proxy);
  });
}

test('触摸仅在命中输入框时展开键盘，点击普通区域关闭代理焦点', () => {
  const target = new Element('div');
  let focused = false;
  bindPointerInput(target, {
    toSource: (e) => ({ x: e.clientX, y: e.clientY }),
    send() {},
    isEditable: (point) => point.x < 50,
    keyboard: { focus() { focused = true; }, blur() { focused = false; } },
  });
  for (const [x, expected] of [[10, true], [100, false]]) {
    const touch = { pointerId: 1, pointerType: 'touch', isPrimary: true, clientX: x, clientY: 20, button: 0 };
    target.emit('pointerdown', touch);
    target.emit('pointerup', touch);
    assert.equal(focused, expected);
  }
});

function keyboard() {
  const messages = [];
  const forwarder = new KeyboardForwarder(new Element('div'), {
    onText: (text) => messages.push({ kind: 'text', text }),
    onKey: (key) => messages.push({ kind: 'key', key }),
  });
  return { proxy: forwarder.proxy, messages };
}

test('Android 软键盘只发 input 时，正文仍发送到宿主', () => {
  const { proxy, messages } = keyboard();
  proxy.emit('keydown', { key: 'Unidentified', keyCode: 229 });
  proxy.value = 'hello';
  proxy.emit('input', { inputType: 'insertText', data: 'hello' });
  assert.deepEqual(messages, [{ kind: 'text', text: 'hello' }]);
  assert.equal(proxy.value, '');
});

test('手机软键盘退格和换行通过 beforeinput 转发', () => {
  const { proxy, messages } = keyboard();
  proxy.emit('beforeinput', { inputType: 'deleteContentBackward' });
  proxy.emit('beforeinput', { inputType: 'insertLineBreak' });
  assert.deepEqual(messages, [{ kind: 'key', key: 'Backspace' }, { kind: 'key', key: 'Enter' }]);
});

test('中文组合输入提交后，最终 input 不重复发送成字文本', () => {
  const { proxy, messages } = keyboard();
  proxy.emit('compositionstart');
  proxy.value = 'ni';
  proxy.emit('input', { inputType: 'insertCompositionText', data: 'ni', isComposing: true });
  proxy.emit('compositionend', { data: '你好' });
  proxy.emit('input', { inputType: 'insertFromComposition', data: '你好' });
  assert.deepEqual(messages, [{ kind: 'text', text: '你好' }]);
});

test('桌面普通字符和特殊键维持原有键盘转发', () => {
  const { proxy, messages } = keyboard();
  proxy.emit('keydown', { key: 'a' });
  proxy.emit('keydown', { key: 'Enter' });
  assert.deepEqual(messages, [{ kind: 'text', text: 'a' }, { kind: 'key', key: 'Enter' }]);
});

test('触摸取消会释放远程按键，第二根手指不会重复点击', () => {
  const target = new Element('div');
  const messages = [];
  let focused = false;
  bindPointerInput(target, {
    toSource: (e) => e.clientX < 0 ? null : { x: e.clientX, y: e.clientY },
    send: (message) => messages.push(message),
    keyboard: { focus() { focused = true; } },
  });
  const touch = { pointerId: 1, pointerType: 'touch', isPrimary: true,
    clientX: 10, clientY: 20, button: 0 };
  target.emit('pointerdown', touch);
  target.emit('pointerdown', { ...touch, pointerId: 2, isPrimary: false });
  target.emit('pointercancel', { ...touch, clientX: -1 });
  target.emit('lostpointercapture', touch);
  assert.deepEqual(messages.map((m) => m.action), ['down', 'up']);
  assert.equal(focused, false);
});

test('视频 MSE 输入保留鼠标右键，兼容鼠标事件不重复转发', () => {
  const host = new Element('div');
  const messages = [];
  const view = new VideoView(host, { sendInput: (message) => messages.push(message) });
  view._engine = 'mse';
  view.viewportWidth = 600;
  view.viewportHeight = 400;
  const mouse = { pointerId: 1, pointerType: 'mouse', isPrimary: true,
    clientX: 60, clientY: 50, button: 2 };
  host.emit('pointerdown', mouse);
  host.emit('pointerup', mouse);
  host.emit('mousedown', mouse);
  host.emit('mouseup', mouse);
  assert.equal(messages.length, 2);
  assert.equal(messages[0].button, 'right');
  assert.equal(messages[0].x, 100);
  assert.equal(document.activeElement, view._keyboard.proxy);
});

test('不可取消的软键盘换行只转发一次 Enter', () => {
  const { proxy, messages } = keyboard();
  proxy.emit('beforeinput', { inputType: 'insertLineBreak', cancelable: false });
  proxy.value = '\n';
  proxy.emit('input', { inputType: 'insertLineBreak', data: null });
  assert.deepEqual(messages, [{ kind: 'key', key: 'Enter' }]);
  assert.equal(proxy.value, '');
});

test('只读视频不绑定指针事件或键盘代理', () => {
  const host = new Element('div');
  const view = new VideoView(host, { sendInput() { assert.fail('只读模式不能发送输入'); } }, { readOnly: true });
  view.focusKeyboard();
  assert.equal(view._keyboard, null);
  assert.equal(host.listeners.size, 0);
});
