#!/usr/bin/env node
// Convert voice-agent-trainer's Tyger score JSON into Jev/System-One records.
// Audio stays at its licensed source; this file contains only references,
// state visible to the decision, teacher scores, and optional labels.
//
//   node scripts/tyger-to-systemone.mjs scores.json --source source.json --out labels.jsonl
//   node scripts/tyger-to-systemone.mjs --self-test

import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";

const QUESTIONS = {
  turn_state: {
    type: "choice",
    instructions: "Which Tyger floor state is most likely at this frame?",
    criteria: {
      listen: "The user has the floor and the agent is not speaking.",
      hold: "The user is speaking or holding the floor.",
      speak: "The agent has the floor and is speaking.",
      backchannel: "The user gives a brief listener response without taking the floor.",
    },
  },
  end_of_turn: {
    type: "noul",
    instructions: "Has the user's turn ended?",
    criteria: { true: "The utterance is complete and the agent may answer.", false: "The user may continue or is still speaking." },
  },
  barge_in: {
    type: "noul",
    instructions: "Is the caller cutting in while the agent is speaking?",
    criteria: { true: "Stop agent playback and yield.", false: "The agent should keep speaking." },
  },
  assistant_backchannel: {
    type: "noul",
    instructions: "Should the agent briefly acknowledge while the caller keeps the floor?",
    criteria: { true: "The agent may interject a brief acknowledgement.", false: "The agent should keep listening silently." },
  },
};

const STATE_NAMES = ["listen", "hold", "speak", "backchannel"];
const TYGER_STATES = ["LISTEN", "HOLD", "SPEAK", "BACKCHANNEL"];
const HEAD_NAMES = ["state_listen", "state_hold", "state_speak", "state_backchannel", "hazard", "yield", "bc", "p_end"];

function softmax(xs) {
  const max = Math.max(...xs);
  const exps = xs.map((x) => Math.exp(x - max));
  const sum = exps.reduce((a, b) => a + b, 0);
  return exps.map((x) => x / sum);
}

function sourceRef(source, frame) {
  const offsetMs = source.offset_ms ?? 0;
  const endMs = offsetMs + Math.round(frame.t * 1000);
  return {
    dataset: source.dataset,
    revision: source.revision,
    conversation_id: source.conversation_id,
    start_ms: offsetMs + Math.max(0, Math.round((frame.t - 0.08) * 1000)),
    end_ms: endMs,
    channels: source.channels,
  };
}

function makeRecord(frame, source, decisions, model, thresholds, rulesRevision) {
  assert.equal(frame.out?.length, 8, `frame ${frame.frame}: Tyger out vector must have 8 values`);
  const states = softmax(frame.out.slice(0, 4));
  const stateIndex = states.indexOf(Math.max(...states));
  const events = decisions.filter((d) => d.frame === frame.frame).map((d) => ({
    kind: d.kind,
    value: d.value,
    threshold: d.thr,
    margin: d.margin,
  }));
  return {
    schema_version: "IDFON-VOICE-DECISION/1",
    source_ref: sourceRef(source, frame),
    trace: `${source.dataset}@${source.revision}:${source.conversation_id}`,
    turn_id: `${source.conversation_id}:f${frame.frame}`,
    ts: frame.t,
    tier: "on_device",
    model,
    policy: { rules_revision: rulesRevision, frame_ms: 80, thresholds },
    state: {
      mode: frame.mode,
      ...(frame.prev_state === undefined ? {} : { prev_state: TYGER_STATES[frame.prev_state] ?? frame.prev_state }),
      ...(frame.act_db === undefined ? {} : { energy_db: frame.act_db }),
      ...(frame.left === undefined ? {} : { frames_left: frame.left }),
    },
    questions: QUESTIONS,
    answers: {
      turn_state: {
        type: "choice",
        choice: STATE_NAMES[stateIndex],
        probabilities: Object.fromEntries(STATE_NAMES.map((name, i) => [name, +states[i].toFixed(6)])),
        confidence: +states[stateIndex].toFixed(6),
      },
      end_of_turn: { type: "noul", noul: frame.out[7] },
      barge_in: { type: "noul", noul: frame.out[5] },
      assistant_backchannel: { type: "noul", noul: frame.out[6] },
    },
    action: { id: "not_executed", executed: false },
    teacher_proposal: { source: "tyger-rules", events },
    outcome: null,
    label: null,
    teacher_scores: { heads: HEAD_NAMES, values: frame.out },
  };
}

function validateRecord(row) {
  assert.equal(row.schema_version, "IDFON-VOICE-DECISION/1");
  assert.ok(row.trace && row.turn_id && Number.isFinite(row.ts));
  assert.ok(row.source_ref.dataset && row.source_ref.conversation_id);
  assert.ok(row.source_ref.end_ms > row.source_ref.start_ms);
  assert.equal(row.policy.frame_ms, 80);
  assert.deepEqual(row.action, { id: "not_executed", executed: false });
  assert.equal(row.teacher_proposal.source, "tyger-rules");
  assert.ok(Array.isArray(row.teacher_proposal.events));
  assert.equal(row.teacher_scores.values.length, HEAD_NAMES.length);
  for (const [id, answer] of Object.entries(row.answers)) {
    assert.equal(answer.type, row.questions[id]?.type, `question/answer type mismatch: ${id}`);
  }
  return row;
}

function checkSource(source) {
  for (const key of ["dataset", "revision", "conversation_id"]) {
    if (typeof source[key] !== "string" || !source[key]) throw new Error(`source is missing ${key}`);
  }
  if (typeof source.channels?.user !== "string" || typeof source.channels?.agent !== "string") {
    throw new Error("source.channels must map user and agent to source track names");
  }
  if (source.offset_ms !== undefined && (!Number.isInteger(source.offset_ms) || source.offset_ms < 0)) {
    throw new Error("source.offset_ms must be a non-negative integer");
  }
}

function selfTest() {
  const frame = { frame: 1, t: 0.08, mode: "speaking", prev_state: 2, act_db: -31.2, left: 4,
    out: [-4.61, -3.22, -0.06, -4.61, 0.05, 0.12, 0.12, 0.08] };
  const source = { dataset: "sample", revision: "rev", conversation_id: "c1", offset_ms: 10000, channels: { user: "a.flac", agent: "b.flac" } };
  const row = makeRecord(frame, source, [{ frame: 1, kind: "BARGE" }], "tyger/test", { ep_thr: 0.9 }, "rules/test");
  assert.equal(row.answers.turn_state.choice, "speak");
  assert.equal(row.answers.barge_in.noul, 0.12);
  assert.equal(row.action.id, "not_executed");
  assert.deepEqual(row.teacher_proposal.events.map((event) => event.kind), ["BARGE"]);
  assert.equal(row.source_ref.start_ms, 10000);
  assert.equal(row.source_ref.end_ms, 10080);
  assert.equal(row.teacher_scores.values.length, 8);
  validateRecord(row);
  console.log("tyger-to-systemone self-test: OK");
}

const args = process.argv.slice(2);
if (args.includes("--self-test")) selfTest();
else {
  const input = args.find((x) => !x.startsWith("--"));
  const value = (name) => args.includes(name) ? args[args.indexOf(name) + 1] : undefined;
  const sourcePath = value("--source"), outputPath = value("--out"), model = value("--model"), rulesRevision = value("--rules-revision");
  if (!input || !sourcePath || !outputPath || !model || !rulesRevision) {
    console.error("usage: node scripts/tyger-to-systemone.mjs scores.json --source source.json --out labels.jsonl --model ID --rules-revision ID");
    process.exit(2);
  }
  const trainer = JSON.parse(readFileSync(input, "utf8"));
  const source = JSON.parse(readFileSync(sourcePath, "utf8"));
  checkSource(source);
  assert.ok(Array.isArray(trainer.frames), "trainer JSON has no frames");
  assert.ok(trainer.thresholds && typeof trainer.thresholds === "object", "trainer JSON has no thresholds");
  const lines = trainer.frames.map((frame) => JSON.stringify(validateRecord(
    makeRecord(frame, source, trainer.decisions ?? [], model, trainer.thresholds, rulesRevision),
  )));
  writeFileSync(outputPath, `${lines.join("\n")}\n`);
  console.log(`wrote ${lines.length} records to ${outputPath}; no audio was copied`);
}
