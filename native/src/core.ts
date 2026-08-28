import { Cmd, asciiBytes, utf8Bytes, windowDescriptor } from "@native-sdk/core";
import { type WindowDescriptor } from "@native-sdk/core/events";
import { type TextInputEvent, applyTextInputEvent } from "@native-sdk/core/text";

const EMPTY = new Uint8Array(0);
const NO_CONNECTIONS: readonly Connection[] = [];
const MAX_MESSAGE = 1024;
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
  readonly showTicket: boolean;
  readonly showAddConnection: boolean;
}

export type Msg =
  | { readonly kind: "connect_receiver" }
  | { readonly kind: "receiver_ready"; readonly data: Uint8Array }
  | { readonly kind: "receiver_error"; readonly data: Uint8Array }
  | { readonly kind: "receiver_event"; readonly key: number; readonly state: ChannelState; readonly bytes: Uint8Array; readonly droppedPending: number; readonly droppedTotal: number }
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
  | { readonly kind: "sender_error"; readonly data: Uint8Array };

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

function sendPayload(model: Model): Uint8Array {
  return concat(concat(model.receiverId, new Uint8Array([10])), model.message);
}

function replyPayload(model: Model): Uint8Array {
  return concat(concat(model.replyRoute, new Uint8Array([10])), model.message);
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
      return [{ ...model, identitySelected: true }, Cmd.clipboardWrite(model.receiverTicket)];
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
        return { ...model, identitySelected: true, replyRoute: route, message, receiverStatus: utf8Bytes("Received: receiver_event"), senderStatus: utf8Bytes("Reply available"), selectedConnectionName: utf8Bytes("Incoming connection"), chatOpen: true };
      }
    case "connection_selected": {
      const connection = model.connections.find((item) => sameBytes(item.name, msg.name));
      return connection === undefined ? model : { ...model, selectedConnectionName: connection.name, receiverId: connection.endpoint, senderDisabled: false, senderStatus: concat(utf8Bytes("Ready: "), connection.name) };
    }
    case "connection_opened": {
      const connection = model.connections.find((item) => sameBytes(item.name, msg.name));
      return connection === undefined ? model : { ...model, selectedConnectionName: connection.name, receiverId: connection.endpoint, senderDisabled: false, senderStatus: concat(utf8Bytes("Ready: "), connection.name), chatOpen: true };
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
      return { ...model, connections: [...model.connections, { name: model.connectionName, endpoint: model.receiverId }], showAddConnection: false, senderDisabled: false, senderStatus: concat(utf8Bytes("Ready: "), model.connectionName) };
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
