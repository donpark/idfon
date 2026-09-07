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
  readonly audio: Uint8Array;
  readonly isAudio: boolean;
  readonly audioReady: boolean;
  readonly duration: Uint8Array;
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
  readonly identityInitials: Uint8Array;
  readonly incomingLive: boolean;
  readonly identities: readonly Identity[];
  readonly identitySelected: boolean;
  readonly copyIdentityTicket: boolean;
  readonly identityError: boolean;
  readonly connections: readonly Connection[];
  readonly selectedConnectionName: Uint8Array;
  readonly selectedConnectionInitials: Uint8Array;
  readonly sessionLaunch: SessionLaunch | null;
  readonly chatOpen: boolean;
  readonly avatarSheetOpen: boolean;
  readonly connectionName: Uint8Array;
  readonly receiverId: Uint8Array;
  readonly receiverTicket: Uint8Array;
  readonly capabilityTicket: Uint8Array;
  readonly capabilityTicketInput: Uint8Array;
  readonly endpointId: Uint8Array;
  readonly receiverStatus: Uint8Array;
  readonly bannerVisible: boolean;
  readonly bannerText: Uint8Array;
  readonly bannerExpiresAt: number;
  readonly receiverAvailable: boolean;
  readonly senderDisabled: boolean;
  readonly audioActive: boolean;
  readonly audioStatus: Uint8Array;
  readonly volumeInput: Uint8Array;
  readonly bitrateInput: Uint8Array;
  readonly liveActive: boolean;
  readonly subscribedActive: boolean;
  readonly callActive: boolean;
  readonly liveTicket: Uint8Array;
  readonly playingTicket: Uint8Array;
  readonly liveTicketInput: Uint8Array;
  readonly recordingStatus: Uint8Array;
  readonly recordingReady: boolean;
  readonly pendingRecordingSend: boolean;
  readonly subscribedRecording: boolean;
  readonly recordingActive: boolean;
  readonly recordingTicket: Uint8Array;
  readonly recordingDuration: Uint8Array;
  readonly recordingStartedAt: number;
  readonly recordingElapsed: Uint8Array;
  readonly composerActive: boolean;
  readonly composerIdle: boolean;
  readonly waveform: readonly number[];
  readonly historyEmpty: boolean;
  readonly comms: Comms;
  readonly blobTicketInput: Uint8Array;
  readonly blobStatus: Uint8Array;
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
  // Initial sync in progress: drain events.compact pages (empty-cursor load
  // after launch/identity switch) without rendering or side effects. Done
  // when a page returns zero events. Without this, pages 2+ of a large
  // history replay through the live-message path (blob fetches, "Incoming
  // recording/call" status) for events that arrived before the switch.
  readonly syncingEvents: boolean;
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
  | { readonly kind: "avatar_pressed" }
  | { readonly kind: "avatar_sheet_closed" }
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
  | { readonly kind: "attach_file" }
  | { readonly kind: "open_link"; readonly data: Uint8Array }

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
  | { readonly kind: "bitrate_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "set_audio_bitrate" }
  | { readonly kind: "live_answer" }
  | { readonly kind: "live_decline" }
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
  | { readonly kind: "recording_preview" }
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
  | { readonly kind: "playback_started"; readonly data: Uint8Array }
  | { readonly kind: "playback_stopped"; readonly data: Uint8Array }
  | { readonly kind: "playback_error"; readonly data: Uint8Array }
  | { readonly kind: "audio_toggle"; readonly data: Uint8Array }
  | { readonly kind: "audio_emergency_stopped"; readonly data: Uint8Array }
  | { readonly kind: "media_session_ready"; readonly data: Uint8Array }
  | { readonly kind: "events_loaded"; readonly data: Uint8Array }
  | { readonly kind: "events_sync_error"; readonly data: Uint8Array }
  | { readonly kind: "poll_events"; readonly at: number }
  | { readonly kind: "banner_dismiss" };

export const viewUnbound = [
  "replyRoute", "identityName", "identityInitials", "incomingLive", "copyIdentityTicket", "identityError", "chatOpen", "receiverTicket", "capabilityTicket", "endpointId", "audioActive", "pendingRecordingSend", "subscribedRecording", "showTicket", "liveAutoAccept", "eventCursor", "eventsReady",
  "receiverAvailable", "receiver_ready", "receiver_error", "receiver_event", "sender_ready", "sender_error", "daemon_ready", "daemon_error", "peers_loaded", "events_loaded", "events_sync_error", "poll_events", "tickAt",
  "recordingStartedAt", "connect_receiver", "recording_persisted", "recording_persist_error", "identity_name_edit", "identity_pressed", "identities_loaded", "identity_created", "identity_create_error", "identity_used", "identity_use_error", "events_sync_error", "chat_closed", "banner_dismiss", "bannerExpiresAt", "capability_ticket_issued", "capability_ticket_error", "copy_endpoint_id", "peer_added", "peer_add_error", "audio_start", "audio_stop", "audio_started", "audio_stopped", "audio_error", "audio_probe_result", "live_started", "live_stopped", "live_error", "live_subscribed", "live_unsubscribed", "live_subscribe_error", "recording_started", "recording_stopped", "recording_error", "recording_store", "recording_stored", "recording_send", "attach_file", "open_link", "recording_store_error", "blob_fetched", "blob_fetch_error", "playback_started", "playback_stopped", "playback_error", "audio_toggle", "audio_emergency_stopped", "media_session_ready", "bitrate_edit", "set_audio_bitrate", "bitrateInput",
] as const;

export function subscriptions(model: Model): Sub<Msg> {
  if (!model.receiverAvailable) return Sub.none;
  return Sub.timer("idfond-events", 1000, "poll_events");
}

export function initialModel(): Model | [Model, Cmd<Msg>] {
  const model: Model = {

    message: EMPTY,
    history: [],
    replyRoute: EMPTY,
    identityName: utf8Bytes("Default"),
    identityInitials: utf8Bytes("De"),
    incomingLive: false,
    identities: [{ name: utf8Bytes("Default"), active: true }],
    identitySelected: true,
    copyIdentityTicket: false,
    identityError: false,
    connections: NO_CONNECTIONS,
    selectedConnectionName: EMPTY,
    selectedConnectionInitials: EMPTY,
    sessionLaunch: null,
    chatOpen: false,
    avatarSheetOpen: false,
    connectionName: EMPTY,
    receiverId: EMPTY,
    receiverTicket: EMPTY,
    capabilityTicket: EMPTY,
    capabilityTicketInput: EMPTY,
    endpointId: EMPTY,
    receiverStatus: utf8Bytes("Connecting"),
    bannerVisible: false,
    bannerText: EMPTY,
    bannerExpiresAt: 0,
    receiverAvailable: false,
    senderDisabled: true,
    audioActive: false,
    audioStatus: utf8Bytes("Microphone off"),
    volumeInput: utf8Bytes("100"),
    bitrateInput: utf8Bytes("32"),
    liveActive: false,
    subscribedActive: false,
    callActive: false,
    liveTicket: EMPTY,
    playingTicket: EMPTY,
    liveTicketInput: EMPTY,
    recordingStatus: utf8Bytes("No recording"),
    recordingReady: false,
    pendingRecordingSend: false,
    subscribedRecording: false,
    recordingActive: false,
    recordingTicket: EMPTY,
    recordingDuration: utf8Bytes("0"),
    recordingStartedAt: 0,
    recordingElapsed: utf8Bytes("0:00"),
    composerActive: false,
    composerIdle: true,
    waveform: [],
    historyEmpty: true,
    comms: { audio: false, live: false, subscribed: false, recording: false, recReady: false },
    blobTicketInput: EMPTY,
    blobStatus: utf8Bytes("No blob selected"),
    showAdvanced: false,
    showTicket: false,
    showAddConnection: false,
    showAddIdentity: false,
    newIdentityName: EMPTY,
    // ponytail: explicit Answer button replaced auto-accept now that calls have header controls
    liveAutoAccept: false,
    livePolicyStatus: utf8Bytes("Incoming live audio requires approval"),
    eventCursor: EMPTY,
    tickAt: 0,
    eventsReady: false,
    syncingEvents: false,
  };
  return [model, Cmd.request("idfond.request", asciiBytes('{"version":1,"id":"gui-identities","method":"identities.compact","params":{}}'), { key: "idfond-identities", ok: "identities_loaded", err: "daemon_error" })];
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
  return concat(concat(utf8Bytes('{"version":1,"id":"gui-capability-ticket","method":"capability.ticket","params":{"identity":'), jsonString(identity)), utf8Bytes(',"capabilities":["message_receive","live_audio_subscribe"]}}'));
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

function identityInitials(name: Uint8Array): Uint8Array {
  // ponytail: ASCII-only initials slice; identity names are ASCII in this prototype
  return name.slice(0, name.length > 2 ? 2 : name.length);
}

function addChatMessage(model: Model, text: Uint8Array, sent: boolean, status: Uint8Array): Model {
  return comUpdate({ ...model, history: [...model.history, { id: utf8Bytes(`message-${model.history.length}`), text, sent, timestamp: utf8Bytes("just now"), status, audio: EMPTY, isAudio: false, audioReady: false, duration: EMPTY }] }, {});
}

function addAudioMessage(model: Model, ticket: Uint8Array, sent: boolean, ready: boolean, duration: Uint8Array): Model {
  return comUpdate({ ...model, history: [...model.history, { id: utf8Bytes(`message-${model.history.length}`), text: utf8Bytes("Voice message"), sent, timestamp: utf8Bytes("just now"), status: utf8Bytes(""), audio: ticket, isAudio: true, audioReady: ready, duration }] }, {});
}

function setLastMessageStatus(model: Model, status: Uint8Array): Model {
  if (model.history.length === 0) return model;
  const history = model.history.slice();
  history[history.length - 1] = { ...history[history.length - 1], status };
  return comUpdate({ ...model, history }, {});
}

function digitsToNumber(data: Uint8Array): number {
  if (data.length === 0) return -1;
  let value = 0;
  let i = 0;
  while (i < data.length) {
    const byte = data[i];
    if (byte < 48 || byte > 57) return -1;
    value = value * 10 + byte - 48;
    i += 1;
  }
  return value;
}

function secondsLabel(seconds: number): Uint8Array {
  const pad = seconds % 60 < 10 ? "0" : "";
  return utf8Bytes(`${Math.floor(seconds / 60)}:${pad}${seconds % 60}`);
}

function envelopeField(text: Uint8Array, field: Uint8Array): Uint8Array {
  // value bytes of "field=" from an envelope header block
  let i = 0;
  while (i + field.length + 1 <= text.length) {
    const start = i === 0 ? 0 : i + 1;
    if ((i === 0 || text[i] === 10) && start + field.length + 1 <= text.length
      && sameBytes(text.slice(start, start + field.length), field)
      && text[start + field.length] === 61) {
      let end = start + field.length + 1;
      while (end < text.length && text[end] !== 10) end += 1;
      return text.slice(start + field.length + 1, end);
    }
    i += 1;
  }
  return EMPTY;
}

function recordingDurationLabel(envelope: Uint8Array): Uint8Array {
  const ms = digitsToNumber(envelopeField(envelope, utf8Bytes("duration_ms")));
  return ms > 0 ? secondsLabel(Math.floor(ms / 1000)) : EMPTY;
}

function liveInviteMessage(action: Uint8Array, ticket: Uint8Array): Uint8Array {
  return concat(utf8Bytes("IDFON-LIVE/1\naction="), concat(action, concat(utf8Bytes("\nticket="), ticket)));
}

function recordingEnvelope(model: Model): Uint8Array {
  const seconds = digitsToNumber(model.recordingDuration);
  const ms = seconds > 0 ? seconds * 1000 : 0;
  return concat(utf8Bytes("IDFON-RECORDING/1\nid="), concat(model.recordingTicket, concat(utf8Bytes("\ncodec=opus\nchannels=1\nsample_rate=48000\nduration_ms="), concat(utf8Bytes(`${ms}`), concat(utf8Bytes("\nsender_id="), concat(model.endpointId, concat(utf8Bytes("\nticket="), model.recordingTicket)))))));
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

// Once a peer reaches us, the conversation is symmetric: adopt them as the
// send target so composer/call actions work without the user having added
// them as a connection first. Never override an existing selection.
function withInboundTarget(model: Model, peer: Uint8Array): Model {
  if (model.receiverId.length !== 0) return model;
  return { ...model, receiverId: peer, senderDisabled: isSelfTarget(model, peer) };
}

// The chat window's message banner (below the header): one visible notice at a
// time, auto-expiring after BANNER_TTL_MS via the 1s events poll (so expiry
// pauses while disconnected). A new banner replaces the standing one.
const BANNER_TTL_MS = 5000;

function showBanner(model: Model, text: Uint8Array): Model {
  if (text.length === 0) return { ...model, bannerVisible: false };
  return { ...model, bannerVisible: true, bannerText: text, bannerExpiresAt: model.tickAt + BANNER_TTL_MS };
}

function hideBanner(model: Model): Model {
  return { ...model, bannerVisible: false };
}

// Target-state banner: selecting a self-target peer is a standing warning;
// selecting a valid one clears whatever stale notice was up.
function targetBanner(model: Model, selfTarget: boolean): Model {
  return selfTarget ? showBanner(model, utf8Bytes("Cannot send to this identity")) : hideBanner(model);
}

function waveformBars(phase: number): readonly number[] {
  // ponytail: deterministic bar pattern stepped by the 1s event poll, not
  // real mic levels; drive from the recorder peak via a faster timer if
  // true levels matter
  const bars: number[] = [];
  let i = 0;
  while (i < 28) {
    const h = (i * 37 + phase * 53) % 89;
    bars.push(0.15 + (h / 89) * 0.85);
    i += 1;
  }
  return bars;
}

function settle(model: Model): Model {
  const c = model.comms;
  const callActive = c.live || c.subscribed;
  return {
    ...model,
    audioActive: c.audio,
    liveActive: c.live,
    subscribedActive: c.subscribed,
    callActive,
    recordingActive: c.recording,
    recordingReady: c.recReady,
    composerActive: model.message.length > 0,
    composerIdle: !c.recording && !c.recReady,
    historyEmpty: model.history.length === 0,
  };
}

function comUpdate(model: Model, patch: Partial<Comms>): Model {
  // SC4013: spreading a Partial<Comms> parameter stamps undefined onto
  // absent fields at runtime; merge each field explicitly instead.
  return settle({ ...model, comms: {
    audio: patch.audio ?? model.comms.audio,
    live: patch.live ?? model.comms.live,
    subscribed: patch.subscribed ?? model.comms.subscribed,
    recording: patch.recording ?? model.comms.recording,
    recReady: patch.recReady ?? model.comms.recReady,
  } });
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "connect_receiver":
      return [model, Cmd.request("idfond.request", contextPayload(model.identityName), { key: "idfond-context", ok: "daemon_ready", err: "daemon_error" })];
    case "identity_pressed":
      if (!model.receiverAvailable) return [
        { ...model, identitySelected: true },
        Cmd.request("idfond.request", contextPayload(model.identityName), { key: "idfond-context", ok: "daemon_ready", err: "daemon_error" }),
      ];
      if (model.receiverTicket.length === 0) return { ...model, identitySelected: true };
      return [{ ...model, identitySelected: true }, Cmd.batch([
        Cmd.clipboardWrite(model.receiverTicket),
        Cmd.showNotification({
          title: asciiBytes("Idfon ticket copied"),
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
      return [model, Cmd.request("idfond.request", capabilityTicketPayload(model.identityName), { key: "idfond-capability-ticket", ok: "capability_ticket_issued", err: "capability_ticket_error" })];
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
      const next = { ...model, identities, identityName: activeName, identityInitials: identityInitials(activeName), newIdentityName: activeName, receiverTicket: EMPTY, endpointId: EMPTY, connections: NO_CONNECTIONS, receiverId: EMPTY, selectedConnectionName: EMPTY, selectedConnectionInitials: identityInitials(EMPTY), senderDisabled: true, receiverAvailable: false, eventCursor: EMPTY, eventsReady: false, syncingEvents: true };
      return [next, Cmd.batch([
        Cmd.request("idfond.request", contextPayload(activeName), { key: "idfond-context", ok: "daemon_ready", err: "daemon_error" }),
        Cmd.request("idfond.request", peersPayload(activeName), { key: "idfond-peers", ok: "peers_loaded", err: "daemon_error" }),
        Cmd.request("idfond.request", daemonEventsPayload(activeName, EMPTY), { key: "idfond-events", ok: "events_loaded", err: "daemon_error" }),
      ])];
    }
    case "identity_selected":
      return [{ ...model, identityName: msg.name, identityInitials: identityInitials(msg.name), newIdentityName: msg.name, identities: model.identities.map((identity) => ({ ...identity, active: sameBytes(identity.name, msg.name) })), receiverTicket: EMPTY, endpointId: EMPTY, connections: NO_CONNECTIONS, receiverId: EMPTY, selectedConnectionName: EMPTY, selectedConnectionInitials: identityInitials(EMPTY), senderDisabled: true, receiverAvailable: false, eventCursor: EMPTY, eventsReady: false, syncingEvents: true, copyIdentityTicket: true }, Cmd.request("idfond.request", identityPayload(utf8Bytes("identity.use"), msg.name), { key: "idfond-identity-use", ok: "identity_used", err: "identity_use_error" })];
    case "show_add_identity":
      return { ...model, showAddIdentity: true, newIdentityName: EMPTY };
    case "cancel_add_identity":
      return { ...model, showAddIdentity: false };
    case "new_identity_name_edit":
      return { ...model, newIdentityName: editText(model.newIdentityName, msg.edit) };
    case "create_identity":
      if (model.newIdentityName.length === 0) return model;
      return [model, Cmd.request("idfond.request", identityPayload(utf8Bytes("identity.create"), model.newIdentityName), { key: "idfond-identity-create", ok: "identity_created", err: "identity_create_error" })];
    case "identity_created":
      return [{ ...model, identityName: model.newIdentityName, identityInitials: identityInitials(model.newIdentityName), identities: model.identities.map((identity) => ({ ...identity, active: sameBytes(identity.name, model.newIdentityName) })), identitySelected: true, copyIdentityTicket: true, showAddIdentity: false }, Cmd.request("idfond.request", identityPayload(utf8Bytes("identity.use"), model.newIdentityName), { key: "idfond-identity-use", ok: "identity_used", err: "identity_use_error" })];
    case "identity_create_error":
      return { ...model, receiverStatus: msg.data };
    case "identity_used":
      return [{ ...model, identityName: model.newIdentityName, identityInitials: identityInitials(model.newIdentityName), receiverTicket: EMPTY, endpointId: EMPTY, connections: NO_CONNECTIONS, receiverId: EMPTY, selectedConnectionName: EMPTY, selectedConnectionInitials: identityInitials(EMPTY), senderDisabled: true, receiverAvailable: false, eventCursor: EMPTY, eventsReady: false, syncingEvents: true }, Cmd.batch([
        Cmd.request("idfond.request", contextPayload(model.newIdentityName), { key: "idfond-context", ok: "daemon_ready", err: "daemon_error" }),
        Cmd.request("idfond.request", peersPayload(model.newIdentityName), { key: "idfond-peers", ok: "peers_loaded", err: "daemon_error" }),
        Cmd.request("idfond.request", daemonEventsPayload(model.newIdentityName, EMPTY), { key: "idfond-events", ok: "events_loaded", err: "daemon_error" }),
        Cmd.request("idfond.request", asciiBytes('{"version":1,"id":"gui-identities","method":"identities.compact","params":{}}'), { key: "idfond-identities", ok: "identities_loaded", err: "daemon_error" }),
      ])];
    case "identity_use_error":
      return { ...model, receiverStatus: msg.data };
    case "events_sync_error":
      // End the swallow so the 1s poll can retry; eventsReady stays false so
      // the retry page still isn't rendered as live.
      return { ...model, syncingEvents: false };
    case "poll_events": {
      const elapsed = msg.at > model.recordingStartedAt ? msg.at - model.recordingStartedAt : 0;
      const seconds = Math.floor(elapsed / 1000);
      const mm = Math.floor(seconds / 60);
      const ss = seconds % 60;
      const pad = ss < 10 ? "0" : "";
      const expired = model.bannerVisible && msg.at >= model.bannerExpiresAt;
      const base = expired ? hideBanner(model) : model;
      return [{ ...base, tickAt: msg.at, recordingElapsed: utf8Bytes(`${mm}:${pad}${ss}`), waveform: waveformBars(seconds) }, Cmd.request("idfond.request", daemonEventsPayload(base.identityName, base.eventCursor), { key: "idfond-events", ok: "events_loaded", err: "daemon_error" })];
    }
    case "banner_dismiss":
      return { ...model, bannerVisible: false };
    case "events_loaded": {
      if (msg.data.length < 2) return model;
      const count = msg.data[0] * 256 + msg.data[1];
      if (model.syncingEvents) {
        if (count === 0) return { ...model, syncingEvents: false, eventsReady: true };
        let syncOffset = 2;
        let syncCursor = model.eventCursor;
        let syncIndex = 0;
        while (syncIndex < count && syncOffset + 2 <= msg.data.length) {
          const cursorLength = msg.data[syncOffset] * 256 + msg.data[syncOffset + 1];
          syncOffset += 2;
          if (syncOffset + cursorLength > msg.data.length) break;
          syncCursor = msg.data.slice(syncOffset, syncOffset + cursorLength);
          syncOffset += cursorLength;
          let field = 0;
          while (field < 4 && syncOffset + 2 <= msg.data.length) {
            syncOffset += 2 + msg.data[syncOffset] * 256 + msg.data[syncOffset + 1];
            field += 1;
          }
          syncIndex += 1;
        }
        return [{ ...model, eventCursor: syncCursor }, Cmd.request("idfond.request", daemonEventsPayload(model.identityName, syncCursor), { key: "idfond-events", ok: "events_loaded", err: "events_sync_error" })];
      }
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
          next = withInboundTarget(next, peer);
          const livePrefix = utf8Bytes("IDFON-LIVE/1\naction=");
          const recordingPrefix = utf8Bytes("IDFON-RECORDING/1\n");
          if (text.length > livePrefix.length && sameBytes(text.slice(0, livePrefix.length), livePrefix)) {
            const actionEnd = byteIndex(text, 10, livePrefix.length);
            const ticketPrefix = utf8Bytes("\nticket=");
            if (actionEnd !== -1 && sameBytes(text.slice(actionEnd, actionEnd + ticketPrefix.length), ticketPrefix)) {
              const action = text.slice(livePrefix.length, actionEnd);
              const ticket = text.slice(actionEnd + ticketPrefix.length);
              const isStart = sameBytes(action, utf8Bytes("start"));
              const isStop = sameBytes(action, utf8Bytes("stop"));
              if ((isStart || isStop) && (!isStart || ticket.length !== 0)) {
                const incoming = showBanner({ ...next, identitySelected: true, replyRoute: peer, liveTicketInput: ticket, sessionLaunch: { peerId: EMPTY, sessionId: peer, sessionType: utf8Bytes("chat") }, selectedConnectionName: utf8Bytes(isStart ? "Incoming call" : "Call ended"), selectedConnectionInitials: identityInitials(utf8Bytes(isStart ? "Incoming call" : "Call ended")), chatOpen: true, receiverStatus: utf8Bytes(isStart ? "Incoming call" : "Call ended"), incomingLive: isStart }, utf8Bytes(isStart ? "Incoming call" : "Call ended"));
                if (isStart) {
                  return [{ ...incoming, eventCursor: cursor, eventsReady: true }, Cmd.none];
                }
                return [{ ...incoming, eventCursor: cursor, eventsReady: true }, Cmd.batch([
                  Cmd.request("media.live.unsubscribe", EMPTY, { key: "media-live-subscribe", ok: "live_unsubscribed", err: "live_subscribe_error" }),
                  Cmd.request("idfond.request", daemonMessagePayload(next.identityName, peer, utf8Bytes("call_stopped"), utf8Bytes(`call-stopped-${next.history.length}`), EMPTY), { key: "iroh-reply", ok: "sender_ready", err: "sender_error" }),
                ])];
              }
            }
          } else if (text.length > recordingPrefix.length && sameBytes(text.slice(0, recordingPrefix.length), recordingPrefix)) {
            const ticket = recordingTicket(text);
            const withAudio = addAudioMessage(showBanner({ ...next, identitySelected: true, replyRoute: peer, sessionLaunch: { peerId: EMPTY, sessionId: peer, sessionType: utf8Bytes("chat") }, blobTicketInput: ticket, receiverStatus: utf8Bytes("Received recording"), selectedConnectionName: utf8Bytes("Incoming recording"), selectedConnectionInitials: identityInitials(utf8Bytes("Incoming recording")), chatOpen: true, eventsReady: true }, utf8Bytes("Preparing recording")), ticket, false, false, recordingDurationLabel(text));
            return [withAudio, Cmd.batch([
              Cmd.request("media.recording.persist", ticket, { key: "media-recording-persist", ok: "recording_persisted", err: "recording_persist_error" }),
              Cmd.request("media.blob.fetch", ticket, { key: "media-blob-fetch", ok: "blob_fetched", err: "blob_fetch_error" }),
            ])];
          } else {
            next = addChatMessage({ ...next, identitySelected: true, replyRoute: peer, sessionLaunch: { peerId: EMPTY, sessionId: peer, sessionType: utf8Bytes("chat") }, receiverStatus: utf8Bytes("Connected"), selectedConnectionName: utf8Bytes("Incoming connection"), selectedConnectionInitials: identityInitials(utf8Bytes("Incoming connection")), chatOpen: true }, text, false, utf8Bytes("Received"));
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
      return { ...model, connections, selectedConnectionName: connections.length === 0 ? EMPTY : connections[0].name, selectedConnectionInitials: identityInitials(connections.length === 0 ? EMPTY : connections[0].name), receiverStatus: utf8Bytes("Connected") };
    }
    case "receiver_ready": {
      const ticket = receiverTicket(msg.data);
      const connected = { ...model, identitySelected: true, identityError: false, receiverTicket: ticket, endpointId: endpointId(msg.data), receiverStatus: utf8Bytes("Available"), receiverAvailable: true };
      return [model.receiverId.length === 0 ? showBanner(connected, utf8Bytes("Add a connection")) : connected, Cmd.none];
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
        const inbound = withInboundTarget(model, route);
        const livePrefix = utf8Bytes("IDFON-LIVE/1\naction=");
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
          const next = showBanner({ ...inbound, identitySelected: true, replyRoute: route, liveTicketInput: ticket, sessionLaunch: { peerId: EMPTY, sessionId: route, sessionType: utf8Bytes("chat") }, selectedConnectionName: utf8Bytes(isStart ? "Incoming call" : "Call ended"), selectedConnectionInitials: identityInitials(utf8Bytes(isStart ? "Incoming call" : "Call ended")), chatOpen: true, receiverStatus: utf8Bytes(isStart ? "Incoming call" : "Call ended"), incomingLive: isStart }, utf8Bytes(isStart ? "Incoming call" : "Call ended"));
          if (isStart) return [next, Cmd.none];
          return [next, Cmd.batch([
            Cmd.request("media.live.unsubscribe", EMPTY, { key: "media-live-subscribe", ok: "live_unsubscribed", err: "live_subscribe_error" }),
            Cmd.request("idfond.request", daemonMessagePayload(model.identityName, route, utf8Bytes("call_stopped"), utf8Bytes(`call-stopped-${model.history.length}`), EMPTY), { key: "iroh-reply", ok: "sender_ready", err: "sender_error" }),
          ])];
        }
        const recordingPrefix = utf8Bytes("IDFON-RECORDING/1\n");
        if (message.length > recordingPrefix.length && sameBytes(message.slice(0, recordingPrefix.length), recordingPrefix)) {
          const ticket = recordingTicket(message);
          const withAudio = addAudioMessage(showBanner({ ...inbound, identitySelected: true, replyRoute: route, sessionLaunch: { peerId: EMPTY, sessionId: route, sessionType: utf8Bytes("chat") }, blobTicketInput: ticket, receiverStatus: utf8Bytes("Received recording"), selectedConnectionName: utf8Bytes("Incoming recording"), selectedConnectionInitials: identityInitials(utf8Bytes("Incoming recording")), chatOpen: true }, utf8Bytes("Preparing recording")), ticket, false, false, recordingDurationLabel(message));
          return [withAudio, Cmd.batch([
            Cmd.request("media.recording.persist", ticket, { key: "media-recording-persist", ok: "recording_persisted", err: "recording_persist_error" }),
            Cmd.request("media.blob.fetch", ticket, { key: "media-blob-fetch", ok: "blob_fetched", err: "blob_fetch_error" }),
          ])];
        }
        return addChatMessage({ ...inbound, identitySelected: true, replyRoute: route, sessionLaunch: { peerId: EMPTY, sessionId: route, sessionType: utf8Bytes("chat") }, receiverStatus: utf8Bytes("Connected"), selectedConnectionName: utf8Bytes("Incoming connection"), selectedConnectionInitials: identityInitials(utf8Bytes("Incoming connection")), chatOpen: true }, message, false, utf8Bytes("Received"));
      }
    case "connection_selected": {
      const connection = model.connections.find((item) => sameBytes(item.name, msg.name));
      if (connection === undefined) return model;
      const selfTarget = isSelfTarget(model, connection.endpoint);
      const next = { ...model, selectedConnectionName: connection.name, selectedConnectionInitials: identityInitials(connection.name), receiverId: connection.endpoint, senderDisabled: selfTarget };
      return [targetBanner(next, selfTarget), Cmd.request("media.set_scope", connection.endpoint, { key: "media-scope", ok: "sender_ready", err: "sender_error" })];
    }
    case "connection_opened": {
      const connection = model.connections.find((item) => sameBytes(item.name, msg.name));
      if (connection === undefined) return model;
      const selfTarget = isSelfTarget(model, connection.endpoint);
      const next = { ...model, selectedConnectionName: connection.name, selectedConnectionInitials: identityInitials(connection.name), receiverId: connection.endpoint, sessionLaunch: { peerId: connection.endpoint, sessionId: connection.endpoint, sessionType: utf8Bytes("chat") }, senderDisabled: selfTarget, chatOpen: true };
      return [targetBanner(next, selfTarget), Cmd.request("media.set_scope", connection.endpoint, { key: "media-scope", ok: "sender_ready", err: "sender_error" })];
    }
    case "chat_closed":
      return { ...model, chatOpen: false, sessionLaunch: null };
    case "avatar_pressed":
      return { ...model, avatarSheetOpen: true };
    case "avatar_sheet_closed":
      return { ...model, avatarSheetOpen: false };
    case "message_edit": {
      const edited = editText(model.message, msg.edit);
      return comUpdate({ ...model, message: edited }, {});
    }
    case "identity_name_edit":
      return { ...model, identityName: editText(model.identityName, msg.edit), identityInitials: identityInitials(editText(model.identityName, msg.edit)) };
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
      return [model, Cmd.request("idfond.request", peerAddPayload(model.identityName, model.connectionName, model.receiverId), { key: "idfond-peer-add", ok: "peer_added", err: "peer_add_error" })];
    case "peer_added": {
      const connection: Connection = { name: model.connectionName, endpoint: model.receiverId };
      const selfTarget = isSelfTarget(model, model.receiverId);
      return [targetBanner({ ...model, connections: [...model.connections, connection], showAddConnection: false, senderDisabled: selfTarget }, selfTarget), Cmd.request("media.set_scope", model.receiverId, { key: "media-scope", ok: "sender_ready", err: "sender_error" })];
    }
    case "peer_add_error":
      return showBanner(model, msg.data);
    case "send_message":
      if (model.recordingTicket.length !== 0) {
        if (model.receiverId.length === 0 || model.pendingRecordingSend) return model;
        if (isSelfTarget(model, model.receiverId)) return targetBanner(model, true);
        return [
        { ...model, pendingRecordingSend: true, recordingStatus: utf8Bytes("Sending attachment") },
        Cmd.request("idfond.request", recordingPayload(model), { key: "media-recording-send", ok: "sender_ready", err: "sender_error" }),
        ];
      }
      if (model.receiverId.length === 0 || model.message.length === 0) return model;
      if (isSelfTarget(model, model.receiverId)) return targetBanner(model, true);
      return [{ ...addChatMessage(model, model.message, true, utf8Bytes("Sending")), message: EMPTY }, Cmd.request("idfond.request", sendPayload(model), { key: "idfond-send", ok: "sender_ready", err: "sender_error" })];
    case "open_link":
      if (msg.data.length === 0) return model;
      return [model, Cmd.openExternalUrl(msg.data)];
    case "attach_file":
      return showBanner(model, utf8Bytes("File attachments not supported yet"));
    case "sender_ready":
      if (model.pendingRecordingSend) {
        // clear comms.recReady too — settle() re-derives the attachment row from it, and a stale true resurrects the old attachment mid-next-recording
        const cleared = comUpdate(model, { recReady: false });
        const seconds = digitsToNumber(model.recordingDuration);
        return addAudioMessage(showBanner({ ...cleared, pendingRecordingSend: false, recordingTicket: EMPTY, recordingStatus: utf8Bytes("Audio sent") }, utf8Bytes("Audio sent")), model.recordingTicket, true, true, seconds > 0 ? secondsLabel(seconds) : EMPTY);
      }
      if (sameBytes(msg.data, utf8Bytes("call_stopped")) && model.liveActive) return [
        showBanner(model, utf8Bytes("Receiver ended call")),
        Cmd.request("media.live.stop", EMPTY, { key: "media-live", ok: "live_stopped", err: "live_error" }),
      ];
      if (sameBytes(msg.data, utf8Bytes("media_scope_set"))) return { ...model, bannerVisible: false };
      // ok data from idfond.request paths is the daemon's JSON response envelope
      return setLastMessageStatus(showBanner(model, utf8Bytes("Message sent")), utf8Bytes("Sent"));
    case "sender_error":
      return setLastMessageStatus(showBanner({ ...model, pendingRecordingSend: false }, msg.data), utf8Bytes("Failed"));
    case "recording_persisted":
      return model;
    case "recording_persist_error":
      return showBanner(model, msg.data);
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
      return showBanner({ ...comUpdate(model, { audio: false, live: false, subscribed: false, recording: false, recReady: false }), audioStatus: utf8Bytes("Emergency stop") }, utf8Bytes("Emergency stop"));
    case "audio_probe":
      return [model, Cmd.request("media.audio.probe", EMPTY, { key: "media-audio-probe", ok: "audio_probe_result", err: "audio_error" })];
    case "audio_probe_result":
      return { ...model, audioStatus: msg.data.length === 0 ? utf8Bytes("No input samples") : concat(utf8Bytes("Input samples: "), msg.data) };
    case "volume_edit":
      return { ...model, volumeInput: editText(model.volumeInput, msg.edit) };
    case "volume_set":
      return [model, Cmd.request("media.audio.set_volume", model.volumeInput, { key: "media-volume", ok: "sender_ready", err: "sender_error" })];
    case "bitrate_edit":
      return { ...model, bitrateInput: editText(model.bitrateInput, msg.edit) };
    case "set_audio_bitrate": {
      if (model.bitrateInput.length === 0) return model;
      return [model, Cmd.request("media.audio.set_bitrate", model.bitrateInput, { key: "media-bitrate", ok: "sender_ready", err: "sender_error" })];
    }
    case "live_answer": {
      if (!model.incomingLive) return model;
      return [hideBanner({ ...model, incomingLive: false, receiverStatus: utf8Bytes("In call") }), Cmd.batch([
        Cmd.request("media.live.subscribe", model.liveTicketInput, { key: "media-live-subscribe", ok: "live_subscribed", err: "live_subscribe_error" }),
        Cmd.request("idfond.request", daemonMessagePayload(model.identityName, model.replyRoute, utf8Bytes("call_started"), utf8Bytes(`call-started-${model.history.length}`), EMPTY), { key: "iroh-reply", ok: "sender_ready", err: "sender_error" }),
      ])];
    }
    case "live_decline": {
      if (!model.incomingLive) return model;
      const declined = hideBanner({ ...model, incomingLive: false, liveTicketInput: EMPTY, receiverStatus: utf8Bytes("Call declined"), selectedConnectionName: utf8Bytes("Call declined") });
      if (model.replyRoute.length === 0) return declined;
      return [declined, Cmd.request("idfond.request", daemonMessagePayload(model.identityName, model.replyRoute, utf8Bytes("call_stopped"), utf8Bytes(`call-stopped-${model.history.length}`), EMPTY), { key: "iroh-reply", ok: "sender_ready", err: "sender_error" })];
    }
    case "live_start":
      if (model.liveActive || model.receiverId.length === 0) return model;
      return [model, Cmd.request("idfond.request", mediaSessionStartPayload(model), { key: "media-session", ok: "media_session_ready", err: "live_error" })];
    case "media_session_ready":
      return [model, Cmd.request("media.live.start", EMPTY, { key: "media-live", ok: "live_started", err: "live_error" })];
    case "live_stop":
      if (model.subscribedActive && !model.liveActive) {
        if (model.replyRoute.length === 0) return [model, Cmd.request("media.live.unsubscribe", EMPTY, { key: "media-live-subscribe", ok: "live_unsubscribed", err: "live_subscribe_error" })];
        return [model, Cmd.batch([
          Cmd.request("media.live.unsubscribe", EMPTY, { key: "media-live-subscribe", ok: "live_unsubscribed", err: "live_subscribe_error" }),
          Cmd.request("idfond.request", daemonMessagePayload(model.identityName, model.replyRoute, utf8Bytes("call_stopped"), utf8Bytes(`call-stopped-${model.history.length}`), EMPTY), { key: "iroh-reply", ok: "sender_ready", err: "sender_error" }),
        ])];
      }
      if (!model.liveActive) return model;
      if (model.receiverId.length === 0) return [model, Cmd.request("media.live.stop", EMPTY, { key: "media-live", ok: "live_stopped", err: "live_error" })];
      return [model, Cmd.batch([
        Cmd.request("idfond.request", daemonMessagePayload(model.identityName, model.receiverId, liveInviteMessage(utf8Bytes("stop"), EMPTY), utf8Bytes(`live-stop-${model.history.length}`), EMPTY), { key: "media-live-stop-signal", ok: "sender_ready", err: "sender_error" }),
        Cmd.request("media.live.stop", EMPTY, { key: "media-live", ok: "live_stopped", err: "live_error" }),
      ])];
    case "live_started":
      return [showBanner({ ...comUpdate(model, { live: true, audio: true }), audioStatus: utf8Bytes("Microphone on (live)"), liveTicket: msg.data }, utf8Bytes("Calling receiver")), Cmd.request("idfond.request", daemonMessagePayload(model.identityName, model.receiverId, liveInviteMessage(utf8Bytes("start"), msg.data), utf8Bytes(`live-start-${model.history.length}`), model.capabilityTicket), { key: "media-live-signal", ok: "sender_ready", err: "sender_error" })];
    case "copy_live_ticket":
      if (model.liveTicket.length === 0) return model;
      return [model, Cmd.clipboardWrite(model.liveTicket)];
    case "live_stopped": {
      const quiet = hideBanner({ ...model, audioStatus: utf8Bytes("Microphone off") });
      return comUpdate(quiet, { live: false, audio: false });
    }
    case "live_error": {
      const failed = showBanner(model, msg.data);
      return comUpdate(failed, { live: false });
    }
    case "live_ticket_edit":
      return { ...model, liveTicketInput: editText(model.liveTicketInput, msg.edit) };
    case "live_subscribe":
      if (model.liveTicketInput.length === 0) return model;
      return [model, Cmd.request("media.live.subscribe", model.liveTicketInput, { key: "media-live-subscribe", ok: "live_subscribed", err: "live_subscribe_error" })];
    case "live_unsubscribe":
      if (!model.subscribedActive) return model;
      return [model, Cmd.request("media.live.unsubscribe", EMPTY, { key: "media-live-subscribe", ok: "live_unsubscribed", err: "live_subscribe_error" })];
    case "live_subscribed":
      return showBanner({ ...comUpdate(model, { subscribed: true }), subscribedRecording: true }, utf8Bytes("Live audio subscribed"));
    case "live_unsubscribed":
      return showBanner({ ...comUpdate(model, { subscribed: false, recReady: model.subscribedRecording || model.recordingReady }), subscribedRecording: false, recordingStatus: model.subscribedRecording ? utf8Bytes("Recording ready") : model.recordingStatus }, utf8Bytes("Live audio unsubscribed"));
    case "live_subscribe_error":
      return showBanner(model, msg.data);
    case "recording_preview":
      if (!model.recordingReady) return model;
      return [model, Cmd.request("media.recording.play", model.recordingTicket, { key: "media-playback", ok: "playback_started", err: "playback_error" })];
    case "recording_start":
      if (model.recordingActive) return model;
      return [model, Cmd.request("media.recording.start", EMPTY, { key: "media-recording", ok: "recording_started", err: "recording_error" })];
    case "recording_stop":
      if (!model.recordingActive) return model;
      return [model, Cmd.request("media.recording.stop", EMPTY, { key: "media-recording", ok: "recording_stopped", err: "recording_error" })];
    case "recording_started":
      return { ...comUpdate(model, { recording: true }), recordingStartedAt: model.tickAt, waveform: waveformBars(0), recordingStatus: utf8Bytes("Recording microphone") };
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
      if (model.comms.recording) return model; // stale store from a superseded recording — never attach mid-recording
      const fields = routedFields(msg.data);
      const settled = comUpdate(model, { recReady: true });
      return [{ ...settled, senderDisabled: model.receiverId.length === 0, recordingDuration: fields[0], recordingStatus: utf8Bytes("Recording attached"), recordingTicket: fields[1] },
        // persist like the inbound path so preview playback can read the blob
        Cmd.request("media.recording.persist", fields[1], { key: "media-recording-persist", ok: "recording_persisted", err: "recording_persist_error" })];
    }
    case "recording_cancel":
      return { ...comUpdate(model, { recReady: false }), pendingRecordingSend: false, recordingTicket: EMPTY, recordingStatus: utf8Bytes("Recording discarded") };
    case "copy_recording_ticket":
      if (model.recordingTicket.length === 0) return model;
      return [model, Cmd.clipboardWrite(model.recordingTicket)];
    case "recording_send":
      if (model.recordingTicket.length === 0 || model.receiverId.length === 0) return model;
      if (isSelfTarget(model, model.receiverId)) return targetBanner(model, true);
      return [model, Cmd.request("idfond.request", recordingPayload(model), { key: "media-recording-send", ok: "sender_ready", err: "sender_error" })];
    case "recording_store_error":
      return { ...model, recordingStatus: msg.data };
    case "blob_ticket_edit":
      return { ...model, blobTicketInput: editText(model.blobTicketInput, msg.edit) };
    case "blob_fetch":
      if (model.blobTicketInput.length === 0) return model;
      return [model, Cmd.request("media.blob.fetch", model.blobTicketInput, { key: "media-blob-fetch", ok: "blob_fetched", err: "blob_fetch_error" })];
    case "blob_fetched": {
      // The completion carries the fetched ticket (media.blob.fetch echoes it
      // back), so each pending item is marked by its own exact ticket.
      const history = model.history.map((item) => item.isAudio && !item.audioReady && sameBytes(item.audio, msg.data) ? { ...item, audioReady: true } : item);
      return comUpdate(showBanner({ ...model, history, blobStatus: utf8Bytes("Recording ready") }, utf8Bytes("Received recording ready")), {});
    }
    case "blob_fetch_error":
      return showBanner({ ...model, blobStatus: msg.data }, utf8Bytes("Could not receive recording"));
    case "audio_toggle": {
      const item = model.history.find((entry) => sameBytes(entry.id, msg.data));
      if (item === undefined || !item.audioReady) return model;
      // real play/pause toggle: FFI play supersedes, stop_playback halts
      if (sameBytes(item.audio, model.playingTicket)) {
        return [comUpdate({ ...model, playingTicket: EMPTY }, {}), Cmd.request("media.recording.stop_playback", EMPTY, { key: "media-playback", ok: "playback_stopped", err: "playback_error" })];
      }
      return [comUpdate({ ...model, playingTicket: item.audio }, {}), Cmd.request("media.recording.play", item.audio, { key: "media-playback", ok: "playback_started", err: "playback_error" })];
    }
    case "playback_started":
    case "playback_stopped":
      return model;
    case "playback_error":
      return { ...model, playingTicket: EMPTY };
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
