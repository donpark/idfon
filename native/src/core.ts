import { Cmd, Sub, asciiBytes, utf8Bytes, windowDescriptor } from "@native-sdk/core";
import { type WindowDescriptor } from "@native-sdk/core/events";
import { type TextInputEvent, applyTextInputEvent } from "@native-sdk/core/text";

const EMPTY = new Uint8Array(0);
const NO_CONNECTIONS: readonly Connection[] = [];
const MAX_MESSAGE = 8192;
const RECEIVER_CHANNEL = 1;
export type ChannelState = "data" | "closed" | "rejected";

export interface Connection {
  readonly name: Uint8Array;
  readonly endpoint: Uint8Array;
}

export interface Identity {
  readonly name: Uint8Array;
  readonly active: boolean;
}

export interface ChatMessage {
  readonly id: Uint8Array;
  readonly text: Uint8Array;
  readonly sent: boolean;
  readonly timestamp: Uint8Array;
  readonly status: Uint8Array;
}

export interface SessionLaunch {
  readonly peerId: Uint8Array;
  readonly sessionId: Uint8Array;
  readonly sessionType: Uint8Array;
}

export interface Comms {
  readonly audio: boolean;
  readonly live: boolean;
  readonly subscribed: boolean;
  readonly recording: boolean;
  readonly recReady: boolean;
}

export interface Model {
  readonly message: Uint8Array;
  readonly history: readonly ChatMessage[];
  readonly replyRoute: Uint8Array;
  readonly identityName: Uint8Array;
  readonly identities: readonly Identity[];
  readonly identitySelected: boolean;
  readonly copyIdentityTicket: boolean;
  readonly identityError: boolean;
  readonly connections: readonly Connection[];
  readonly selectedConnectionName: Uint8Array;
  readonly sessionLaunch: SessionLaunch | null;
  readonly chatOpen: boolean;
  readonly connectionName: Uint8Array;
  readonly receiverId: Uint8Array;
  readonly receiverTicket: Uint8Array;
  readonly capabilityTicket: Uint8Array;
  readonly capabilityTicketInput: Uint8Array;
  readonly endpointId: Uint8Array;
  readonly receiverStatus: Uint8Array;
  readonly senderStatus: Uint8Array;
  readonly receiverAvailable: boolean;
  readonly senderDisabled: boolean;
  readonly audioActive: boolean;
  readonly audioStatus: Uint8Array;
  readonly volumeInput: Uint8Array;
  readonly liveActive: boolean;
  readonly subscribedActive: boolean;
  readonly liveTicket: Uint8Array;
  readonly liveTicketInput: Uint8Array;
  readonly liveStatus: Uint8Array;
  readonly recordingStatus: Uint8Array;
  readonly recordingReady: boolean;
  readonly pendingRecordingSend: boolean;
  readonly subscribedRecording: boolean;
  readonly recordingActive: boolean;
  readonly recordingTicket: Uint8Array;
  readonly recordingDuration: Uint8Array;
  readonly comms: Comms;
  readonly blobTicketInput: Uint8Array;
  readonly blobStatus: Uint8Array;
  readonly playbackActive: boolean;
  readonly fetchedRecordingReady: boolean;
  readonly playbackStatus: Uint8Array;
  readonly showAdvanced: boolean;
  readonly showTicket: boolean;
  readonly showAddConnection: boolean;
  readonly showAddIdentity: boolean;
  readonly newIdentityName: Uint8Array;
  readonly liveAutoAccept: boolean;
  readonly livePolicyStatus: Uint8Array;
  readonly eventCursor: Uint8Array;
  readonly tickAt: number;
  readonly eventsReady: boolean;
}

export type Msg =
  | { readonly kind: "connect_receiver" }
  | { readonly kind: "receiver_ready"; readonly data: Uint8Array }
  | { readonly kind: "receiver_error"; readonly data: Uint8Array }
  | { readonly kind: "receiver_event"; readonly key: number; readonly state: ChannelState; readonly bytes: Uint8Array; readonly droppedPending: number; readonly droppedTotal: number }
  | { readonly kind: "daemon_ready"; readonly data: Uint8Array }
  | { readonly kind: "daemon_error"; readonly data: Uint8Array }
  | { readonly kind: "peers_loaded"; readonly data: Uint8Array }
  | { readonly kind: "recording_persisted"; readonly data: Uint8Array }
  | { readonly kind: "recording_persist_error"; readonly data: Uint8Array }
  | { readonly kind: "message_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "identity_name_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "identity_pressed" }
  | { readonly kind: "identity_selected"; readonly name: Uint8Array }
  | { readonly kind: "identities_loaded"; readonly data: Uint8Array }
  | { readonly kind: "show_add_identity" }
  | { readonly kind: "cancel_add_identity" }
  | { readonly kind: "new_identity_name_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "create_identity" }
  | { readonly kind: "identity_created"; readonly data: Uint8Array }
  | { readonly kind: "identity_create_error"; readonly data: Uint8Array }
  | { readonly kind: "identity_used"; readonly data: Uint8Array }
  | { readonly kind: "identity_use_error"; readonly data: Uint8Array }
  | { readonly kind: "connection_selected"; readonly name: Uint8Array }
  | { readonly kind: "connection_opened"; readonly name: Uint8Array }
  | { readonly kind: "chat_closed" }
  | { readonly kind: "connection_name_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "receiver_id_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "capability_ticket_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "issue_capability_ticket" }
  | { readonly kind: "capability_ticket_issued"; readonly data: Uint8Array }
  | { readonly kind: "capability_ticket_error"; readonly data: Uint8Array }
  | { readonly kind: "copy_endpoint_id" }
  | { readonly kind: "show_add_connection" }
  | { readonly kind: "cancel_add_connection" }
  | { readonly kind: "toggle_live_auto_accept" }
  | { readonly kind: "add_connection" }
  | { readonly kind: "peer_added"; readonly data: Uint8Array }
  | { readonly kind: "peer_add_error"; readonly data: Uint8Array }
  | { readonly kind: "send_message" }
  | { readonly kind: "reply_message" }

  | { readonly kind: "sender_ready"; readonly data: Uint8Array }
  | { readonly kind: "sender_error"; readonly data: Uint8Array }
  | { readonly kind: "audio_start" }
  | { readonly kind: "audio_stop" }
  | { readonly kind: "audio_started"; readonly data: Uint8Array }
  | { readonly kind: "audio_stopped"; readonly data: Uint8Array }
  | { readonly kind: "audio_error"; readonly data: Uint8Array }
  | { readonly kind: "audio_probe" }
  | { readonly kind: "audio_emergency_stop" }
  | { readonly kind: "toggle_advanced" }
  | { readonly kind: "audio_probe_result"; readonly data: Uint8Array }
  | { readonly kind: "volume_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "volume_set" }
  | { readonly kind: "live_start" }
  | { readonly kind: "live_stop" }
  | { readonly kind: "live_started"; readonly data: Uint8Array }
  | { readonly kind: "copy_live_ticket" }
  | { readonly kind: "live_stopped"; readonly data: Uint8Array }
  | { readonly kind: "live_error"; readonly data: Uint8Array }
  | { readonly kind: "live_ticket_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "live_subscribe" }
  | { readonly kind: "live_unsubscribe" }
  | { readonly kind: "live_subscribed"; readonly data: Uint8Array }
  | { readonly kind: "live_unsubscribed"; readonly data: Uint8Array }
  | { readonly kind: "live_subscribe_error"; readonly data: Uint8Array }
  | { readonly kind: "recording_start" }
  | { readonly kind: "recording_stop" }
  | { readonly kind: "recording_started"; readonly data: Uint8Array }
  | { readonly kind: "recording_stopped"; readonly data: Uint8Array }
  | { readonly kind: "recording_error"; readonly data: Uint8Array }
  | { readonly kind: "recording_store" }
  | { readonly kind: "recording_stored"; readonly data: Uint8Array }
  | { readonly kind: "recording_cancel" }
  | { readonly kind: "copy_recording_ticket" }
  | { readonly kind: "recording_send" }
  | { readonly kind: "recording_store_error"; readonly data: Uint8Array }
  | { readonly kind: "blob_ticket_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "blob_fetch" }
  | { readonly kind: "blob_fetched"; readonly data: Uint8Array }
  | { readonly kind: "blob_fetch_error"; readonly data: Uint8Array }
  | { readonly kind: "playback_start" }
  | { readonly kind: "playback_stop" }
  | { readonly kind: "playback_started"; readonly data: Uint8Array }
  | { readonly kind: "playback_stopped"; readonly data: Uint8Array }
  | { readonly kind: "playback_error"; readonly data: Uint8Array }
  | { readonly kind: "audio_emergency_stopped"; readonly data: Uint8Array }
  | { readonly kind: "media_session_ready"; readonly data: Uint8Array }
  | { readonly kind: "events_loaded"; readonly data: Uint8Array }
  | { readonly kind: "poll_events"; readonly at: number };

export const viewUnbound = [
  "replyRoute", "identityName", "copyIdentityTicket", "identityError", "chatOpen", "receiverTicket", "capabilityTicket", "endpointId", "audioActive", "pendingRecordingSend", "subscribedRecording", "showTicket", "liveAutoAccept", "eventCursor", "eventsReady",
  "receiverAvailable", "receiver_ready", "receiver_error", "receiver_event", "sender_ready", "sender_error", "daemon_ready", "daemon_error", "peers_loaded", "events_loaded", "poll_events", "tickAt",
  "connect_receiver", "recording_persisted", "recording_persist_error", "identity_name_edit", "identity_pressed", "identities_loaded", "identity_created", "identity_create_error", "identity_used", "identity_use_error", "chat_closed", "capability_ticket_issued", "capability_ticket_error", "copy_endpoint_id", "peer_added", "peer_add_error", "audio_start", "audio_stop", "audio_started", "audio_stopped", "audio_error", "audio_probe_result", "live_started", "live_stopped", "live_error", "live_subscribed", "live_unsubscribed", "live_subscribe_error", "recording_started", "recording_stopped", "recording_error", "recording_store", "recording_stored", "recording_send", "recording_store_error", "blob_fetched", "blob_fetch_error", "playback_started", "playback_stopped", "playback_error", "audio_emergency_stopped", "media_session_ready",
] as const;

export function subscriptions(model: Model): Sub<Msg> {
  if (!model.receiverAvailable) return Sub.none;
  return Sub.timer("nufond-events", 1000, "poll_events");
}

export function initialModel(): Model | [Model, Cmd<Msg>] {
  const model: Model = {

    message: EMPTY,
    history: [],
    replyRoute: EMPTY,
    identityName: utf8Bytes("Default"),
    identities: [{ name: utf8Bytes("Default"), active: true }],
    identitySelected: true,
    copyIdentityTicket: false,
    identityError: false,
    connections: NO_CONNECTIONS,
    selectedConnectionName: EMPTY,
    sessionLaunch: null,
    chatOpen: false,
    connectionName: EMPTY,
    receiverId: EMPTY,
    receiverTicket: EMPTY,
    capabilityTicket: EMPTY,
    capabilityTicketInput: EMPTY,
    endpointId: EMPTY,
    receiverStatus: utf8Bytes("Connecting"),
    senderStatus: utf8Bytes("Waiting for receiver"),
    receiverAvailable: false,
    senderDisabled: true,
    audioActive: false,
    audioStatus: utf8Bytes("Microphone off"),
    volumeInput: utf8Bytes("100"),
    liveActive: false,
    subscribedActive: false,
    liveTicket: EMPTY,
    liveTicketInput: EMPTY,
    liveStatus: utf8Bytes("Live audio off"),
    recordingStatus: utf8Bytes("No recording"),
    recordingReady: false,
    pendingRecordingSend: false,
    subscribedRecording: false,
    recordingActive: false,
    recordingTicket: EMPTY,
    recordingDuration: utf8Bytes("0"),
    comms: { audio: false, live: false, subscribed: false, recording: false, recReady: false },
    blobTicketInput: EMPTY,
    blobStatus: utf8Bytes("No blob selected"),
    playbackActive: false,
    fetchedRecordingReady: false,
    playbackStatus: utf8Bytes("Playback stopped"),
    showAdvanced: false,
    showTicket: false,
    showAddConnection: false,
    showAddIdentity: false,
    newIdentityName: EMPTY,
    liveAutoAccept: false,
    livePolicyStatus: utf8Bytes("Incoming live audio requires approval"),
    eventCursor: EMPTY,
    tickAt: 0,
    eventsReady: false,
  };
  return [model, Cmd.request("nufond.request", asciiBytes('{"version":1,"id":"gui-identities","method":"identities.compact","params":{}}'), { key: "nufond-identities", ok: "identities_loaded", err: "daemon_error" })];
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a);
  out.set(b, a.length);
  return out;
}

function receiverTicket(data: Uint8Array): Uint8Array {
  let i = 0;
  while (i < data.length) {
    if (data[i] === 10) return data.slice(0, i);
    i += 1;
  }
  return data;
}

function endpointId(data: Uint8Array): Uint8Array {
  let i = 0;
  while (i < data.length) {
    if (data[i] === 10) return data.slice(i + 1);
    i += 1;
  }
  return EMPTY;
}

function contextTicket(data: Uint8Array): Uint8Array {
  const marker = utf8Bytes("\"ticket\":[");
  let start = -1;
  for (let i = 0; i + marker.length <= data.length; i += 1) {
    if (sameBytes(data.slice(i, i + marker.length), marker)) { start = i + marker.length; break; }
  }
  if (start < 0) return EMPTY;
  let count = 0;
  for (let i = start; i < data.length; i += 1) {
    const byte = data[i];
    if (byte >= 48 && byte <= 57) continue;
    if (byte === 93) break;
    if (byte === 44 || byte === 32) { if (i > start && data[i - 1] >= 48 && data[i - 1] <= 57) count += 1; continue; }
    return EMPTY;
  }
  const result = new Uint8Array(count + 1);
  let index = 0;
  let value = 0;
  let digits = 0;
  for (let i = start; i < data.length; i += 1) {
    const byte = data[i];
    if (byte >= 48 && byte <= 57) { value = value * 10 + byte - 48; digits += 1; continue; }
    if (digits > 0) { if (value > 255 || index >= result.length) return EMPTY; result[index] = value; index += 1; value = 0; digits = 0; }
    if (byte === 93) return result.slice(0, index);
    if (byte !== 44 && byte !== 32) return EMPTY;
  }
  return EMPTY;
}

function routedFields(data: Uint8Array): [Uint8Array, Uint8Array] {
  let i = 0;
  while (i < data.length) {
    if (data[i] === 10) return [data.slice(0, i), data.slice(i + 1)];
    i += 1;
  }
  return [EMPTY, EMPTY];
}

function recordingTicket(envelope: Uint8Array): Uint8Array {
  const marker = utf8Bytes("\nticket=");
  let i = 0;
  while (i + marker.length <= envelope.length) {
    if (sameBytes(envelope.slice(i, i + marker.length), marker)) return envelope.slice(i + marker.length);
    i += 1;
  }
  return EMPTY;
}

function chatMessage(message: Uint8Array): Uint8Array {
  const out: number[] = [123, 34, 118, 34, 58, 49, 44, 34, 116, 121, 112, 101, 34, 58, 34, 109, 101, 115, 115, 97, 103, 101, 34, 44, 34, 98, 121, 116, 101, 115, 34, 58, 91];
  for (let i = 0; i < message.length; i += 1) {
    const value = message[i];
    if (value >= 100) out.push(48 + Math.floor(value / 100));
    if (value >= 10) out.push(48 + Math.floor(value / 10) % 10);
    out.push(48 + value % 10);
    if (i + 1 < message.length) out.push(44);
  }
  out.push(93, 125);
  return new Uint8Array(out);
}

function decodeChatMessage(message: Uint8Array): Uint8Array {
  const marker = utf8Bytes("\"bytes\":[");
  let start = -1;
  for (let i = 0; i + marker.length <= message.length; i += 1) {
    if (sameBytes(message.slice(i, i + marker.length), marker)) { start = i + marker.length; break; }
  }
  if (start < 0) return message;
  const values: number[] = [];
  let value = 0;
  let digits = 0;
  for (let i = start; i < message.length; i += 1) {
    const byte = message[i];
    if (byte >= 48 && byte <= 57) { value = value * 10 + byte - 48; digits += 1; continue; }
    if (digits > 0) { if (value > 255) return message; values.push(value); value = 0; digits = 0; }
    if (byte === 93) { const result = new Uint8Array(values.length); for (let j = 0; j < values.length; j += 1) result[j] = values[j]; return result; }
    if (byte !== 44 && byte !== 32) return message;
  }
  return message;
}

function jsonString(data: Uint8Array): Uint8Array {
  const out: number[] = [34];
  for (let i = 0; i < data.length; i += 1) {
    const value = data[i];
    if (value === 34 || value === 92) out.push(92);
    if (value === 10) { out.push(92, 110); continue; }
    if (value === 13) { out.push(92, 114); continue; }
    if (value === 9) { out.push(92, 116); continue; }
    out.push(value);
  }
  out.push(34);
  return new Uint8Array(out);
}

function capabilityTicketPayload(identity: Uint8Array): Uint8Array {
  return concat(concat(utf8Bytes('{"version":1,"id":"gui-capability-ticket","method":"capability.ticket","params":{"identity":'), jsonString(identity)), utf8Bytes(',"capabilities":["message_receive"]}}'));
}

function extractTicket(data: Uint8Array): Uint8Array {
  const marker = utf8Bytes('"ticket":');
  for (let i = 0; i + marker.length < data.length; i += 1) {
    if (sameBytes(data.slice(i, i + marker.length), marker)) {
      let start = i + marker.length;
      while (start < data.length && data[start] === 32) start += 1;
      if (start >= data.length || data[start] !== 123) return EMPTY;
      let depth = 0;
      for (let j = start; j < data.length; j += 1) {
        if (data[j] === 123) depth += 1;
        if (data[j] === 125) { depth -= 1; if (depth === 0) return data.slice(start, j + 1); }
      }
    }
  }
  return EMPTY;
}

function contextPayload(identity: Uint8Array): Uint8Array {
  return concat(concat(utf8Bytes('{"version":1,"id":"gui-context","method":"context","params":{"identity":'), jsonString(identity)), utf8Bytes('}}'));
}

function peersPayload(identity: Uint8Array): Uint8Array {
  return concat(concat(utf8Bytes('{"version":1,"id":"gui-peers","method":"peers.compact","params":{"identity":'), jsonString(identity)), utf8Bytes('}}'));
}

function identityPayload(method: Uint8Array, name: Uint8Array): Uint8Array {
  return concat(concat(concat(concat(utf8Bytes('{"version":1,"id":"gui-identity","method":"'), method), utf8Bytes('","params":{"name":')), jsonString(name)), utf8Bytes('}}'));
}

function ticketEndpointId(ticket: Uint8Array): Uint8Array {
  const marker = utf8Bytes("\"id\":\"");
  for (let i = 0; i + marker.length < ticket.length; i += 1) {
    if (sameBytes(ticket.slice(i, i + marker.length), marker)) {
      const start = i + marker.length;
      let end = start;
      while (end < ticket.length && ticket[end] !== 34) end += 1;
      return ticket.slice(start, end);
    }
  }
  return EMPTY;
}

function peerAddPayload(identity: Uint8Array, name: Uint8Array, ticket: Uint8Array): Uint8Array {
  const id = ticketEndpointId(ticket);
  let payload = concat(utf8Bytes('{"version":1,"id":"gui-peer-add","method":"peer.add","params":{"identity":'), jsonString(identity));
  payload = concat(payload, utf8Bytes(',"id":'));
  payload = concat(payload, jsonString(id));
  payload = concat(payload, utf8Bytes(',"name":'));
  payload = concat(payload, jsonString(name));
  payload = concat(payload, utf8Bytes(',"endpoint_id":'));
  payload = concat(payload, jsonString(id));
  payload = concat(payload, utf8Bytes(',"endpoint_addr":'));
  payload = concat(payload, jsonString(ticket));
  return concat(payload, utf8Bytes(',"aliases":[]}}'));
}

function byteArrayJson(data: Uint8Array): Uint8Array {
  const out: number[] = [91];
  for (let i = 0; i < data.length; i += 1) {
    const value = data[i];
    if (value >= 100) out.push(48 + Math.floor(value / 100));
    if (value >= 10) out.push(48 + Math.floor(value / 10) % 10);
    out.push(48 + value % 10);
    if (i + 1 < data.length) out.push(44);
  }
  out.push(93);
  return new Uint8Array(out);
}

function mediaSessionStartPayload(model: Model): Uint8Array {
  let payload = concat(utf8Bytes('{"version":1,"id":"gui-live","method":"media.session.start","params":{"identity":'), jsonString(model.identityName));
  payload = concat(payload, utf8Bytes(',"peer_bytes":'));
  payload = concat(payload, byteArrayJson(model.receiverId));
  return concat(payload, utf8Bytes(',"kind":"live_audio","mode":"record"}}'));
}

function daemonEventsPayload(identity: Uint8Array, cursor: Uint8Array): Uint8Array {
  let payload = concat(utf8Bytes('{"version":1,"id":"gui-events","method":"events.compact","params":{"identity":'), jsonString(identity));
  payload = concat(payload, utf8Bytes(',"after_bytes":'));
  payload = concat(payload, byteArrayJson(cursor));
  return concat(payload, utf8Bytes('}}'));
}

function daemonMessagePayload(identity: Uint8Array, to: Uint8Array, text: Uint8Array, key: Uint8Array, capabilityTicket: Uint8Array): Uint8Array {
  let payload = concat(utf8Bytes('{"version":1,"id":"gui-send","method":"message.send","params":{"identity":'), jsonString(identity));
  payload = concat(payload, utf8Bytes(',"to_bytes":'));
  payload = concat(payload, byteArrayJson(to));
  payload = concat(payload, utf8Bytes(',"text_bytes":'));
  payload = concat(payload, byteArrayJson(text));
  payload = concat(payload, utf8Bytes(',"idempotency_key_bytes":'));
  payload = concat(payload, byteArrayJson(key));
  payload = concat(payload, utf8Bytes(',"capability_ticket":'));
  payload = concat(payload, capabilityTicket.length === 0 ? utf8Bytes('null') : capabilityTicket);
  return concat(payload, utf8Bytes('}}'));
}

function sendPayload(model: Model): Uint8Array {
  return daemonMessagePayload(model.identityName, model.receiverId, model.message, utf8Bytes(`gui-${model.tickAt}-${model.history.length}`), model.capabilityTicket);
}

function replyPayload(model: Model): Uint8Array {
  return daemonMessagePayload(model.identityName, model.replyRoute, model.message, utf8Bytes(`gui-reply-${model.tickAt}-${model.history.length}`), model.capabilityTicket);
}

function replyTextPayload(model: Model, message: Uint8Array): Uint8Array {
  return concat(concat(model.replyRoute, new Uint8Array([10])), message);
}

function addChatMessage(model: Model, text: Uint8Array, sent: boolean, status: Uint8Array): Model {
  return { ...model, history: [...model.history, { id: utf8Bytes(`message-${model.history.length}`), text, sent, timestamp: utf8Bytes("just now"), status }] };
}

function setLastMessageStatus(model: Model, status: Uint8Array): Model {
  if (model.history.length === 0) return model;
  const history = model.history.slice();
  history[history.length - 1] = { ...history[history.length - 1], status };
  return { ...model, history };
}

function liveInviteMessage(action: Uint8Array, ticket: Uint8Array): Uint8Array {
  return concat(utf8Bytes("NUFON-LIVE/1\naction="), concat(action, concat(utf8Bytes("\nticket="), ticket)));
}

function recordingEnvelope(model: Model): Uint8Array {
  return concat(utf8Bytes("NUFON-RECORDING/1\nid="), concat(model.recordingTicket, concat(utf8Bytes("\ncodec=opus\nchannels=1\nsample_rate=48000\nduration_ms=0\nsender_id="), concat(model.endpointId, concat(utf8Bytes("\nticket="), model.recordingTicket)))));
}

function recordingPayload(model: Model): Uint8Array {
  return daemonMessagePayload(model.identityName, model.receiverId, recordingEnvelope(model), utf8Bytes(`recording-${model.tickAt}-${model.history.length}`), model.capabilityTicket);
}

function editText(text: Uint8Array, edit: TextInputEvent): Uint8Array {
  const next = applyTextInputEvent({ text, selection: { anchor: 1024, focus: 1024 }, composition: null }, edit, MAX_MESSAGE);
  return next === null ? text : next.text;
}

function byteIndex(data: Uint8Array, value: number, start: number): number {
  let i = start;
  while (i < data.length) {
    if (data[i] === value) return i;
    i += 1;
  }
  return -1;
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let i = 0;
  while (i < a.length) {
    if (a[i] !== b[i]) return false;
    i += 1;
  }
  return true;
}

function isSelfTarget(model: Model, target: Uint8Array): boolean {
  return model.endpointId.length !== 0 && sameBytes(model.endpointId, target);
}

function settle(model: Model): Model {
  const c = model.comms;
  return {
    ...model,
    audioActive: c.audio,
    liveActive: c.live,
    subscribedActive: c.subscribed,
    recordingActive: c.recording,
    recordingReady: c.recReady,
  };
}

function comUpdate(model: Model, patch: Partial<Comms>): Model {
  return settle({ ...model, comms: { ...model.comms, ...patch } });
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "connect_receiver":
      return [model, Cmd.request("nufond.request", contextPayload(model.identityName), { key: "nufond-context", ok: "daemon_ready", err: "daemon_error" })];
    case "identity_pressed":
      if (!model.receiverAvailable) return [
        { ...model, identitySelected: true },
        Cmd.request("nufond.request", contextPayload(model.identityName), { key: "nufond-context", ok: "daemon_ready", err: "daemon_error" }),
      ];
      if (model.receiverTicket.length === 0) return { ...model, identitySelected: true };
      return [{ ...model, identitySelected: true }, Cmd.batch([
        Cmd.clipboardWrite(model.receiverTicket),
        Cmd.showNotification({
          title: asciiBytes("Nufon ticket copied"),
          body: concat(asciiBytes("Endpoint: "), model.endpointId),
        }),
      ])];
    case "daemon_ready": {
      const ticket = contextTicket(msg.data);
      const next = { ...model, receiverStatus: utf8Bytes("Connected"), receiverTicket: ticket, receiverAvailable: true, copyIdentityTicket: false };
      if (model.copyIdentityTicket && ticket.length !== 0) return [next, Cmd.batch([
        Cmd.clipboardWrite(ticket),
        Cmd.showNotification({ title: asciiBytes("Identity ticket copied"), body: concat(asciiBytes("Identity: "), model.identityName) }),
      ])];
      return next;
    }
    case "daemon_error":
      return { ...model, receiverStatus: msg.data, receiverAvailable: false };
    case "capability_ticket_edit":
      return { ...model, capabilityTicketInput: editText(model.capabilityTicketInput, msg.edit), capabilityTicket: editText(model.capabilityTicketInput, msg.edit) };
    case "issue_capability_ticket":
      return [model, Cmd.request("nufond.request", capabilityTicketPayload(model.identityName), { key: "nufond-capability-ticket", ok: "capability_ticket_issued", err: "capability_ticket_error" })];
    case "capability_ticket_issued": {
      const ticket = extractTicket(msg.data);
      return { ...model, capabilityTicket: ticket, capabilityTicketInput: ticket };
    }
    case "capability_ticket_error":
      return { ...model, receiverStatus: msg.data };
    case "identities_loaded": {
      if (msg.data.length < 2) return model;
      const count = msg.data[0] * 256 + msg.data[1];
      let offset = 2;
      const identities: Identity[] = [];
      let index = 0;
      while (index < count && offset + 2 <= msg.data.length) {
        const length = msg.data[offset] * 256 + msg.data[offset + 1];
        offset += 2;
        if (offset + length + 1 > msg.data.length) break;
        identities.push({ name: msg.data.slice(offset, offset + length), active: msg.data[offset + length] !== 0 });
        offset += length + 1;
        index += 1;
      }
      let activeName = model.identityName;
      let identityIndex = 0;
      while (identityIndex < identities.length) {
        if (identities[identityIndex].active) activeName = identities[identityIndex].name;
        identityIndex += 1;
      }
      const next = { ...model, identities, identityName: activeName, newIdentityName: activeName, receiverTicket: EMPTY, endpointId: EMPTY, connections: NO_CONNECTIONS, receiverId: EMPTY, selectedConnectionName: EMPTY, senderDisabled: true, receiverAvailable: false, eventCursor: EMPTY, eventsReady: false };
      return [next, Cmd.batch([
        Cmd.request("nufond.request", contextPayload(activeName), { key: "nufond-context", ok: "daemon_ready", err: "daemon_error" }),
        Cmd.request("nufond.request", peersPayload(activeName), { key: "nufond-peers", ok: "peers_loaded", err: "daemon_error" }),
        Cmd.request("nufond.request", daemonEventsPayload(activeName, EMPTY), { key: "nufond-events", ok: "events_loaded", err: "daemon_error" }),
      ])];
    }
    case "identity_selected":
      return [{ ...model, identityName: msg.name, newIdentityName: msg.name, identities: model.identities.map((identity) => ({ ...identity, active: sameBytes(identity.name, msg.name) })), receiverTicket: EMPTY, endpointId: EMPTY, connections: NO_CONNECTIONS, receiverId: EMPTY, selectedConnectionName: EMPTY, senderDisabled: true, receiverAvailable: false, eventCursor: EMPTY, eventsReady: false, copyIdentityTicket: true }, Cmd.request("nufond.request", identityPayload(utf8Bytes("identity.use"), msg.name), { key: "nufond-identity-use", ok: "identity_used", err: "identity_use_error" })];
    case "show_add_identity":
      return { ...model, showAddIdentity: true, newIdentityName: EMPTY };
    case "cancel_add_identity":
      return { ...model, showAddIdentity: false };
    case "new_identity_name_edit":
      return { ...model, newIdentityName: editText(model.newIdentityName, msg.edit) };
    case "create_identity":
      if (model.newIdentityName.length === 0) return model;
      return [model, Cmd.request("nufond.request", identityPayload(utf8Bytes("identity.create"), model.newIdentityName), { key: "nufond-identity-create", ok: "identity_created", err: "identity_create_error" })];
    case "identity_created":
      return [{ ...model, identityName: model.newIdentityName, identities: model.identities.map((identity) => ({ ...identity, active: sameBytes(identity.name, model.newIdentityName) })), identitySelected: true, copyIdentityTicket: true, showAddIdentity: false }, Cmd.request("nufond.request", identityPayload(utf8Bytes("identity.use"), model.newIdentityName), { key: "nufond-identity-use", ok: "identity_used", err: "identity_use_error" })];
    case "identity_create_error":
      return { ...model, receiverStatus: msg.data };
    case "identity_used":
      return [{ ...model, identityName: model.newIdentityName, receiverTicket: EMPTY, endpointId: EMPTY, connections: NO_CONNECTIONS, receiverId: EMPTY, selectedConnectionName: EMPTY, senderDisabled: true, receiverAvailable: false, eventCursor: EMPTY, eventsReady: false }, Cmd.batch([
        Cmd.request("nufond.request", contextPayload(model.newIdentityName), { key: "nufond-context", ok: "daemon_ready", err: "daemon_error" }),
        Cmd.request("nufond.request", peersPayload(model.newIdentityName), { key: "nufond-peers", ok: "peers_loaded", err: "daemon_error" }),
        Cmd.request("nufond.request", daemonEventsPayload(model.newIdentityName, EMPTY), { key: "nufond-events", ok: "events_loaded", err: "daemon_error" }),
        Cmd.request("nufond.request", asciiBytes('{"version":1,"id":"gui-identities","method":"identities.compact","params":{}}'), { key: "nufond-identities", ok: "identities_loaded", err: "daemon_error" }),
      ])];
    case "identity_use_error":
      return { ...model, receiverStatus: msg.data };
    case "poll_events":
      return [{ ...model, tickAt: msg.at }, Cmd.request("nufond.request", daemonEventsPayload(model.identityName, model.eventCursor), { key: "nufond-events", ok: "events_loaded", err: "daemon_error" })];
    case "events_loaded": {
      if (msg.data.length < 2) return model;
      const count = msg.data[0] * 256 + msg.data[1];
      let offset = 2;
      let index = 0;
      let next = model;
      const acceptMessages = model.eventsReady;
      while (index < count && offset + 2 <= msg.data.length) {
        const cursorLength = msg.data[offset] * 256 + msg.data[offset + 1];
        offset += 2;
        if (offset + cursorLength + 2 > msg.data.length) break;
        const cursor = msg.data.slice(offset, offset + cursorLength);
        offset += cursorLength;
        const kindLength = msg.data[offset] * 256 + msg.data[offset + 1];
        offset += 2;
        if (offset + kindLength + 2 > msg.data.length) break;
        const kind = msg.data.slice(offset, offset + kindLength);
        offset += kindLength;
        const peerLength = msg.data[offset] * 256 + msg.data[offset + 1];
        offset += 2;
        if (offset + peerLength + 2 > msg.data.length) break;
        const peer = msg.data.slice(offset, offset + peerLength);
        offset += peerLength;
        const messageLength = msg.data[offset] * 256 + msg.data[offset + 1];
        offset += 2;
        if (offset + messageLength + 2 > msg.data.length) break;
        const message = msg.data.slice(offset, offset + messageLength);
        offset += messageLength;
        const textLength = msg.data[offset] * 256 + msg.data[offset + 1];
        offset += 2;
        if (offset + textLength > msg.data.length) break;
        const text = msg.data.slice(offset, offset + textLength);
        offset += textLength;
        next = { ...next, eventCursor: cursor };
        if (acceptMessages && sameBytes(kind, utf8Bytes("message.received")) && peer.length !== 0) {
          const livePrefix = utf8Bytes("NUFON-LIVE/1\naction=");
          const recordingPrefix = utf8Bytes("NUFON-RECORDING/1\n");
          if (text.length > livePrefix.length && sameBytes(text.slice(0, livePrefix.length), livePrefix)) {
            const actionEnd = byteIndex(text, 10, livePrefix.length);
            const ticketPrefix = utf8Bytes("\nticket=");
            if (actionEnd !== -1 && sameBytes(text.slice(actionEnd, actionEnd + ticketPrefix.length), ticketPrefix)) {
              const action = text.slice(livePrefix.length, actionEnd);
              const ticket = text.slice(actionEnd + ticketPrefix.length);
              const isStart = sameBytes(action, utf8Bytes("start"));
              const isStop = sameBytes(action, utf8Bytes("stop"));
              if ((isStart || isStop) && (!isStart || ticket.length !== 0)) {
                const incoming = { ...next, identitySelected: true, replyRoute: peer, liveTicketInput: ticket, sessionLaunch: { peerId: EMPTY, sessionId: peer, sessionType: utf8Bytes("chat") }, selectedConnectionName: utf8Bytes(isStart ? "Incoming call" : "Call ended"), chatOpen: true, receiverStatus: utf8Bytes(isStart ? "Incoming call" : "Call ended"), liveStatus: utf8Bytes(isStart ? (next.liveAutoAccept ? "Subscribing to live audio" : "Incoming live audio awaiting approval") : "Stopping live audio") };
                if (isStart && !next.liveAutoAccept) {
                  next = { ...incoming, livePolicyStatus: utf8Bytes("Incoming live audio blocked by local policy") };
                } else if (isStart) {
                  return [{ ...incoming, eventCursor: cursor, eventsReady: true }, Cmd.batch([
                    Cmd.request("media.live.subscribe", ticket, { key: "media-live-subscribe", ok: "live_subscribed", err: "live_subscribe_error" }),
                    Cmd.request("nufond.request", daemonMessagePayload(next.identityName, peer, utf8Bytes("call_started"), utf8Bytes(`call-started-${next.history.length}`), EMPTY), { key: "iroh-reply", ok: "sender_ready", err: "sender_error" }),
                  ])];
                } else {
                  return [{ ...incoming, eventCursor: cursor, eventsReady: true }, Cmd.batch([
                    Cmd.request("media.live.unsubscribe", EMPTY, { key: "media-live-subscribe", ok: "live_unsubscribed", err: "live_subscribe_error" }),
                    Cmd.request("nufond.request", daemonMessagePayload(next.identityName, peer, utf8Bytes("call_stopped"), utf8Bytes(`call-stopped-${next.history.length}`), EMPTY), { key: "iroh-reply", ok: "sender_ready", err: "sender_error" }),
                  ])];
                }
              }
            }
          } else if (text.length > recordingPrefix.length && sameBytes(text.slice(0, recordingPrefix.length), recordingPrefix)) {
            const ticket = recordingTicket(text);
            return [{ ...next, identitySelected: true, replyRoute: peer, sessionLaunch: { peerId: EMPTY, sessionId: peer, sessionType: utf8Bytes("chat") }, message: utf8Bytes("Received recording"), blobTicketInput: ticket, receiverStatus: utf8Bytes("Received recording"), senderStatus: utf8Bytes("Preparing recording"), selectedConnectionName: utf8Bytes("Incoming recording"), chatOpen: true, eventsReady: true }, Cmd.batch([
              Cmd.request("media.recording.persist", ticket, { key: "media-recording-persist", ok: "recording_persisted", err: "recording_persist_error" }),
              Cmd.request("media.blob.fetch", ticket, { key: "media-blob-fetch", ok: "blob_fetched", err: "blob_fetch_error" }),
            ])];
          } else {
            next = addChatMessage({ ...next, identitySelected: true, replyRoute: peer, sessionLaunch: { peerId: EMPTY, sessionId: peer, sessionType: utf8Bytes("chat") }, message: text, receiverStatus: utf8Bytes("Received: receiver_event"), senderStatus: utf8Bytes("Reply available"), selectedConnectionName: utf8Bytes("Incoming connection"), chatOpen: true }, text, false, utf8Bytes("Received"));
          }
        }
        index += 1;
      }
      return { ...next, eventsReady: true };
    }
    case "peers_loaded": {
      if (msg.data.length < 2) return { ...model, receiverStatus: utf8Bytes("Connected") };
      const count = msg.data[0] * 256 + msg.data[1];
      let offset = 2;
      const connections: Connection[] = [];
      let index = 0;
      while (index < count && offset + 2 <= msg.data.length) {
        const nameLength = msg.data[offset] * 256 + msg.data[offset + 1];
        offset += 2;
        if (offset + nameLength + 2 > msg.data.length) break;
        const name = msg.data.slice(offset, offset + nameLength);
        offset += nameLength;
        const endpointLength = msg.data[offset] * 256 + msg.data[offset + 1];
        offset += 2;
        if (offset + endpointLength > msg.data.length) break;
        const endpoint = msg.data.slice(offset, offset + endpointLength);
        offset += endpointLength;
        if (name.length !== 0 && endpoint.length !== 0) connections.push({ name, endpoint });
        index += 1;
      }
      return { ...model, connections, selectedConnectionName: connections.length === 0 ? EMPTY : connections[0].name, receiverStatus: utf8Bytes("Connected") };
    }
    case "receiver_ready": {
      const ticket = receiverTicket(msg.data);
      return [
        { ...model, identitySelected: true, identityError: false, receiverTicket: ticket, endpointId: endpointId(msg.data), receiverStatus: utf8Bytes("Available"), senderStatus: model.receiverId.length === 0 ? utf8Bytes("Add a connection") : model.senderStatus, receiverAvailable: true },
        Cmd.none,
      ];
    }
    case "receiver_error":
      return { ...model, identityError: true, receiverStatus: msg.data, receiverAvailable: false };
    case "receiver_event":
      if (msg.state !== "data") return model;
      {
        const fields = routedFields(msg.bytes);
        const route = fields[0];
        const message = decodeChatMessage(fields[1]);
        if (route.length === 0) return model;
        const livePrefix = utf8Bytes("NUFON-LIVE/1\naction=");
        if (message.length > livePrefix.length && sameBytes(message.slice(0, livePrefix.length), livePrefix)) {
          const actionEnd = byteIndex(message, 10, livePrefix.length);
          const ticketPrefix = utf8Bytes("\nticket=");
          if (actionEnd === -1 || !sameBytes(message.slice(actionEnd, actionEnd + ticketPrefix.length), ticketPrefix)) return model;
          const action = message.slice(livePrefix.length, actionEnd);
          const ticket = message.slice(actionEnd + ticketPrefix.length);
          const isStart = sameBytes(action, utf8Bytes("start"));
          const isStop = sameBytes(action, utf8Bytes("stop"));
          if (!isStart && !isStop) return model;
          if (isStart && ticket.length === 0) return model;
          const next = { ...model, identitySelected: true, replyRoute: route, liveTicketInput: ticket, sessionLaunch: { peerId: EMPTY, sessionId: route, sessionType: utf8Bytes("chat") }, selectedConnectionName: utf8Bytes(isStart ? "Incoming call" : "Call ended"), chatOpen: true, receiverStatus: utf8Bytes(isStart ? "Incoming call" : "Call ended"), liveStatus: utf8Bytes(isStart ? (model.liveAutoAccept ? "Subscribing to live audio" : "Incoming live audio awaiting approval") : "Stopping live audio") };
          if (isStart && !model.liveAutoAccept) return { ...next, livePolicyStatus: utf8Bytes("Incoming live audio blocked by local policy") };
          if (isStart) return [next, Cmd.batch([
            Cmd.request("media.live.subscribe", ticket, { key: "media-live-subscribe", ok: "live_subscribed", err: "live_subscribe_error" }),
            Cmd.request("nufond.request", daemonMessagePayload(model.identityName, route, utf8Bytes("call_started"), utf8Bytes(`call-started-${model.history.length}`), EMPTY), { key: "iroh-reply", ok: "sender_ready", err: "sender_error" }),
          ])];
          return [next, Cmd.batch([
            Cmd.request("media.live.unsubscribe", EMPTY, { key: "media-live-subscribe", ok: "live_unsubscribed", err: "live_subscribe_error" }),
            Cmd.request("nufond.request", daemonMessagePayload(model.identityName, route, utf8Bytes("call_stopped"), utf8Bytes(`call-stopped-${model.history.length}`), EMPTY), { key: "iroh-reply", ok: "sender_ready", err: "sender_error" }),
          ])];
        }
        const recordingPrefix = utf8Bytes("NUFON-RECORDING/1\n");
        if (message.length > recordingPrefix.length && sameBytes(message.slice(0, recordingPrefix.length), recordingPrefix)) {
          const ticket = recordingTicket(message);
          return [{ ...model, identitySelected: true, replyRoute: route, sessionLaunch: { peerId: EMPTY, sessionId: route, sessionType: utf8Bytes("chat") }, message: utf8Bytes("Received recording"), blobTicketInput: ticket, receiverStatus: utf8Bytes("Received recording"), senderStatus: utf8Bytes("Preparing recording"), selectedConnectionName: utf8Bytes("Incoming recording"), chatOpen: true }, Cmd.batch([
            Cmd.request("media.recording.persist", ticket, { key: "media-recording-persist", ok: "recording_persisted", err: "recording_persist_error" }),
            Cmd.request("media.blob.fetch", ticket, { key: "media-blob-fetch", ok: "blob_fetched", err: "blob_fetch_error" }),
          ])];
        }
        return addChatMessage({ ...model, identitySelected: true, replyRoute: route, sessionLaunch: { peerId: EMPTY, sessionId: route, sessionType: utf8Bytes("chat") }, message, receiverStatus: utf8Bytes("Received: receiver_event"), senderStatus: utf8Bytes("Reply available"), selectedConnectionName: utf8Bytes("Incoming connection"), chatOpen: true }, message, false, utf8Bytes("Received"));
      }
    case "connection_selected": {
      const connection = model.connections.find((item) => sameBytes(item.name, msg.name));
      if (connection === undefined) return model;
      const selfTarget = isSelfTarget(model, connection.endpoint);
      const next = { ...model, selectedConnectionName: connection.name, receiverId: connection.endpoint, senderDisabled: selfTarget, senderStatus: utf8Bytes(selfTarget ? "Cannot send to this identity" : "Ready") };
      return [next, Cmd.request("media.set_scope", connection.endpoint, { key: "media-scope", ok: "sender_ready", err: "sender_error" })];
    }
    case "connection_opened": {
      const connection = model.connections.find((item) => sameBytes(item.name, msg.name));
      if (connection === undefined) return model;
      const selfTarget = isSelfTarget(model, connection.endpoint);
      const next = { ...model, selectedConnectionName: connection.name, receiverId: connection.endpoint, sessionLaunch: { peerId: connection.endpoint, sessionId: connection.endpoint, sessionType: utf8Bytes("chat") }, senderDisabled: selfTarget, senderStatus: utf8Bytes(selfTarget ? "Cannot send to this identity" : "Ready"), chatOpen: true };
      return [next, Cmd.request("media.set_scope", connection.endpoint, { key: "media-scope", ok: "sender_ready", err: "sender_error" })];
    }
    case "chat_closed":
      return { ...model, chatOpen: false, sessionLaunch: null };
    case "message_edit":
      return { ...model, message: editText(model.message, msg.edit) };
    case "identity_name_edit":
      return { ...model, identityName: editText(model.identityName, msg.edit) };
    case "connection_name_edit":
      return { ...model, connectionName: editText(model.connectionName, msg.edit) };
    case "receiver_id_edit":
      return { ...model, receiverId: editText(model.receiverId, msg.edit) };
    case "copy_endpoint_id":
      if (model.receiverTicket.length === 0) return model;
      return [model, Cmd.clipboardWrite(model.receiverTicket)];
    case "show_add_connection":
      return { ...model, showAddConnection: true };
    case "cancel_add_connection":
      return { ...model, showAddConnection: false };
    case "toggle_live_auto_accept":
      return { ...model, liveAutoAccept: !model.liveAutoAccept, livePolicyStatus: utf8Bytes(model.liveAutoAccept ? "Incoming live audio requires approval" : "Incoming live audio auto-accepted") };
    case "add_connection":
      if (model.connectionName.length === 0 || model.receiverId.length === 0) return model;
      return [model, Cmd.request("nufond.request", peerAddPayload(model.identityName, model.connectionName, model.receiverId), { key: "nufond-peer-add", ok: "peer_added", err: "peer_add_error" })];
    case "peer_added": {
      const connection: Connection = { name: model.connectionName, endpoint: model.receiverId };
      const selfTarget = isSelfTarget(model, model.receiverId);
      return [{ ...model, connections: [...model.connections, connection], showAddConnection: false, senderDisabled: selfTarget, senderStatus: utf8Bytes(selfTarget ? "Cannot send to this identity" : "Ready") }, Cmd.request("media.set_scope", model.receiverId, { key: "media-scope", ok: "sender_ready", err: "sender_error" })];
    }
    case "peer_add_error":
      return { ...model, senderStatus: msg.data };
    case "send_message":
      if (model.recordingTicket.length !== 0) {
        if (model.receiverId.length === 0 || model.pendingRecordingSend) return model;
        if (isSelfTarget(model, model.receiverId)) return { ...model, senderStatus: utf8Bytes("Cannot send to this identity") };
        return [
        { ...model, pendingRecordingSend: true, recordingStatus: utf8Bytes("Sending attachment") },
        Cmd.request("nufond.request", recordingPayload(model), { key: "media-recording-send", ok: "sender_ready", err: "sender_error" }),
        ];
      }
      if (model.receiverId.length === 0 || model.message.length === 0) return model;
      if (isSelfTarget(model, model.receiverId)) return { ...model, senderStatus: utf8Bytes("Cannot send to this identity") };
      return [{ ...addChatMessage(model, model.message, true, utf8Bytes("Sending")), message: EMPTY }, Cmd.request("nufond.request", sendPayload(model), { key: "nufond-send", ok: "sender_ready", err: "sender_error" })];
    case "reply_message":
      if (model.replyRoute.length === 0 || model.message.length === 0) return model;
      if (isSelfTarget(model, model.replyRoute)) return { ...model, senderStatus: utf8Bytes("Cannot send to this identity") };
      return [{ ...addChatMessage(model, model.message, true, utf8Bytes("Sending")), message: EMPTY }, Cmd.request("nufond.request", replyPayload(model), { key: "nufond-reply", ok: "sender_ready", err: "sender_error" })];
    case "sender_ready":
      if (model.pendingRecordingSend) return { ...model, pendingRecordingSend: false, recordingReady: false, recordingTicket: EMPTY, recordingStatus: utf8Bytes("Audio sent"), senderStatus: utf8Bytes("Audio sent") };
      if (sameBytes(msg.data, utf8Bytes("call_stopped")) && model.liveActive) return [
        { ...model, senderStatus: utf8Bytes("Receiver ended call") },
        Cmd.request("media.live.stop", EMPTY, { key: "media-live", ok: "live_stopped", err: "live_error" }),
      ];
      return setLastMessageStatus({ ...model, senderStatus: msg.data.length === 0 ? utf8Bytes("Message sent") : msg.data }, utf8Bytes("Sent"));
    case "sender_error":
      return setLastMessageStatus({ ...model, pendingRecordingSend: false, senderStatus: msg.data }, utf8Bytes("Failed"));
    case "recording_persisted":
      return model;
    case "recording_persist_error":
      return { ...model, senderStatus: msg.data };
    case "audio_start":
      if (model.audioActive) return model;
      return [model, Cmd.request("media.audio.start", EMPTY, { key: "media-audio", ok: "audio_started", err: "audio_error" })];
    case "audio_stop":
      if (!model.audioActive) return model;
      return [model, Cmd.request("media.audio.stop", EMPTY, { key: "media-audio", ok: "audio_stopped", err: "audio_error" })];
    case "audio_emergency_stop":
      return [model, Cmd.request("media.emergency_stop", EMPTY, { key: "media-emergency", ok: "audio_emergency_stopped", err: "audio_error" })];
    case "toggle_advanced":
      return { ...model, showAdvanced: !model.showAdvanced };
    case "audio_started":
      return { ...comUpdate(model, { audio: true }), audioStatus: utf8Bytes("Microphone on") };
    case "audio_stopped":
      return { ...comUpdate(model, { audio: false }), audioStatus: utf8Bytes("Microphone off") };
    case "audio_error":
      return { ...comUpdate(model, { audio: false }), audioStatus: msg.data };
    case "audio_emergency_stopped":
      return { ...comUpdate(model, { audio: false, live: false, subscribed: false, recording: false, recReady: false }), playbackActive: false, audioStatus: utf8Bytes("Emergency stop"), liveStatus: utf8Bytes("Live audio stopped"), playbackStatus: utf8Bytes("Playback stopped") };
    case "audio_probe":
      return [model, Cmd.request("media.audio.probe", EMPTY, { key: "media-audio-probe", ok: "audio_probe_result", err: "audio_error" })];
    case "audio_probe_result":
      return { ...model, audioStatus: msg.data.length === 0 ? utf8Bytes("No input samples") : concat(utf8Bytes("Input samples: "), msg.data) };
    case "volume_edit":
      return { ...model, volumeInput: editText(model.volumeInput, msg.edit) };
    case "volume_set":
      return [model, Cmd.request("media.audio.set_volume", model.volumeInput, { key: "media-volume", ok: "sender_ready", err: "sender_error" })];
    case "live_start":
      if (model.liveActive || model.receiverId.length === 0) return model;
      return [model, Cmd.request("nufond.request", mediaSessionStartPayload(model), { key: "media-session", ok: "media_session_ready", err: "live_error" })];
    case "media_session_ready":
      return [model, Cmd.request("media.live.start", EMPTY, { key: "media-live", ok: "live_started", err: "live_error" })];
    case "live_stop":
      if (model.subscribedActive && !model.liveActive) {
        if (model.replyRoute.length === 0) return [model, Cmd.request("media.live.unsubscribe", EMPTY, { key: "media-live-subscribe", ok: "live_unsubscribed", err: "live_subscribe_error" })];
        return [model, Cmd.batch([
          Cmd.request("media.live.unsubscribe", EMPTY, { key: "media-live-subscribe", ok: "live_unsubscribed", err: "live_subscribe_error" }),
          Cmd.request("nufond.request", daemonMessagePayload(model.identityName, model.replyRoute, utf8Bytes("call_stopped"), utf8Bytes(`call-stopped-${model.history.length}`), EMPTY), { key: "iroh-reply", ok: "sender_ready", err: "sender_error" }),
        ])];
      }
      if (!model.liveActive) return model;
      if (model.receiverId.length === 0) return [model, Cmd.request("media.live.stop", EMPTY, { key: "media-live", ok: "live_stopped", err: "live_error" })];
      return [model, Cmd.batch([
        Cmd.request("nufond.request", daemonMessagePayload(model.identityName, model.receiverId, liveInviteMessage(utf8Bytes("stop"), EMPTY), utf8Bytes(`live-stop-${model.history.length}`), EMPTY), { key: "media-live-stop-signal", ok: "sender_ready", err: "sender_error" }),
        Cmd.request("media.live.stop", EMPTY, { key: "media-live", ok: "live_stopped", err: "live_error" }),
      ])];
    case "live_started":
      return [{ ...comUpdate(model, { live: true, audio: true }), audioStatus: utf8Bytes("Microphone on (live)"), liveTicket: msg.data, liveStatus: utf8Bytes("Calling receiver") }, Cmd.request("nufond.request", daemonMessagePayload(model.identityName, model.receiverId, liveInviteMessage(utf8Bytes("start"), msg.data), utf8Bytes(`live-start-${model.history.length}`), model.capabilityTicket), { key: "media-live-signal", ok: "sender_ready", err: "sender_error" })];
    case "copy_live_ticket":
      if (model.liveTicket.length === 0) return model;
      return [model, Cmd.clipboardWrite(model.liveTicket)];
    case "live_stopped":
      return { ...comUpdate({ ...model, audioStatus: utf8Bytes("Microphone off"), liveStatus: utf8Bytes("Live audio off") }, { live: false, audio: false }) };
    case "live_error":
      return { ...comUpdate({ ...model, liveStatus: msg.data }, { live: false }) };
    case "live_ticket_edit":
      return { ...model, liveTicketInput: editText(model.liveTicketInput, msg.edit) };
    case "live_subscribe":
      if (model.liveTicketInput.length === 0) return model;
      return [model, Cmd.request("media.live.subscribe", model.liveTicketInput, { key: "media-live-subscribe", ok: "live_subscribed", err: "live_subscribe_error" })];
    case "live_unsubscribe":
      if (!model.subscribedActive) return model;
      return [model, Cmd.request("media.live.unsubscribe", EMPTY, { key: "media-live-subscribe", ok: "live_unsubscribed", err: "live_subscribe_error" })];
    case "live_subscribed":
      return { ...comUpdate(model, { subscribed: true }), subscribedRecording: true, liveStatus: utf8Bytes("Live audio subscribed") };
    case "live_unsubscribed":
      return { ...comUpdate(model, { subscribed: false, recReady: model.subscribedRecording || model.recordingReady }), subscribedRecording: false, liveStatus: utf8Bytes("Live audio unsubscribed"), recordingStatus: model.subscribedRecording ? utf8Bytes("Recording ready") : model.recordingStatus };
    case "live_subscribe_error":
      return { ...model, liveStatus: msg.data };
    case "recording_start":
      if (model.recordingActive) return model;
      return [model, Cmd.request("media.recording.start", EMPTY, { key: "media-recording", ok: "recording_started", err: "recording_error" })];
    case "recording_stop":
      if (!model.recordingActive) return model;
      return [model, Cmd.request("media.recording.stop", EMPTY, { key: "media-recording", ok: "recording_stopped", err: "recording_error" })];
    case "recording_started":
      return { ...comUpdate(model, { recording: true }), recordingStatus: utf8Bytes("Recording microphone") };
    case "recording_stopped": {
      const next = { ...comUpdate(model, { recording: false, recReady: false }), subscribedRecording: false, recordingStatus: utf8Bytes("Preparing recording") };
      return [next, Cmd.request("media.live.recording.store", EMPTY, { key: "media-recording-store", ok: "recording_stored", err: "recording_store_error" })];
    }
    case "recording_error":
      return { ...comUpdate(model, { recording: false }), recordingStatus: msg.data };
    case "recording_store":
      if (!model.recordingReady) return model;
      return [model, Cmd.request("media.live.recording.store", EMPTY, { key: "media-recording-store", ok: "recording_stored", err: "recording_store_error" })];
    case "recording_stored": {
      const fields = routedFields(msg.data);
      return { ...comUpdate(model, { recReady: true }), senderDisabled: model.receiverId.length === 0, recordingDuration: fields[0], recordingStatus: utf8Bytes("Recording attached"), recordingTicket: fields[1] };
    }
    case "recording_cancel":
      return { ...comUpdate(model, { recReady: false }), pendingRecordingSend: false, recordingTicket: EMPTY, recordingStatus: utf8Bytes("Recording discarded") };
    case "copy_recording_ticket":
      if (model.recordingTicket.length === 0) return model;
      return [model, Cmd.clipboardWrite(model.recordingTicket)];
    case "recording_send":
      if (model.recordingTicket.length === 0 || model.receiverId.length === 0) return model;
      if (isSelfTarget(model, model.receiverId)) return { ...model, senderStatus: utf8Bytes("Cannot send to this identity") };
      return [model, Cmd.request("nufond.request", recordingPayload(model), { key: "media-recording-send", ok: "sender_ready", err: "sender_error" })];
    case "recording_store_error":
      return { ...model, recordingStatus: msg.data };
    case "blob_ticket_edit":
      return { ...model, blobTicketInput: editText(model.blobTicketInput, msg.edit) };
    case "blob_fetch":
      if (model.blobTicketInput.length === 0) return model;
      return [model, Cmd.request("media.blob.fetch", model.blobTicketInput, { key: "media-blob-fetch", ok: "blob_fetched", err: "blob_fetch_error" })];
    case "blob_fetched":
      return { ...model, fetchedRecordingReady: true, blobStatus: utf8Bytes("Recording ready"), senderStatus: utf8Bytes("Received recording ready") };
    case "blob_fetch_error":
      return { ...model, fetchedRecordingReady: false, blobStatus: msg.data, senderStatus: utf8Bytes("Could not receive recording") };
    case "playback_start":
      if (!model.fetchedRecordingReady) return model;
      return [model, Cmd.request("media.recording.play", EMPTY, { key: "media-playback", ok: "playback_started", err: "playback_error" })];
    case "playback_stop":
      return [model, Cmd.request("media.recording.stop_playback", EMPTY, { key: "media-playback", ok: "playback_stopped", err: "playback_error" })];
    case "playback_started":
      return { ...model, playbackActive: true, playbackStatus: utf8Bytes("Playing recording") };
    case "playback_stopped":
      return { ...model, playbackActive: false, playbackStatus: utf8Bytes("Playback stopped") };
    case "playback_error":
      return { ...model, playbackActive: false, playbackStatus: msg.data };
  }
}

export function commandMsg(name: string): Msg | null {
  return name === "chat.closed" ? { kind: "chat_closed" } : null;
}

export function windows(model: Model): readonly WindowDescriptor[] {
  if (!model.chatOpen) return [];
  return [windowDescriptor({
    label: asciiBytes("chat"),
    canvasLabel: asciiBytes("chat-canvas"),
    title: model.selectedConnectionName,
    width: 420,
    height: 420,
    closePolicy: "quit",
    onCloseCommand: asciiBytes("chat.closed"),
  })];
}
