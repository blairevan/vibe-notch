import net from 'node:net';
import fs from 'node:fs';

const SOCKET_PATH = '/tmp/claude-island.sock';
const DEBUG_LOG = '/tmp/dsh-vibe-notch-debug.log';

function logDebug(msg) {
  try {
    fs.appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] ${msg}\n`);
  } catch {}
}

function sendEvent(payload) {
  logDebug(`Sending to socket: ${JSON.stringify(payload)}`);
  try {
    const client = net.createConnection(SOCKET_PATH, () => {
      client.write(JSON.stringify(payload), () => {
        logDebug(`Successfully wrote ${payload.event} to socket`);
        client.end();
      });
    });
    client.on('error', (err) => {
      logDebug(`Socket error: ${err.message}`);
    });
  } catch (err) {
    logDebug(`Connection exception: ${err.message}`);
  }
}

export function apply(ctx) {
  logDebug('dsh-vibe-notch apply() called');

  ctx.on('session/created', (session) => {
    logDebug(`session/created: ${session.id}`);
    sendEvent({
      session_id: session.id,
      cwd: session.header?.cwd || process.cwd(),
      event: 'SessionStart',
      status: 'waiting_for_input',
      pid: process.pid,
      client: 'dsh'
    });
  }, { global: true });

  ctx.on('session/event', (session, event) => {
    const cwd = session.header?.cwd || process.cwd();
    const sessionId = session.id;
    logDebug(`session/event: ${sessionId} type=${event.type}`);

    if (event.type === 'turn/start' || (event.type === 'user/message' && (event.data?.source?.kind === 'user' || event.data?.role === 'user'))) {
      sendEvent({
        session_id: sessionId,
        cwd,
        event: 'UserPromptSubmit',
        status: 'processing',
        pid: process.pid,
        client: 'dsh'
      });
    } else if (event.type === 'tool/call') {
      sendEvent({
        session_id: sessionId,
        cwd,
        event: 'PreToolUse',
        status: 'running_tool',
        tool: event.data?.tool || event.data?.name || 'tool',
        tool_use_id: event.data?.callId || event.data?.id,
        tool_input: event.data?.input || event.data?.arguments,
        pid: process.pid,
        client: 'dsh'
      });
    } else if (event.type === 'tool/result') {
      sendEvent({
        session_id: sessionId,
        cwd,
        event: 'PostToolUse',
        status: 'processing',
        tool_use_id: event.data?.callId || event.data?.id,
        pid: process.pid,
        client: 'dsh'
      });
    } else if (event.type === 'approval/asked') {
      sendEvent({
        session_id: sessionId,
        cwd,
        event: 'PermissionRequest',
        status: 'waiting_for_approval',
        tool: event.data?.toolName || event.data?.tool || 'tool',
        tool_use_id: event.data?.id || event.data?.callId,
        pid: process.pid,
        client: 'dsh'
      });
    } else if (event.type === 'turn/end') {
      sendEvent({
        session_id: sessionId,
        cwd,
        event: 'Stop',
        status: 'waiting_for_input',
        pid: process.pid,
        client: 'dsh'
      });
    }
  }, { global: true });

  ctx.on('session/disposed', (session) => {
    logDebug(`session/disposed: ${session.id}`);
    sendEvent({
      session_id: session.id,
      cwd: session.header?.cwd || process.cwd(),
      event: 'SessionEnd',
      status: 'ended',
      pid: process.pid,
      client: 'dsh'
    });
  }, { global: true });
}
