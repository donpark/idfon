import { Cmd, utf8Bytes } from "@native-sdk/core";
import { type TextInputEvent, applyTextInputEvent } from "@native-sdk/core/text";

const EMPTY = new Uint8Array(0);
const MAX_MESSAGE = 1024;
const RECEIVER_CHANNEL = 1;
export type ChannelState = "data" | "closed" | "rejected";

export interface Model {
  readonly message: Uint8Array;
  // Shared receiver state: the sender reads this at Send time.
  readonly receiverTicket: Uint8Array;
  readonly receiverKey: Uint8Array;
  readonly receiverStatus: Uint8Array;
  readonly senderStatus: Uint8Array;
  readonly receiverAvailable: boolean;
  readonly senderDisabled: boolean;
}

export type Msg =
  | { readonly kind: "connect_receiver" }
  | { readonly kind: "receiver_ready"; readonly data: Uint8Array }
  | { readonly kind: "receiver_error"; readonly data: Uint8Array }
  | { readonly kind: "receiver_event"; readonly key: number; readonly state: ChannelState; readonly bytes: Uint8Array; readonly droppedPending: number; readonly droppedTotal: number }
  | { readonly kind: "message_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "send_message" }
  | { readonly kind: "sender_ready"; readonly data: Uint8Array }
  | { readonly kind: "sender_error"; readonly data: Uint8Array };

export const viewUnbound = ["receiverAvailable", "receiver_ready", "receiver_error", "receiver_event", "sender_ready", "sender_error"] as const;

export function initialModel(): Model | [Model, Cmd<Msg>] {
  return [{

    message: EMPTY,
    receiverTicket: EMPTY,
    receiverKey: EMPTY,
    receiverStatus: utf8Bytes("Not connected"),
    senderStatus: utf8Bytes("Waiting for receiver"),
    receiverAvailable: false,
    senderDisabled: true,
  }, Cmd.channelOpen(RECEIVER_CHANNEL, { event: "receiver_event" })];
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a);
  out.set(b, a.length);
  return out;
}

function receiverFields(data: Uint8Array): [Uint8Array, Uint8Array] {
  let separator = -1;
  let i = 0;
  while (i < data.length) {
    if (data[i] === 10) {
      separator = i;
      break;
    }
    i += 1;
  }
  if (separator < 0) return [data, data];
  return [data.slice(0, separator), data.slice(separator + 1)];
}

function sendPayload(model: Model): Uint8Array {
  // Deliberate shortcut: receiverTicket is the shared in-process signaling
  // state. There is no separate sender/receiver signaling channel yet.
  return concat(concat(model.receiverTicket, new Uint8Array([10])), model.message);
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "connect_receiver":
      return [model, Cmd.request("iroh.receiver.bind", EMPTY, { key: "iroh-receiver", ok: "receiver_ready", err: "receiver_error" })];
    case "receiver_ready": {
      const fields = receiverFields(msg.data);
      const ticket = fields[0];
      const key = fields[1];
      return [
        { ...model, receiverTicket: ticket, receiverKey: key, receiverStatus: utf8Bytes("Available"), senderStatus: utf8Bytes("Receiver available"), receiverAvailable: true, senderDisabled: false },
        Cmd.none,
      ];
    }
    case "receiver_error":
      return { ...model, receiverStatus: msg.data, senderStatus: utf8Bytes("Receiver unavailable"), receiverAvailable: false, senderDisabled: true };
    case "receiver_event":
      return msg.state === "data" ? { ...model, receiverStatus: concat(utf8Bytes("Received: "), msg.bytes) } : model;
    case "message_edit": {
      // Use the capacity as an end-of-text sentinel; the text helper clamps it
      // to the current length without crossing ScriptC's integer boundary.
      const next = applyTextInputEvent({ text: model.message, selection: { anchor: 1024, focus: 1024 }, composition: null }, msg.edit, MAX_MESSAGE);
      return next === null ? model : { ...model, message: next.text };
    }
    case "send_message":
      // Check the shared receiver state at the moment Send is pressed.
      if (model.receiverTicket.length === 0 || model.message.length === 0) return model;
      return [model, Cmd.request("iroh.sender.send", sendPayload(model), { key: "iroh-send", ok: "sender_ready", err: "sender_error" })];
    case "sender_ready":
      return { ...model, senderStatus: msg.data.length === 0 ? utf8Bytes("Message echoed") : msg.data };
    case "sender_error":
      return { ...model, senderStatus: msg.data };
  }
}
