import net from 'node:net';
import fs from 'node:fs';

const SOCKET_PATH = '/tmp/claude-island.sock';
const LOG_PATH = '/tmp/vibe-notch-flow.log';

function log(msg) {
  try {
    fs.appendFileSync(LOG_PATH, '[' + process.pid + '] [dsh-plugin] ' + msg + '\n');
  } catch {}
}

const isDesktop = process.execPath.includes('DeepSeek Harness Desktop') ||
                  process.argv.some(arg => typeof arg === 'string' && arg.includes('DeepSeek Harness Desktop')) ||
                  Boolean(process.env.DSH_DESKTOP);

const dshClientType = isDesktop ? 'dsh-desktop' : 'dsh-web';

log('dsh-vibe-notch plugin loaded, clientType=' + dshClientType);

function sendEvent(payload) {
  const fullPayload = {
    ...payload,
    client: dshClientType
  };
  log('sendEvent connecting: event=' + fullPayload.event + ', status=' + fullPayload.status + ', client=' + fullPayload.client + ', tool=' + (fullPayload.tool || 'none'));
  try {
    const client = net.createConnection(SOCKET_PATH, () => {
      client.write(JSON.stringify(fullPayload), () => {
        client.end();
        log('sendEvent success for ' + fullPayload.event);
      });
    });
    client.on('error', (err) => {
      log('sendEvent socket error: ' + err.message);
    });
  } catch (err) {
    log('sendEvent exception: ' + err.message);
  }
}

// Track pending/recent tool calls by sessionId
const activeToolCalls = new Map();

function parseToolArguments(raw) {
  if (!raw) return {};
  if (typeof raw === 'object') return raw;
  if (typeof raw === 'string') {
    try {
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed === 'object') return parsed;
    } catch {}
    return { command: raw };
  }
  return {};
}

export function apply(ctx) {
  log('dsh-vibe-notch apply(ctx) registered, clientType=' + dshClientType);

  ctx.on('session/created', (session) => {
    log('session/created: ' + (session.id || '').slice(0, 8));
    sendEvent({
      session_id: session.id,
      cwd: session.header?.cwd || process.cwd(),
      event: 'SessionStart',
      status: 'waiting_for_input',
      pid: process.pid
    });
  }, { global: true });

  ctx.on('session/event', (session, event) => {
    const cwd = session.header?.cwd || process.cwd();
    const sessionId = session.id;
    log('session/event: type=' + event.type + ', sid=' + (sessionId || '').slice(0, 8));

    if (event.type === 'turn/start') {
      activeToolCalls.delete(sessionId);
      sendEvent({
        session_id: sessionId,
        cwd,
        event: 'UserPromptSubmit',
        status: 'processing',
        pid: process.pid
      });
    } else if (event.type === 'tool/call') {
      const toolName = event.data?.name || event.data?.tool || 'unknown';
      const callId = event.data?.callId || ('call-' + Date.now());
      const toolInput = parseToolArguments(event.data?.arguments || event.data?.input);

      activeToolCalls.set(sessionId, {
        toolName,
        callId,
        toolInput
      });

      sendEvent({
        session_id: sessionId,
        cwd,
        event: 'PreToolUse',
        status: 'running_tool',
        tool: toolName,
        tool_name: toolName,
        tool_use_id: callId,
        tool_input: toolInput,
        pid: process.pid
      });
    } else if (event.type === 'tool/result') {
      const callId = event.data?.callId || activeToolCalls.get(sessionId)?.callId;
      sendEvent({
        session_id: sessionId,
        cwd,
        event: 'PostToolUse',
        status: 'processing',
        tool_use_id: callId,
        pid: process.pid
      });
    } else if (event.type === 'approval/asked') {
      const lastCall = activeToolCalls.get(sessionId);
      const toolName = event.data?.toolName || lastCall?.toolName || 'tool';
      const approvalId = event.data?.id || event.data?.callId || lastCall?.callId || ('approval-' + Date.now());
      const reason = event.data?.reason || '';
      
      const combinedInput = {
        ...(lastCall?.toolInput || {}),
        ...(reason ? { reason } : {})
      };

      log('approval/asked: tool=' + toolName + ', reason=' + reason + ', id=' + approvalId);

      sendEvent({
        session_id: sessionId,
        cwd,
        event: 'PermissionRequest',
        status: 'waiting_for_approval',
        tool: toolName,
        tool_name: toolName,
        tool_use_id: approvalId,
        tool_input: combinedInput,
        reason: reason,
        message: reason,
        pid: process.pid
      });
    } else if (event.type === 'approval/decided') {
      const approvalId = event.data?.id;
      const outcome = event.data?.outcome;
      log('approval/decided: outcome=' + outcome + ', id=' + approvalId);

      sendEvent({
        session_id: sessionId,
        cwd,
        event: 'PostToolUse',
        status: 'processing',
        tool_use_id: approvalId,
        pid: process.pid
      });
    } else if (event.type === 'turn/end') {
      activeToolCalls.delete(sessionId);
      sendEvent({
        session_id: sessionId,
        cwd,
        event: 'Stop',
        status: 'waiting_for_input',
        pid: process.pid
      });
    }
  }, { global: true });

  ctx.on('session/disposed', (session) => {
    activeToolCalls.delete(session.id);
    log('session/disposed: ' + (session.id || '').slice(0, 8));
    sendEvent({
      session_id: session.id,
      cwd: session.header?.cwd || process.cwd(),
      event: 'SessionEnd',
      status: 'ended',
      pid: process.pid
    });
  }, { global: true });
}

