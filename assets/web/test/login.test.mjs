import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const html = readFileSync(new URL('../login.html', import.meta.url), 'utf8');
const script = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];

function loginPage({ status = 200, pathname = '/' } = {}) {
  let submit;
  let request;
  let reloaded = false;
  let destination;
  const input = { value: 'test-access-key', focus() {} };
  const button = { disabled: false };
  const error = { textContent: '' };
  const elements = {
    'login-form': { addEventListener: (_, handler) => { submit = handler; } },
    'access-key': input,
    submit: button,
    error,
  };
  runInNewContext(script, {
    document: { getElementById: (id) => elements[id] },
    location: {
      pathname,
      hash: '#t=fixed-token&ro=1',
      reload() { reloaded = true; },
      replace(url) { destination = url; },
    },
    async fetch(url, options) {
      request = { url, ...options };
      return { status, ok: status === 200 };
    },
  });
  return {
    submit: () => submit({ preventDefault() {} }),
    input, button, error,
    result: () => ({ request, reloaded, destination }),
  };
}

test('密钥通过后刷新根路径，重新向服务端请求受保护页面', async () => {
  const page = loginPage();
  await page.submit();
  const { request, reloaded, destination } = page.result();
  assert.equal(reloaded, true);
  assert.equal(destination, undefined);
  assert.equal(page.input.value, '');
  assert.equal(request.url, '/auth');
  assert.equal(request.method, 'POST');
  assert.deepEqual(JSON.parse(request.body), { key: 'test-access-key' });
  assert.equal(request.credentials, 'same-origin');
});

test('从独立登录路径进入时保留 token 及只读参数', async () => {
  for (const pathname of ['/login.html', '/index.html']) {
    const page = loginPage({ pathname });
    await page.submit();
    assert.equal(page.result().destination, '/#t=fixed-token&ro=1');
  }
});

test('错误密钥显示提示并允许重试，始终停留在登录页', async () => {
  const page = loginPage({ status: 401 });
  await page.submit();
  assert.match(page.error.textContent, /访问密钥不正确/);
  assert.equal(page.button.disabled, false);
  assert.equal(page.result().reloaded, false);
  assert.equal(page.result().destination, undefined);
});
