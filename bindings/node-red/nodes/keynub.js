'use strict';
// Node-RED nodes for the KeyNub USB license dongle, over @keynub/licdongle.
//
//   keynub-dongle   configuration: which dongle (first, or by serial) and the
//                   file holding its write key (a credential)
//   keynub-genuine  proves the dongle genuine; output 1 genuine, output 2 not
//   keynub-record   list, read, write or erase license records
//   keynub-counter  read or increment a monotonic counter
//   keynub-crypto   encrypt data that only a dongle can decrypt, or decrypt it
//
// Every operation runs in its own encrypted session, opened and closed around
// it. A failure goes to Node-RED's error handling (a Catch node receives the
// message) with msg.keynub.code set to the SDK's code (KEYNUB_NO_DEVICE,
// KEYNUB_NOT_GENUINE, ...) and msg.keynub.detail to its diagnostic text.

const fs = require('node:fs');
const licd = require('@keynub/licdongle');

module.exports = function register(RED) {
  // --- configuration node: one context and one open dongle ------------------
  function KeynubDongleNode(config) {
    RED.nodes.createNode(this, config);
    this.serial = (config.serial || '').trim() || null;
    let ctx = null;
    let dongle = null;

    const release = () => {
      if (dongle) {
        try { dongle.close(); } catch (_) { /* already closed */ }
        dongle = null;
      }
      if (ctx) {
        try { ctx.close(); } catch (_) { /* already closed */ }
        ctx = null;
      }
    };

    // The open dongle, opened on first use and again after a failure (a dongle
    // that was unplugged and plugged back in is a new connection).
    this.dongle = () => {
      if (dongle && !dongle.closed) {
        return dongle;
      }
      if (!ctx || ctx.closed) {
        ctx = new licd.Context();
      }
      dongle = ctx.open(this.serial);
      return dongle;
    };

    // Runs fn(session) in a session of its own; with write, after unlocking the
    // write role with the configured key.
    this.withSession = (write, fn) => {
      let session;
      try {
        session = this.dongle().openSession();
      } catch (err) {
        release();
        throw err;
      }
      try {
        if (write) {
          const file = this.credentials && this.credentials.writeKeyFile;
          if (!file) {
            throw new Error('this operation needs the dongle\'s write key: set its file in the keynub-dongle configuration');
          }
          session.authorizeWrite(fs.readFileSync(file));
        }
        return fn(session);
      } finally {
        session.close();
      }
    };

    this.release = release;
    this.on('close', release);
  }
  RED.nodes.registerType('keynub-dongle', KeynubDongleNode, {
    credentials: { writeKeyFile: { type: 'text' } },
  });

  // --- helpers ----------------------------------------------------------------
  function fail(node, msg, err, done) {
    msg.keynub = { code: err.code || null, detail: err.detail || '' };
    node.status({ fill: 'red', shape: 'ring', text: err.code || 'error' });
    done(err);
  }

  function dongleOf(node, config) {
    const dongle = RED.nodes.getNode(config.dongle);
    if (!dongle) {
      node.status({ fill: 'red', shape: 'ring', text: 'no keynub-dongle configured' });
    }
    return dongle;
  }

  function bytes(value) {
    if (Buffer.isBuffer(value)) {
      return value;
    }
    if (typeof value === 'string') {
      return Buffer.from(value, 'utf8');
    }
    if (value instanceof Uint8Array) {
      return Buffer.from(value);
    }
    if (value && typeof value === 'object') {
      return Buffer.from(JSON.stringify(value), 'utf8');
    }
    throw new Error('msg.payload must be a Buffer, a string or an object');
  }

  // --- keynub-genuine -----------------------------------------------------------
  function KeynubGenuineNode(config) {
    RED.nodes.createNode(this, config);
    const dongle = dongleOf(this, config);
    this.on('input', (msg, send, done) => {
      if (!dongle) {
        done(new Error('no keynub-dongle configured'));
        return;
      }
      try {
        const g = dongle.dongle().verifyGenuine();
        msg.payload = { genuine: true, serial: g.serial, provisionedDate: g.provisionedDate };
        this.status({ fill: 'green', shape: 'dot', text: g.serial });
        send([msg, null]);
      } catch (err) {
        // Every failure answers "not genuine": a missing dongle, a counterfeit
        // and an I/O error alike. The code says which.
        dongle.release();
        msg.payload = { genuine: false, code: err.code || null, detail: err.detail || err.message };
        this.status({ fill: 'red', shape: 'ring', text: err.code || 'not genuine' });
        send([null, msg]);
      }
      done();
    });
  }
  RED.nodes.registerType('keynub-genuine', KeynubGenuineNode);

  // --- keynub-record --------------------------------------------------------------
  function KeynubRecordNode(config) {
    RED.nodes.createNode(this, config);
    const dongle = dongleOf(this, config);
    const action = config.action || 'read';
    this.on('input', (msg, send, done) => {
      if (!dongle) {
        done(new Error('no keynub-dongle configured'));
        return;
      }
      const name = (config.record || msg.topic || '').toString();
      try {
        if (action !== 'list' && !name) {
          throw new Error('no record name: set it in the node or in msg.topic');
        }
        const write = action === 'write' || action === 'erase';
        dongle.withSession(write, (s) => {
          if (action === 'list') {
            msg.payload = s.listRecords();
          } else if (action === 'read') {
            const data = s.readRecord(name);
            msg.payload = config.output === 'string' ? data.toString('utf8') : data;
          } else if (action === 'write') {
            s.writeRecord(name, bytes(msg.payload));
          } else if (action === 'erase') {
            s.eraseRecord(name);
          } else {
            throw new Error('unknown action ' + action);
          }
        });
        msg.topic = name || msg.topic;
        this.status({ fill: 'green', shape: 'dot', text: action + (name ? ' ' + name : '') });
        send(msg);
        done();
      } catch (err) {
        fail(this, msg, err, done);
      }
    });
  }
  RED.nodes.registerType('keynub-record', KeynubRecordNode);

  // --- keynub-counter -------------------------------------------------------------
  function KeynubCounterNode(config) {
    RED.nodes.createNode(this, config);
    const dongle = dongleOf(this, config);
    const action = config.action || 'read';
    this.on('input', (msg, send, done) => {
      if (!dongle) {
        done(new Error('no keynub-dongle configured'));
        return;
      }
      const id = Number(msg.counter !== undefined ? msg.counter : config.counter || 0);
      try {
        if (!Number.isInteger(id) || id < 0 || id > 255) {
          throw new Error('the counter id must be an integer from 0 to 255');
        }
        msg.payload = dongle.withSession(action === 'increment',
          (s) => (action === 'increment' ? s.incrementCounter(id) : s.readCounter(id)));
        msg.counter = id;
        this.status({ fill: 'green', shape: 'dot', text: 'counter ' + id + ': ' + msg.payload });
        send(msg);
        done();
      } catch (err) {
        fail(this, msg, err, done);
      }
    });
  }
  RED.nodes.registerType('keynub-counter', KeynubCounterNode);

  // --- keynub-crypto --------------------------------------------------------------
  function KeynubCryptoNode(config) {
    RED.nodes.createNode(this, config);
    const dongle = dongleOf(this, config);
    const action = config.action || 'decrypt';
    const scope = config.scope === 'device' ? licd.Scope.DEVICE : licd.Scope.DEVELOPER;
    this.on('input', (msg, send, done) => {
      if (!dongle) {
        done(new Error('no keynub-dongle configured'));
        return;
      }
      try {
        const input = bytes(msg.payload);
        const out = dongle.withSession(false,
          (s) => (action === 'encrypt' ? s.appEncrypt(scope, input) : s.appDecrypt(input)));
        msg.payload = action === 'decrypt' && config.output === 'string' ? out.toString('utf8') : out;
        this.status({ fill: 'green', shape: 'dot', text: action + 'ed ' + out.length + ' bytes' });
        send(msg);
        done();
      } catch (err) {
        fail(this, msg, err, done);
      }
    });
  }
  RED.nodes.registerType('keynub-crypto', KeynubCryptoNode);
};
