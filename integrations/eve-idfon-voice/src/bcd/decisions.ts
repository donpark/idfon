// The bcd decision layer: per-frame intent probabilities -> events.
// p(backchannel) = continuer + assessment; p(floor) = negative + floor_take
// (the model card's definitions). Reference thresholds (model card "Results"):
// floor 0.7; backchannel 0.7, called only once the user stops, 1.2 s backstop.
//
// Times are the model's 20 ms frames. "Called only once the user stops" is read
// literally: a threshold crossing while the user speaks (aux vad) arms a
// pending backchannel that fires at the first non-speaking frame, and is
// dropped (never fired) if the user does not stop within the backstop. Floor
// takes are stronger: a floor crossing fires at once and cancels any pending
// backchannel.

export const FRAME_S = 0.02;

export interface BcdThresholds {
  floor: number; // p(floor) crossing -> floor_take
  backchannel: number; // p(backchannel) crossing -> arm pending
  backstopS: number; // pending backchannel is dropped this long after arming
  vad: number; // aux vad >= this means the user is speaking
}

export const DEFAULT_THRESHOLDS: BcdThresholds = {
  floor: 0.7,
  backchannel: 0.7,
  backstopS: 1.2,
  vad: 0.5,
};

export type BcdEventKind = "backchannel" | "floor_take" | "none";

export interface BcdDecision {
  kind: BcdEventKind;
  frame: number; // 20 ms frame index since reset
  p: number; // triggering prob (0 for none)
  pBackchannel: number;
  pFloor: number;
  vad: number;
}

export class BcdDecisions {
  readonly thresholds: BcdThresholds;
  private frame = 0;
  private floorHot = false;
  private bcHot = false;
  private bcArmedAt = -1; // frame the pending backchannel was armed, -1 = none

  constructor(thresholds: Partial<BcdThresholds> = {}) {
    this.thresholds = { ...DEFAULT_THRESHOLDS, ...thresholds };
  }

  reset(): void {
    this.frame = 0;
    this.floorHot = false;
    this.bcHot = false;
    this.bcArmedAt = -1;
  }

  /// One 20 ms frame's intent softmax + aux vad -> this frame's event.
  onFrame(intent: ArrayLike<number>, vad: number): BcdDecision {
    const frame = this.frame++;
    const pBackchannel = intent[0] + intent[1]; // continuer + assessment
    const pFloor = intent[2] + intent[3]; // negative + floor_take
    const speaking = vad >= this.thresholds.vad;
    const out = (kind: BcdEventKind, p: number): BcdDecision => ({
      kind,
      frame,
      p,
      pBackchannel,
      pFloor,
      vad,
    });

    // fires once per threshold crossing; re-arms when p(floor) drops below
    const floorHot = pFloor >= this.thresholds.floor;
    const floorCross = floorHot && !this.floorHot;
    this.floorHot = floorHot;

    const bcHot = pBackchannel >= this.thresholds.backchannel;
    const bcCross = bcHot && !this.bcHot;
    this.bcHot = bcHot;

    if (floorCross) {
      this.bcArmedAt = -1; // the user is taking the floor, not backchannelling
      return out("floor_take", pFloor);
    }
    if (this.bcArmedAt >= 0) {
      if (!speaking) {
        this.bcArmedAt = -1; // user stopped: call the backchannel
        return out("backchannel", pBackchannel);
      }
      if (frame - this.bcArmedAt >= Math.round(this.thresholds.backstopS / FRAME_S)) {
        this.bcArmedAt = -1; // backstop: user never stopped, dropped
      }
      return out("none", 0);
    }
    if (bcCross) {
      if (!speaking) return out("backchannel", pBackchannel); // user already stopped
      this.bcArmedAt = frame;
    }
    return out("none", 0);
  }
}
