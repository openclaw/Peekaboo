import { createServer } from 'node:http';
import { createHash } from 'node:crypto';

// Minimal, synthetic CDP peer: never launches or discovers a real browser.
export async function devtoolsFixture({ refuse = false, redirectURL } = {}) {
  const sockets = new Set();
  const commands = [];
  let attaches = 0;
  let requests = 0;
  const server = createServer((_request, response) => {
    requests++;
    response.writeHead(404).end();
  });
  server.on('upgrade', (request, socket) => {
    attaches++;
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
    socket.on('error', () => {});
    if (redirectURL) {
      socket.end('HTTP/1.1 302 Found\r\nLocation: ' + redirectURL + '\r\nContent-Length: 0\r\n\r\n');
      return;
    }
    if (refuse) {
      socket.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n');
      return;
    }
    const accept = createHash('sha1')
      .update(request.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
      .digest('base64');
    socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n' +
      'Connection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n');
    function send(value) {
      const payload = Buffer.from(JSON.stringify(value));
      const header = Buffer.alloc(payload.length < 126 ? 2 : 4);
      header[0] = 0x81;
      header[1] = payload.length < 126 ? payload.length : 126;
      if (payload.length >= 126) header.writeUInt16BE(payload.length, 2);
      socket.write(Buffer.concat([header, payload]));
    }
    const targetInfo = { targetId: 'fixture-browser', type: 'browser', title: '', url: '', attached: true };
    function command(value) {
      commands.push(value.method);
      let result = {};
      switch (value.method) {
        case 'Target.getBrowserContexts': result = { browserContextIds: [] }; break;
        case 'Target.getTargets': result = { targetInfos: [targetInfo] }; break;
        case 'Target.setDiscoverTargets':
          send({ method: 'Target.targetCreated', params: { targetInfo } }); break;
        case 'Target.attachToTarget':
          send({ method: 'Target.attachedToTarget', params: { sessionId: 'fixture-session', targetInfo, waitingForDebugger: false } });
          result = { sessionId: 'fixture-session' }; break;
        case 'Target.detachFromTarget':
          send({ method: 'Target.detachedFromTarget', params: { sessionId: 'fixture-session' } }); break;
        case 'Browser.getVersion':
          result = { product: 'Chrome/152.0', protocolVersion: '1.3', userAgent: 'fixture' }; break;
      }
      send({ id: value.id, result, ...(value.sessionId ? { sessionId: value.sessionId } : {}) });
    }
    let buffered = Buffer.alloc(0);
    socket.on('data', chunk => {
      buffered = Buffer.concat([buffered, chunk]);
      while (buffered.length >= 2) {
        const opcode = buffered[0] & 15;
        let size = buffered[1] & 127;
        let offset = 2;
        if (size === 126) {
          if (buffered.length < 4) return;
          size = buffered.readUInt16BE(2); offset = 4;
        } else if (size === 127) {
          socket.destroy(); return;
        }
        const masked = Boolean(buffered[1] & 128);
        const end = offset + (masked ? 4 : 0) + size;
        if (buffered.length < end) return;
        const mask = masked ? buffered.subarray(offset, offset + 4) : undefined;
        if (masked) offset += 4;
        const data = Buffer.from(buffered.subarray(offset, end));
        buffered = buffered.subarray(end);
        if (mask) for (let i = 0; i < data.length; i++) data[i] ^= mask[i % 4];
        if (opcode === 8) { socket.end(Buffer.from([0x88, 0])); return; }
        if (opcode === 1) command(JSON.parse(data.toString()));
      }
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return {
    endpoint: `ws://127.0.0.1:${server.address().port}/devtools/browser/fixture`,
    get attaches() { return attaches; },
    get requests() { return requests; },
    commands,
    drop() { for (const socket of sockets) socket.destroy(); },
    async close() {
      for (const socket of sockets) socket.destroy();
      await new Promise(resolve => server.close(resolve));
    },
  };
}
