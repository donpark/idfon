import { Cmd, asciiBytes, utf8Bytes, windowDescriptor } from "@native-sdk/core";
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

export interface Model {
  readonly message: Uint8Array;
  readonly replyRoute: Uint8Array;
  readonly identityName: Uint8Array;
  readonly identitySelected: boolean;
  readonly identityError: boolean;
  readonly connections: readonly Connection[];
  readonly selectedConnectionName: Uint8Array;
  readonly chatOpen: boolean;
  readonly connectionName: Uint8Array;
  readonly receiverId: Uint8Array;
  readonly receiverTicket: Uint8Array;
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
  readonly subscribedRecording: boolean;
  readonly recordingActive: boolean;
  readonly recordingTicket: Uint8Array;
  readonly blobTicketInput: Uint8Array;
  readonly blobStatus: Uint8Array;
  readonly playbackActive: boolean;
  readonly fetchedRecordingReady: boolean;
  readonly playbackStatus: Uint8Array;
  readonly showAdvanced: boolean;
  readonly showTicket: boolean;
  readonly showAddConnection: boolean;
}

export type Msg =
  | { readonly kind: "connect_receiver" }
  | { readonly kind: "receiver_ready"; readonly data: Uint8Array }
  | { readonly kind: "receiver_error"; readonly data: Uint8Array }
  | { readonly kind: "receiver_event"; readonly key: number; readonly state: ChannelState; readonly bytes: Uint8Array; readonly droppedPending: number; readonly droppedTotal: number }
  | { readonly kind: "recording_persisted"; readonly data: Uint8Array }
  | { readonly kind: "recording_persist_error"; readonly data: Uint8Array }
  | { readonly kind: "message_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "identity_name_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "identity_pressed" }
  | { readonly kind: "connection_selected"; readonly name: Uint8Array }
  | { readonly kind: "connection_opened"; readonly name: Uint8Array }
  | { readonly kind: "chat_closed" }
  | { readonly kind: "connection_name_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "receiver_id_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "copy_endpoint_id" }
  | { readonly kind: "show_add_connection" }
  | { readonly kind: "cancel_add_connection" }
  | { readonly kind: "add_connection" }
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
  | { readonly kind: "audio_emergency_stopped"; readonly data: Uint8Array };

export const viewUnbound = ["receiverAvailable", "receiver_ready", "receiver_error", "receiver_event", "sender_ready", "sender_error"] as const;

export function initialModel(): Model | [Model, Cmd<Msg>] {
  return [{

    message: EMPTY,
    replyRoute: EMPTY,
    identityName: utf8Bytes("Default"),
    identitySelected: true,
    identityError: false,
    connections: NO_CONNECTIONS,
    selectedConnectionName: EMPTY,
    chatOpen: false,
    connectionName: EMPTY,
    receiverId: EMPTY,
    receiverTicket: EMPTY,
    endpointId: EMPTY,
    receiverStatus: utf8Bytes("Not connected"),
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
    subscribedRecording: false,
    recordingActive: false,
    recordingTicket: EMPTY,
    blobTicketInput: EMPTY,
    blobStatus: utf8Bytes("No blob selected"),
    playbackActive: false,
    fetchedRecordingReady: false,
    playbackStatus: utf8Bytes("Playback stopped"),
    showAdvanced: false,
    showTicket: false,
    showAddConnection: false,
  }, Cmd.batch([
    Cmd.channelOpen(RECEIVER_CHANNEL, { event: "receiver_event" }),
    Cmd.request("iroh.receiver.bind", EMPTY, { key: "iroh-receiver", ok: "receiver_ready", err: "receiver_error" }),
  ])];
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

function sendPayload(model: Model): Uint8Array {
  return concat(concat(model.receiverId, new Uint8Array([10])), model.message);
}

function replyPayload(model: Model): Uint8Array {
  return concat(concat(model.replyRoute, new Uint8Array([10])), model.message);
}

function recordingEnvelope(model: Model): Uint8Array {
  return concat(utf8Bytes("NUFON-RECORDING/1\nid="), concat(model.recordingTicket, concat(utf8Bytes("\ncodec=opus\nchannels=1\nsample_rate=48000\nduration_ms=0\nsender_id="), concat(model.endpointId, concat(utf8Bytes("\nticket="), model.recordingTicket)))));
}

function recordingPayload(model: Model): Uint8Array {
  return concat(concat(model.receiverId, new Uint8Array([10])), recordingEnvelope(model));
}

function editText(text: Uint8Array, edit: TextInputEvent): Uint8Array {
  const next = applyTextInputEvent({ text, selection: { anchor: 1024, focus: 1024 }, composition: null }, edit, MAX_MESSAGE);
  return next === null ? text : next.text;
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

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "connect_receiver":
      return [model, Cmd.request("iroh.receiver.bind", EMPTY, { key: "iroh-receiver", ok: "receiver_ready", err: "receiver_error" })];
    case "identity_pressed":
      if (!model.receiverAvailable) return [
        { ...model, identitySelected: true },
        Cmd.request("iroh.receiver.bind", EMPTY, { key: "iroh-receiver", ok: "receiver_ready", err: "receiver_error" }),
      ];
      if (model.receiverTicket.length === 0) return { ...model, identitySelected: true };
      return [{ ...model, identitySelected: true }, Cmd.batch([
        Cmd.clipboardWrite(model.receiverTicket),
        Cmd.showNotification({
          title: asciiBytes("Nufon ticket copied"),
          body: concat(asciiBytes("Endpoint: "), model.endpointId),
        }),
      ])];
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
        const message = fields[1];
        if (route.length === 0) return model;
        const recordingPrefix = utf8Bytes("NUFON-RECORDING/1\n");
        if (message.length > recordingPrefix.length && sameBytes(message.slice(0, recordingPrefix.length), recordingPrefix)) {
          const ticket = recordingTicket(message);
          return [{ ...model, identitySelected: true, replyRoute: route, message: utf8Bytes("Received recording"), blobTicketInput: ticket, receiverStatus: utf8Bytes("Received recording"), senderStatus: utf8Bytes("Preparing recording"), selectedConnectionName: utf8Bytes("Incoming recording"), chatOpen: true }, Cmd.batch([
            Cmd.request("media.recording.persist", ticket, { key: "media-recording-persist", ok: "recording_persisted", err: "recording_persist_error" }),
            Cmd.request("media.blob.fetch", ticket, { key: "media-blob-fetch", ok: "blob_fetched", err: "blob_fetch_error" }),
          ])];
        }
        return { ...model, identitySelected: true, replyRoute: route, message, receiverStatus: utf8Bytes("Received: receiver_event"), senderStatus: utf8Bytes("Reply available"), selectedConnectionName: utf8Bytes("Incoming connection"), chatOpen: true };
      }
    case "connection_selected": {
      const connection = model.connections.find((item) => sameBytes(item.name, msg.name));
      if (connection === undefined) return model;
      const next = { ...model, selectedConnectionName: connection.name, receiverId: connection.endpoint, senderDisabled: false, senderStatus: concat(utf8Bytes("Ready: "), connection.name) };
      return [next, Cmd.request("media.set_scope", connection.endpoint, { key: "media-scope", ok: "sender_ready", err: "sender_error" })];
    }
    case "connection_opened": {
      const connection = model.connections.find((item) => sameBytes(item.name, msg.name));
      if (connection === undefined) return model;
      const next = { ...model, selectedConnectionName: connection.name, receiverId: connection.endpoint, senderDisabled: false, senderStatus: concat(utf8Bytes("Ready: "), connection.name), chatOpen: true };
      return [next, Cmd.request("media.set_scope", connection.endpoint, { key: "media-scope", ok: "sender_ready", err: "sender_error" })];
    }
    case "chat_closed":
      return { ...model, chatOpen: false };
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
    case "add_connection":
      if (model.connectionName.length === 0 || model.receiverId.length === 0) return model;
      return [{ ...model, connections: [...model.connections, { name: model.connectionName, endpoint: model.receiverId }], showAddConnection: false, senderDisabled: false, senderStatus: concat(utf8Bytes("Ready: "), model.connectionName) }, Cmd.request("media.set_scope", model.receiverId, { key: "media-scope", ok: "sender_ready", err: "sender_error" })];
    case "send_message":
      if (model.receiverId.length === 0 || model.message.length === 0) return model;
      return [model, Cmd.request("iroh.sender.send", sendPayload(model), { key: "iroh-send", ok: "sender_ready", err: "sender_error" })];
    case "reply_message":
      if (model.replyRoute.length === 0 || model.message.length === 0) return model;
      return [model, Cmd.request("iroh.receiver.reply", replyPayload(model), { key: "iroh-reply", ok: "sender_ready", err: "sender_error" })];
    case "sender_ready":
      return { ...model, senderStatus: msg.data.length === 0 ? utf8Bytes("Message echoed") : msg.data };
    case "sender_error":
      return { ...model, senderStatus: msg.data };
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
      return { ...model, audioActive: true, audioStatus: utf8Bytes("Microphone on") };
    case "audio_stopped":
      return { ...model, audioActive: false, audioStatus: utf8Bytes("Microphone off") };
    case "audio_error":
      return { ...model, audioActive: false, audioStatus: msg.data };
    case "audio_emergency_stopped":
      return { ...model, audioActive: false, liveActive: false, subscribedActive: false, recordingActive: false, playbackActive: false, audioStatus: utf8Bytes("Emergency stop"), liveStatus: utf8Bytes("Live audio stopped"), playbackStatus: utf8Bytes("Playback stopped") };
    case "audio_probe":
      return [model, Cmd.request("media.audio.probe", EMPTY, { key: "media-audio-probe", ok: "audio_probe_result", err: "audio_error" })];
    case "audio_probe_result":
      return { ...model, audioStatus: msg.data.length === 0 ? utf8Bytes("No input samples") : concat(utf8Bytes("Input samples: "), msg.data) };
    case "volume_edit":
      return { ...model, volumeInput: editText(model.volumeInput, msg.edit) };
    case "volume_set":
      return [model, Cmd.request("media.audio.set_volume", model.volumeInput, { key: "media-volume", ok: "sender_ready", err: "sender_error" })];
    case "live_start":
      if (model.liveActive) return model;
      return [model, Cmd.request("media.live.start", EMPTY, { key: "media-live", ok: "live_started", err: "live_error" })];
    case "live_stop":
      if (!model.liveActive) return model;
      return [model, Cmd.request("media.live.stop", EMPTY, { key: "media-live", ok: "live_stopped", err: "live_error" })];
    case "live_started":
      return { ...model, liveActive: true, audioActive: true, audioStatus: utf8Bytes("Microphone on (live)"), liveTicket: msg.data, liveStatus: utf8Bytes("Live audio publishing") };
    case "copy_live_ticket":
      if (model.liveTicket.length === 0) return model;
      return [model, Cmd.clipboardWrite(model.liveTicket)];
    case "live_stopped":
      return { ...model, liveActive: false, audioActive: false, audioStatus: utf8Bytes("Microphone off"), liveStatus: utf8Bytes("Live audio off") };
    case "live_error":
      return { ...model, liveActive: false, liveStatus: msg.data };
    case "live_ticket_edit":
      return { ...model, liveTicketInput: editText(model.liveTicketInput, msg.edit) };
    case "live_subscribe":
      if (model.liveTicketInput.length === 0) return model;
      return [model, Cmd.request("media.live.subscribe", model.liveTicketInput, { key: "media-live-subscribe", ok: "live_subscribed", err: "live_subscribe_error" })];
    case "live_unsubscribe":
      if (!model.subscribedActive) return model;
      return [model, Cmd.request("media.live.unsubscribe", EMPTY, { key: "media-live-subscribe", ok: "live_unsubscribed", err: "live_subscribe_error" })];
    case "live_subscribed":
      return { ...model, subscribedActive: true, subscribedRecording: true, liveStatus: utf8Bytes("Live audio subscribed") };
    case "live_unsubscribed":
      return { ...model, subscribedActive: false, recordingReady: model.subscribedRecording || model.recordingReady, subscribedRecording: false, liveStatus: utf8Bytes("Live audio unsubscribed"), recordingStatus: model.subscribedRecording ? utf8Bytes("Recording ready") : model.recordingStatus };
    case "live_subscribe_error":
      return { ...model, liveStatus: msg.data };
    case "recording_start":
      if (model.recordingActive) return model;
      return [model, Cmd.request("media.recording.start", EMPTY, { key: "media-recording", ok: "recording_started", err: "recording_error" })];
    case "recording_stop":
      if (!model.recordingActive) return model;
      return [model, Cmd.request("media.recording.stop", EMPTY, { key: "media-recording", ok: "recording_stopped", err: "recording_error" })];
    case "recording_started":
      return { ...model, recordingActive: true, recordingReady: false, recordingTicket: EMPTY, recordingStatus: utf8Bytes("Recording microphone") };
    case "recording_stopped": {
      const next = { ...model, recordingActive: false, recordingReady: false, subscribedRecording: false, recordingStatus: utf8Bytes("Preparing recording") };
      return [next, Cmd.request("media.live.recording.store", EMPTY, { key: "media-recording-store", ok: "recording_stored", err: "recording_store_error" })];
    }
    case "recording_error":
      return { ...model, recordingActive: false, recordingStatus: msg.data };
    case "recording_store":
      if (!model.recordingReady) return model;
      return [model, Cmd.request("media.live.recording.store", EMPTY, { key: "media-recording-store", ok: "recording_stored", err: "recording_store_error" })];
    case "recording_stored":
      return { ...model, recordingReady: true, recordingStatus: utf8Bytes("Recording ready to send"), recordingTicket: msg.data };
    case "copy_recording_ticket":
      if (model.recordingTicket.length === 0) return model;
      return [model, Cmd.clipboardWrite(model.recordingTicket)];
    case "recording_send":
      if (model.recordingTicket.length === 0 || model.receiverId.length === 0) return model;
      return [model, Cmd.request("iroh.sender.send", recordingPayload(model), { key: "media-recording-send", ok: "sender_ready", err: "sender_error" })];
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
