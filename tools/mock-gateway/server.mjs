// Fake OpenClaw gateway for NotchClaw development.
// Validates every request against the official protocol schema, checks the device
// signature, and streams a canned reply (with an image artifact) for chat.send.
// Run: npm install && PORT=18799 npm start, then point NotchClaw at ws://127.0.0.1:18799

import { WebSocketServer } from 'ws';
import Ajv from 'ajv';
import addFormats from 'ajv-formats';
import crypto from 'node:crypto';
import fs from 'node:fs';
const schema = JSON.parse(fs.readFileSync(new URL('./node_modules/@openclaw/gateway-protocol/protocol.schema.json', import.meta.url)));
const ajv = new Ajv({ strict: false, allErrors: true }); addFormats(ajv);
ajv.addSchema({ $id: 'p', definitions: schema.definitions });
const v = (name, data) => { const f = ajv.getSchema(`p#/definitions/${name}`); if (!f) return `no schema ${name}`; return f(data) ? null : JSON.stringify(f.errors).slice(0, 600); };
const methodSchema = { connect: 'ConnectParams', 'chat.send': 'ChatSendParams', 'chat.history': 'ChatHistoryParams', 'chat.abort': 'ChatAbortParams',
  'sessions.patch': 'SessionsPatchParams', 'sessions.compact': 'SessionsCompactParams', 'sessions.reset': 'SessionsResetParams',
  'sessions.describe': 'SessionsDescribeParams', 'sessions.messages.subscribe': 'SessionsMessagesSubscribeParams', 'models.list': 'ModelsListParams',
  'exec.approval.resolve': 'ExecApprovalResolveParams', 'artifacts.download': 'ArtifactsDownloadParams', 'sessions.list': 'SessionsListParams', 'sessions.create': 'SessionsCreateParams', 'sessions.messages.unsubscribe': 'SessionsMessagesUnsubscribeParams' };
const port = Number(process.env.PORT || 18799);
const sessions = [{ key: 'agent:main:main', kind: 'direct', updatedAt: Date.now() - 60000 }];
const wss = new WebSocketServer({ port });
console.log('mock on', port);
wss.on('connection', (ws) => {
  let seq = 0; const nonce = crypto.randomUUID(); const ts = Date.now();
  const event = (e, payload) => ws.send(JSON.stringify({ type: 'event', event: e, payload, seq: ++seq }));
  const res = (id, ok, payload, error) => ws.send(JSON.stringify({ type: 'res', id, ok, payload, error }));
  event('connect.challenge', { nonce, ts });
  ws.on('message', (raw) => {
    const f = JSON.parse(raw.toString());
    const sname = methodSchema[f.method];
    const err = sname ? v(sname, f.params) : null;
    console.log(`REQ ${f.method} ${err ? 'SCHEMA-FAIL ' + err : 'ok'}`);
    if (f.method === 'connect') {
      const d = f.params.device; const p = f.params;
      const payload = ['v2', d.id, p.client.id, p.client.mode, p.role, (p.scopes||[]).join(','), String(d.signedAt), p.auth?.token ?? '', d.nonce].join('|');
      const pub = Buffer.from(d.publicKey.replace(/-/g,'+').replace(/_/g,'/'), 'base64');
      const key = crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100','hex'), pub]), format: 'der', type: 'spki' });
      const sigOk = crypto.verify(null, Buffer.from(payload), key, Buffer.from(d.signature.replace(/-/g,'+').replace(/_/g,'/'), 'base64'));
      const idOk = crypto.createHash('sha256').update(pub).digest('hex') === d.id;
      console.log(`  signature ${sigOk} deviceId ${idOk} nonce ${d.nonce === nonce} signedAt ${d.signedAt === ts}`);
      // Simulate OpenClaw's scope upgrade: admin needs approval (create $MOCK_ADMIN_APPROVED_FILE to approve).
      const wantsAdmin = (p.scopes || []).includes('operator.admin');
      const approved = process.env.MOCK_ADMIN_APPROVED_FILE ? fs.existsSync(process.env.MOCK_ADMIN_APPROVED_FILE) : true;
      if (wantsAdmin && !approved) {
        console.log('  admin upgrade pending');
        return res(f.id, false, undefined, { code: 'NOT_PAIRED', message: 'pairing required', details: { code: 'PAIRING_REQUIRED', requestId: 'req-admin-1', recommendedNextStep: 'wait_then_retry' } });
      }
      ws.scopes = p.scopes || [];
      return res(f.id, true, { type: 'hello-ok', protocol: 4, server: { version: 'mock-2026.8', connId: 'c1' }, features: { methods: [], events: [] }, snapshot: {}, auth: { role: 'operator', scopes: p.scopes, deviceToken: 'devtok' }, policy: { maxPayload: 26214400, maxBufferedBytes: 52428800, tickIntervalMs: 15000 } });
    }
    switch (f.method) {
      case 'chat.history': return res(f.id, true, { messages: [{ role: 'user', content: [{ type: 'text', text: '<notchclaw-format>x</notchclaw-format>\n\nold question' }] }, { role: 'assistant', content: [{ type: 'text', text: 'old **answer**' }] }], sessionInfo: { model: 'gpt-5.1-codex', modelProvider: 'openai-codex', thinkingLevel: 'medium', totalTokens: 1000, contextTokens: 200000 } });
      case 'sessions.describe': return res(f.id, true, { session: { key: 'agent:main:main', model: 'gpt-5.1-codex', modelProvider: 'openai-codex', thinkingLevel: 'medium' } });
      case 'models.list': return res(f.id, true, { models: [{ id: 'gpt-5.1-codex', name: 'GPT-5.1 Codex', provider: 'openai-codex' }, { id: 'claude-sonnet-5-5', name: 'Claude Sonnet 5.5', provider: 'anthropic' }] });
      case 'usage.status': return res(f.id, true, { updatedAt: Date.now(), providers: [{ provider: 'openai', displayName: 'Codex', plan: 'plus', windows: [{ label: '5h', usedPercent: 37, resetAt: Date.now() + 3600e3 }, { label: 'Week', usedPercent: 64 }] }] });
      case 'chat.send': {
        const runId = 'run-' + seq;
        res(f.id, true, { runId, status: 'started' });
        console.log('  message starts with instruction:', f.params.message.startsWith('<notchclaw-format>'));
        const sk = 'agent:main:main'; let rs = 0;
        setTimeout(() => event('chat', { runId, sessionKey: sk, seq: rs++, state: 'status', phase: 'starting_model' }), 200);
        setTimeout(() => event('chat', { runId, sessionKey: sk, seq: rs++, state: 'delta', deltaText: '## Hi', message: { role: 'assistant', content: [{ type: 'text', text: '## Hi' }] } }), 600);
        setTimeout(() => event('chat', { runId, sessionKey: sk, seq: rs++, state: 'delta', deltaText: ' there\n\n- one\n- two' }), 900);
        setTimeout(() => event('chat', { runId, sessionKey: sk, seq: rs++, state: 'final', message: { role: 'assistant', content: [{ type: 'text', text: '## Hi there\n\n- one\n- two' }, { type: 'image', artifactId: 'art_1', mimeType: 'image/png', width: 1, height: 1 }] } }), 1200);
        if (process.env.MOCK_REPLAY) {
          // Things a real gateway can deliver after a reply: a repeated terminal event,
          // the same reply committed under another run id, and a silent run.
          const finalMsg = { role: 'assistant', content: [{ type: 'text', text: '## Hi there\n\n- one\n- two' }] };
          setTimeout(() => event('chat', { runId, sessionKey: sk, seq: 90, state: 'final', message: finalMsg }), 3500);
          setTimeout(() => event('chat', { runId: runId + '-mirror', sessionKey: sk, seq: 0, state: 'final', message: finalMsg }), 4000);
          setTimeout(() => event('chat', { runId: 'heartbeat-1', sessionKey: sk, seq: 0, state: 'final', message: { role: 'assistant', content: [] } }), 4500);
        }
        return;
      }
      case 'artifacts.download': return res(f.id, true, { artifact: { id: f.params.artifactId, type: 'image', title: 'img', mimeType: 'image/png', download: { mode: 'bytes' } }, encoding: 'base64', data: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==' });
      case 'sessions.list': return res(f.id, true, { sessions: [...sessions].sort((a, b) => b.updatedAt - a.updatedAt), count: sessions.length });
      case 'sessions.create': {
        const key = 'agent:main:s-' + Math.random().toString(36).slice(2, 8);
        sessions.push({ key, kind: 'direct', label: 'Fresh chat', updatedAt: Date.now() });
        return res(f.id, true, { ok: true, key, sessionId: key, entry: { key } });
      }
      case 'sessions.reset':
      case 'sessions.compact':
        if (!(ws.scopes || []).includes('operator.admin')) {
          return res(f.id, false, undefined, { code: 'FORBIDDEN', message: 'missing scope: operator.admin', details: { code: 'MISSING_SCOPE', missingScope: 'operator.admin', requiredScopes: ['operator.admin'] } });
        }
        return res(f.id, true, { ok: true, key: f.params.key });
      default: return res(f.id, true, { ok: true });
    }
  });
});
