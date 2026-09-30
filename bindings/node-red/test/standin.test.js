'use strict';
// Every node against a stand-in for the C ABI (bindings/julia/test/stub/licd_stub.c,
// one imaginary dongle held in memory), in a Node-RED runtime started by
// node-red-node-test-helper. The stand-in is compiled with the C compiler on the
// path (cc, gcc, clang, zig cc or cl) unless KEYNUB_LICDONGLE_LIBRARY names one;
// KEYNUB_SDK_ROOT names the SDK sources when the test does not run inside a clone.
//
//     npm install && npm test        (in bindings/node-red)

const test = require('node:test');
const assert = require('node:assert');
const childProcess = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const SERIAL = '04A1B2C3D4E5F6';
const FACTORY_KEY = Buffer.from([0x30, 0x10, 0x01, 0x02, 0x03]);

function sdkRoot() {
  if (process.env.KEYNUB_SDK_ROOT) {
    return process.env.KEYNUB_SDK_ROOT;
  }
  for (let dir = __dirname; ; dir = path.dirname(dir)) {
    if (fs.existsSync(path.join(dir, 'bindings', 'flat', 'licd_flat.c'))) {
      return dir;
    }
    if (path.dirname(dir) === dir) {
      throw new Error('the SDK sources were not found above this test; set KEYNUB_SDK_ROOT');
    }
  }
}

function buildStandIn() {
  const root = sdkRoot();
  const windows = process.platform === 'win32';
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'keynub-node-red-'));
  const output = path.join(tmp, windows ? 'keynub_licdongle_standin.dll'
    : process.platform === 'darwin' ? 'libkeynub_licdongle_standin.dylib' : 'libkeynub_licdongle_standin.so');
  let include = path.join(root, 'core', 'include');
  if (!fs.existsSync(path.join(include, 'licdongle.h'))) {
    include = path.join(root, 'include');
  }
  const source = path.join(root, 'bindings', 'julia', 'test', 'stub', 'licd_stub.c');
  const gcc = ['-shared', '-O1', '-DLICD_BUILD_SHARED', `-I${include}`, '-o', output, source];
  if (!windows) {
    gcc.push('-fPIC');
  }
  const cl = ['/nologo', '/LD', '/O1', '/DLICD_BUILD_SHARED', `/I${include}`, `/Fe:${output}`, source];
  for (const [command, ...args] of [['cc', ...gcc], ['gcc', ...gcc], ['clang', ...gcc], ['zig', 'cc', ...gcc], ['cl', ...cl]]) {
    const r = childProcess.spawnSync(command, args, { cwd: tmp, stdio: 'ignore' });
    if (r.status === 0 && fs.existsSync(output)) {
      return { library: output, tmp };
    }
  }
  throw new Error('the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path');
}

// The library must be named before @keynub/licdongle loads it.
let built = null;
if (!process.env.KEYNUB_LICDONGLE_LIBRARY) {
  built = buildStandIn();
  process.env.KEYNUB_LICDONGLE_LIBRARY = built.library;
}
const keyFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'keynub-node-red-key-')), 'factory.der');
fs.writeFileSync(keyFile, FACTORY_KEY);

const helper = require('node-red-node-test-helper');
const keynubNodes = require('../nodes/keynub.js');
// The Catch node from Node-RED's core set, so a flow can receive what a node reports.
const catchNode = require('@node-red/nodes/core/common/25-catch.js');

helper.init(require.resolve('node-red'));

// A flow of one dongle configuration, the node under test and a helper node
// per output; returns the nodes once the flow runs.
function flow(node, withKey = true) {
  const outputs = node.type === 'keynub-genuine' ? 2 : 1;
  const wires = [];
  const nodes = [{ id: 'd1', type: 'keynub-dongle', serial: '' }];
  for (let i = 0; i < outputs; i++) {
    nodes.push({ id: 'out' + i, type: 'helper' });
    wires.push(['out' + i]);
  }
  nodes.push({ id: 'n1', dongle: 'd1', wires, ...node });
  nodes.push({ id: 'c1', type: 'catch', scope: ['n1'], wires: [['caught']] });
  nodes.push({ id: 'caught', type: 'helper' });
  const credentials = withKey ? { d1: { writeKeyFile: keyFile } } : {};
  return new Promise((resolve) => helper.load([catchNode, keynubNodes], nodes, credentials, () => {
    // One listener per output for the flow's life: a Node-RED node keeps every
    // input handler it is given, so a listener per message would pile up.
    const result = { n1: helper.getNode('n1'), waiting: null };
    const answer = (port) => (m) => {
      const w = result.waiting;
      result.waiting = null;
      if (w) {
        w(port, m);
      }
    };
    [helper.getNode('out0'), helper.getNode('out1')].forEach((o, i) => o && o.on('input', answer(i)));
    helper.getNode('caught').on('input', answer('caught'));
    resolve(result);
  }));
}

// Sends a message and resolves with the first output that answers: [port, msg].
function send(nodes, msg) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      nodes.waiting = null;
      reject(new Error('no output for ' + JSON.stringify(msg) + ' to ' + nodes.n1.type));
    }, 5000);
    nodes.waiting = (port, m) => { clearTimeout(timer); resolve([port, m]); };
    nodes.n1.receive(msg);
  });
}

test('keynub nodes against the ABI stand-in', async (t) => {
  await new Promise((resolve) => helper.startServer(resolve));
  t.after(async () => {
    await new Promise((resolve) => helper.stopServer(resolve));
    // Windows keeps the loaded stand-in locked until the process exits.
    for (const dir of [built && built.tmp, path.dirname(keyFile)]) {
      try {
        if (dir) {
          fs.rmSync(dir, { recursive: true, force: true });
        }
      } catch (_) { /* left to the temporary folder's own cleanup */ }
    }
  });
  t.afterEach(async () => { await helper.unload(); });

  await t.test('keynub-genuine: output 1 for a genuine dongle', async () => {
    const nodes = await flow({ type: 'keynub-genuine' });
    const [port, msg] = await send(nodes, { payload: 'go' });
    assert.strictEqual(port, 0);
    assert.deepStrictEqual(msg.payload, { genuine: true, serial: SERIAL, provisionedDate: '2026-08-15' });
  });

  await t.test('keynub-genuine: output 2 when the dongle is missing', async () => {
    const nodes = await flow({ type: 'keynub-genuine' });
    helper.getNode('d1').serial = 'nope';
    const [port, msg] = await send(nodes, {});
    assert.strictEqual(port, 1);
    assert.strictEqual(msg.payload.genuine, false);
    assert.strictEqual(msg.payload.code, 'KEYNUB_NO_DEVICE');
  });

  await t.test('keynub-record: write, list, read, erase', async () => {
    let nodes = await flow({ type: 'keynub-record', action: 'write', record: 'lic' });
    const [p1] = await send(nodes, { payload: 'licence-text' });
    assert.strictEqual(p1, 0);
    // The stand-in keeps records per opened dongle, and the configuration keeps
    // the dongle open, so the same flow's node sees what it wrote.
    const d1 = helper.getNode('d1');
    const s = d1.withSession(false, (session) => session.readRecord('lic').toString('utf8'));
    assert.strictEqual(s, 'licence-text');
    nodes.n1.receive({ payload: { a: 1 }, topic: 'ignored-because-configured' });
    await new Promise((r) => setTimeout(r, 50));
    assert.strictEqual(d1.withSession(false, (session) => session.readRecord('lic').toString()), '{"a":1}');
    await helper.unload();

    nodes = await flow({ type: 'keynub-record', action: 'list' });
    const [, listed] = await send(nodes, {});
    assert.deepStrictEqual(listed.payload, []);
    await helper.unload();

    nodes = await flow({ type: 'keynub-record', action: 'read', record: '', output: 'string' });
    helper.getNode('d1').withSession(true, (session) => session.writeRecord('cfg', 'cfgdata'));
    const [, read] = await send(nodes, { topic: 'cfg' });
    assert.strictEqual(read.payload, 'cfgdata');
    const [where, missing] = await send(nodes, { topic: 'nope' });
    assert.strictEqual(where, 'caught');
    assert.strictEqual(missing.keynub.code, 'KEYNUB_RECORD_NOT_FOUND');
    const [noName, err] = await send(nodes, {});
    assert.strictEqual(noName, 'caught');
    assert.match(err.error.message, /no record name/);
    await helper.unload();

    nodes = await flow({ type: 'keynub-record', action: 'erase', record: 'cfg' });
    helper.getNode('d1').withSession(true, (session) => session.writeRecord('cfg', 'x'));
    const [erased] = await send(nodes, {});
    assert.strictEqual(erased, 0);
    assert.deepStrictEqual(helper.getNode('d1').withSession(false, (session) => session.listRecords()), []);
  });

  await t.test('keynub-record: writing without the write key fails', async () => {
    const nodes = await flow({ type: 'keynub-record', action: 'write', record: 'lic' }, false);
    const [where, msg] = await send(nodes, { payload: 'x' });
    assert.strictEqual(where, 'caught');
    assert.match(msg.error.message, /write key/);
  });

  await t.test('keynub-counter: read and increment', async () => {
    let nodes = await flow({ type: 'keynub-counter', action: 'read', counter: 0 });
    const [, before] = await send(nodes, {});
    assert.strictEqual(before.payload, 0);
    await helper.unload();
    nodes = await flow({ type: 'keynub-counter', action: 'increment', counter: 0 });
    const [, after] = await send(nodes, {});
    assert.strictEqual(after.payload, 1);
    const [, second] = await send(nodes, { counter: 1 });
    assert.strictEqual(second.counter, 1);
    assert.strictEqual(second.payload, 1);
    const [where, bad] = await send(nodes, { counter: 7 });
    assert.strictEqual(where, 'caught');
    assert.strictEqual(bad.keynub.code, 'KEYNUB_RANGE');
  });

  await t.test('keynub-crypto: encrypt, then decrypt, both scopes', async () => {
    for (const scope of ['developer', 'device']) {
      let nodes = await flow({ type: 'keynub-crypto', action: 'encrypt', scope });
      const [, sealed] = await send(nodes, { payload: { threshold: 42 } });
      assert.ok(Buffer.isBuffer(sealed.payload));
      assert.strictEqual(sealed.payload[0], scope === 'device' ? 0 : 1);
      await helper.unload();
      nodes = await flow({ type: 'keynub-crypto', action: 'decrypt', output: 'string' });
      const [, plain] = await send(nodes, { payload: sealed.payload });
      assert.strictEqual(plain.payload, '{"threshold":42}');
      const tampered = Buffer.from(sealed.payload);
      tampered[tampered.length - 1] ^= 1;
      const [where, bad] = await send(nodes, { payload: tampered });
      assert.strictEqual(where, 'caught');
      assert.strictEqual(bad.keynub.code, 'KEYNUB_TAG_MISMATCH');
      await helper.unload();
    }
  });

  await t.test('the example flow loads', async () => {
    const example = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'examples', 'verify-and-read.json'), 'utf8'));
    const types = new Set(example.map((n) => n.type));
    for (const type of ['keynub-dongle', 'keynub-genuine', 'keynub-record']) {
      assert.ok(types.has(type), type);
    }
  });
});

