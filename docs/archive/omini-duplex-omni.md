- MoQ - Media over QUIC
- WebTransport

## **Continuous Context and State Monitoring**

For an "Omni" model to feel natural, it cannot just receive data—it has to maintain a constant **listening, seeing, and evaluation loop** in the background.

Architecturally, achieving this without crashing performance or blowing up memory limits relies on four specific mechanisms:

---

### 1. The Dual-Stream Architecture (Environment vs. Assistant Streams)

Instead of feeding inputs and outputs into a single linear chat history, full-duplex Omni engines split context into two parallel streams:

* **Environment Stream:** Continuous, incoming tokens from the user’s microphone and camera feed.
* **Assistant Stream:** What the AI model itself is currently generating and uttering.

The core model continuously interleaves and aligns these two streams in real time. This is how it detects **echoes** (hearing its own voice played over speakers) versus **user interruptions** (the user starting to talk over it).

---

### 2. High-Frequency Decision Loops (Proactive Triggering)

Instead of waiting for a "submit button" or a long pause, full-duplex Omni models run a lightweight decision loop—often every **100 to 1000 milliseconds**—asking a sub-task question:

$$\text{Action} \in \{\text{Listen}, \text{Speak}, \text{Backchannel}, \text{Interrupt Self}\}$$

* **If you are silent:** The model continues running its speech decoder or stays quiet.
* **If you start talking mid-sentence:** The model detects the incoming audio tokens, sends a soft-stop signal to its output queue, and wipes the unuttered tokens from its generation memory.
* **If you make a subtle gesture or sound:** It emits a short backchannel token (*"mhm"*) without fully stopping its main thought stream.

---

### 3. Continuous KV-Cache Management & Sliding Windows

In traditional LLMs, the "context window" keeps growing with every turn until the memory fills up. An Omni model streaming 30 frames of video per second and raw audio would run out of GPU memory in minutes.

To solve this, Omni architectures use **sliding-window attention** and **dynamic KV-cache management**:

* **High-Resolution Short-Term Memory:** The last few seconds of video, audio, and text are held in full, raw detail to catch fine movements, pitch changes, or immediate speech.
* **Compressed Long-Term Memory:** Older video frames and audio are compressed into high-level semantic tokens (or text-like memory blocks), throwing away unnecessary raw video frames while preserving the core context of the conversation.

---

### 4. Continuous Acoustic & Visual VAD (Voice/Activity Detection)

Before data even hits the main transformer blocks, hardware-level or lightweight edge models filter the incoming stream:

* **Acoustic VAD:** Separates background noise (a dog barking, a car horn) from actual human speech so the model doesn't constantly pause needlessly.
* **Visual Activity Detection:** Monitors for relevant changes in the camera feed—like a hand entering the frame pointing at something—to prompt the model's visual encoder.

---

### Summary

"Omni" isn't just about combining image, speech, and text processing—it is fundamentally about **changing the execution pipeline from a static batch processor to a continuous, streaming state-machine**. Without continuous context monitoring, true full-duplex omnimodal AI simply cannot function.

===

WebSocket falls flat for true full-duplex omnimodal streaming. However, the solution industry standards are coalescing around isn't pure QUIC yet; it is **WebRTC** on the client side, with **Media over QUIC (MoQ)** emerging on the horizon.

The reason WebSocket struggles with "Omni" is **Head-of-Line (HoL) Blocking** and **TCP latency**. Because WebSockets run over a single TCP stream, losing one frame of live video forces the entire connection to freeze until that missing frame is retransmitted. In an Omni setup, a dropped video frame delays your incoming audio, breaking the real-time full-duplex loop.

---

### How Full-Duplex Omni Models Actually Handle Streams Today

To handle simultaneous multi-track interaction (video, audio, data, control signals), platforms rely on protocols designed for multiplexing over **UDP**.

```
                     ┌── Audio Track (Opus / Raw) ──┐
[ Client Devices ] ──┼── Video Track (H.264/VP9)  ──┼──> [ WebRTC Gateway / Omni Engine ]
 (Browsers/Glasses)  └── Data Channel (Control/JSON)┘

```

#### 1. WebRTC: The Current Standard for Edge AI

When you talk to real-time multimodal APIs like [OpenAI Realtime API](https://developers.openai.com/api/docs/guides/voice-webrtc), the client communicates using **WebRTC**.

* **Native Multiplexing:** WebRTC natively handles multiple independent audio/video media tracks and a bidirectional `RTCDataChannel` over a single connection.
* **UDP-Based (RTP):** If a single video frame is lost on a poor connection, WebRTC skips it instead of freezing the audio.
* **Built-in DSP:** It handles hardware-level echo cancellation, jitter buffers, and dynamic bitrate adaptation automatically.

#### 2. Media over QUIC (MoQ) & WebTransport: The Next Generation

While WebRTC dominates today, developers are actively pushing toward **QUIC-based architectures** (specifically **WebTransport** and **MoQ - Media over QUIC**).

* **Independent Stream Priority:** QUIC allows hundreds of logical streams over one UDP connection. If the network gets congested, you can set rules like: *"Prioritize Audio stream > Text Control Data > Drop Video frames."* [Cite: 1.2.3]
* **Zero-RTT Resumption:** QUIC enables instant connection resumption. If a user switches from Wi-Fi to 5G while looking through smart glasses, the stream doesn't drop.
* **Lower Overhead:** It bypasses the heavy Session Description Protocol (SDP) and ICE negotiation required by WebRTC.

#### 3. WebSockets (Server-to-Server Only)

WebSockets are still heavily used, but almost exclusively on the **back-end pipeline**. Once client audio/video is decoded at an edge media server, server-to-server microservices (where network connections are stable and packet loss is virtually zero) often route data frames to the model's GPU cluster via WebSockets or gRPC streams.

---

### Summary

* **WebSocket:** Great for single-track, turn-based text/audio on stable connections; terrible for real-time video+audio streaming due to TCP head-of-line blocking.
* **WebRTC:** The **current production gold standard** for client-side Omni interactions because it multiplexes video, audio, and control data natively.
* **QUIC / MoQ:** The **future foundation** being built to replace WebRTC's complexity with lighter, prioritized QUIC stream multiplexing.

===

**Yes, absolutely.** A fast transport like QUIC (or WebRTC) gives cascaded systems the **networking capability** to support barge-in and low latency. However, transport is only half the equation—it cannot fix the **cognitive bottlenecks** inherent to cascading models.

To see why, it helps to break down what QUIC actually solves versus what it can't.

---

### What QUIC Gives a Cascaded Model

Because QUIC eliminates TCP Head-of-Line blocking and multiplexes independent streams, a cascaded model using QUIC (e.g., via `WebTransport` or `Media over QUIC`) gains key full-duplex mechanics:

* **Instant Interruptions (Barge-in):** If the user starts talking while the Text-to-Speech (TTS) engine is outputting audio, the client can send an instant control signal on a separate QUIC stream. The server immediately cancels the TTS generation and flushes the pipeline.
* **Low Network Latency:** Multiplexing audio and control signals on UDP allows incoming user audio and outgoing model responses to bypass each other without network-level freezes.
* **Parallel Pipelines:** The system can stream incoming audio to the Speech-to-Text (STT) model while simultaneously streaming TTS audio back to the user.

---

### What Cascading Still Misses (The Neural Bottleneck)

Even over zero-latency QUIC transport, a cascaded architecture still behaves like three distinct people passing sticky notes:

```
[User Audio] ──> STT Engine ──> [Text] ──> Text LLM ──> [Text] ──> TTS Engine ──> [Audio]

```

1. **The Turn-Taking Delay (Time to First Token):**
A cascaded model usually has to wait for the STT module to finish transcribing a phrase before the LLM can begin processing logic. Even with streaming STT, passing data between 3 separate software systems introduces a software "processing tax" that transport protocols like QUIC cannot remove.
2. **Loss of Non-Verbal Context:**
If you interrupt a cascaded system with an annoyed *"No, stop!"*, the STT module converts that to the plain text `"No, stop!"`. The LLM receives the text, but misses the tone, emotion, volume, or hesitation in your voice.
3. **Clunky Backchanneling:**
In native full-duplex (like an Omni model), the neural network can emit short audio cues like *"mm-hmm"* or *"right"* mid-thought while keeping its memory intact. In a cascaded setup, forcing a separate LLM and TTS pipeline to generate a backchannel requires complex orchestration and often breaks the conversation state.

---

### The Verdict

| Feature | Cascaded Model over QUIC | Native Omni Model |
| --- | --- | --- |
| **Barge-in / Interruption** | **Yes** (Client drops TTS stream) | **Yes** (Native model self-interrupts) |
| **Low Latency** | **Good** (~500ms–1s pipeline latency) | **Ultra-fast** (<300ms end-to-end) |
| **Emotion & Pitch Awareness** | **No** (Stripped by STT step) | **Yes** (Hears raw audio tokens) |
| **Simultaneous Vision + Audio** | **Clunky** (Separates image frames & audio) | **Native** (Single multimodal context) |

QUIC gives cascaded systems **great UX controls** (like real-time barge-in and fast transport), but it takes a **native full-duplex/Omni model** to get truly human-like, multi-modal fluid intelligence.

===

You can engineer a cascaded system to perform streaming barge-in, background accumulation, and interrupt handling.

However, in practice, building this requires treating the STT layer not just as a speech-to-text converter, but as a **real-time orchestra conductor** for the whole state machine.

---

### How Cascaded Systems Handle Barge-In & Accumulation

To achieve full-duplex mechanics in a cascaded architecture, production frameworks like [Vapi](https://vapi.ai) or custom WebRTC audio engines execute a multi-layered pipeline:

```
[ Incoming User Audio ]
         │
         ├──► 1. Acoustic VAD / Micro-Models ──► (Detects sound vs. background noise)
         │
         └──► 2. Streaming STT ──► [Partial Tokens / Word Confidence]
                                        │
                                        ├──► [Soft-Abort Signal] ──► Flushes TTS Audio Stream
                                        │
                                        └──► [Text Buffer] ────► Appends to Context Array

```

1. **Acoustic & VAD Triggers (Immediate Abort):**
When the user starts speaking while the system is mid-response, a lightweight Voice Activity Detection (VAD) model or low-latency streaming STT (like Deepgram's Nova series) flags user speech in under 50ms. It immediately sends a **soft-abort** signal directly to the Audio Server to drop the ongoing Text-to-Speech (TTS) stream, stopping output instantly before a full word transcript is even formed.
2. **Partial Transcripts & Context Accumulation:**
While the TTS is being aborted, the streaming STT continues transcribing incoming audio into "interim tokens". It holds these in a rolling buffer, capturing background voices or follow-up statements.
3. **Semantic Filtering & Intent Verification:**
The system must evaluate whether the incoming sound is a true interruption, backchannel noise, or background chatter. Modern cascaded systems route the streaming STT output through two checks:
* **Backchannel Filter:** If the interim text is just a minor sound like *"mhm"* or *"yeah"*, the system may ignore it and resume playing the TTS audio.
* **Semantic Abort:** If the interim text represents new intent (*"Wait, stop,"* or *"I changed my mind"*), the system hard-cancels the previous LLM task, appends the newly accumulated text to the conversation history, and fires a fresh prompt to the LLM.



---

### The Practical Challenges with Cascaded Barge-In

While this architecture works well in production, building streaming interruption into a cascade introduces specific edge cases:

* **The Echo Cancellation Problem (Self-Barge):** If your client-side Acoustic Echo Cancellation (AEC) isn't calibrated properly, the microphone picks up the system's own speaker output. The STT layer misinterprets the system's voice as a user, causing the agent to interrupt itself mid-sentence.
* **State Synchronization Overhead:** The orchestration layer must track precisely how many words the TTS engine managed to speak before being interrupted. If the system stops after 3 words out of a 10-word sentence, the engine must update its memory state to reflect only what the user actually heard before the user spoke over it.
* **Loss of Paralinguistic Signals:** The STT layer detects *words* and *volume thresholds*, but often strips out tone, pitch, or sarcasm. It knows the user interrupted, but it struggles to infer *how* frustrated or excited they were unless an extra acoustic classification model is added alongside the STT layer.

### Summary

Cascaded pipelines do not need to be rigid. By using low-latency streaming STT combined with signal routing, you can abort ongoing audio generation, listen continuously, and accumulate background context smoothly. It simply shifts the engineering challenge from model architecture to real-time stream orchestration.

===

Platforms are increasingly doing the heavy lifting by **moving low-latency turn management directly into the native OS layers**.

Apple’s APIs—like `SpeechAnalyzer` and native `SpeechDetector` modules—provide local, low-latency streaming tools. These frameworks allow apps to perform on-device Voice Activity Detection (VAD) and streaming acoustic analysis directly over Apple Silicon.

This native OS shift changes the engineering landscape for both cascaded and full-duplex systems in three significant ways:

---

### 1. Zero-Latency Local Interruption

Instead of streaming continuous microphone audio over the web to a cloud provider just to detect whether someone spoke, the **OS handles the front line locally on the NPU/DSP**:

* **On-Device VAD:** The system detects local speech onset in under 20ms.
* **Local Mute/Flush:** The app instantly cuts off the local audio playback buffer before the cloud server even knows an interruption occurred.
* **Bandwidth & Privacy Savings:** Raw silence or background fan noise never leaves the machine; audio streams to the cloud only when active, validated speech frames are detected.

### 2. Offloading the Orchestration Burden

Historically, developers building voice agents had to integrate third-party libraries (like Silero VAD or WebRTC VAD) or build custom C++ audio graphs to handle buffer management.

By building `SpeechAnalyzer` and streaming speech detection natively into the OS:

* State management for turn-taking (e.g., hysteresis, start-of-speech, end-of-speech boundaries) is standardized.
* The system handles Hardware Echo Cancellation (AEC) out-of-the-box, eliminating the issue of the app "hearing itself" and self-interrupting.

### 3. The Remaining Frontier: Cognitive Alignment

While OS-level frameworks solve the **signal-level mechanics** of barge-in, they leave one crucial problem for the model layer: **semantic continuity**.

```
[OS Layer (macOS)] ──► Local VAD detects voice ──► Instantly kills local audio speaker stream
                               │
[Cloud / Model Engine] ────────┴─► Receives partial string: "Wait, actually, I meant..."
                                     └─► Needs to reconcile where it was interrupted mid-sentence

```

When local OS tools trigger an instant abort:

* The LLM still needs to know **where** in its output stream it was cut off (e.g., word 4 of a 20-word response).
* The model must re-evaluate if the interruption was meaningful (e.g., *"Stop!"*) or just a minor backchannel sound (e.g., *"Uh-huh"*).

---

### Summary

The platform-level integration of VAD and real-time speech analytics removes the primary engineering friction of building voice interfaces.

Because the operating system handles continuous listening, noise suppression, and instant muting on-device, developer focus is shifting away from building complex audio transport pipelines and toward managing **semantic turn-taking and continuous memory state**.

===

Cascade Architectures

- Modern: **optimized streaming cascade pipeline**
- Legacy: **batch/legacy cascade pipeline**.

While streaming cascades drastically improve user experience, they still differ fundamentally from true **native omni-models**:

### 1. The Two Cascade Paradigms

* **Legacy Batch Cascade:**
* *Workflow:* `Audio input -> STT transcribes full phrase -> Text LLM processes -> TTS generates audio file -> User hears response`.
* *Characteristics:* High latency (2 to 5 seconds of silence), zero ability to interrupt gracefully, and complete loss of non-verbal information (tone, pitch, background noise) at the text conversion step.


* **Modern Streaming Cascade:**
* *Workflow:* Audio is chunked and streamed via WebSockets. Partial STT tokens trigger LLM generation immediately, which streams tokens into a low-latency TTS model.
* *Interruption (Barge-in):* When client-side or server-side Voice Activity Detection (VAD) detects user speech mid-response, an **abort signal** cancels the active LLM context generation and halts the TTS playback buffer immediately.
* *Characteristics:* Latency drops significantly (under 1 second), and barge-in feels responsive. However, the core reasoning engine is still a **text-only LLM** operating behind discrete protocol handoffs.



---

### 2. Why Streaming Cascades Aren't "Native Omni"

Even a heavily optimized streaming cascade has architectural constraints that set it apart from end-to-end (native) omni-models:

* **Information Bottleneck:** A streaming cascade converts audio tokens into text tokens for the LLM. In doing so, it strips out paralinguistic cues—sarcasm, emotional tone, accent, pitch, speed, and background sounds.
* **Interrupted Reasoning:** When a streaming cascade receives an abort signal, it abruptly cuts the process. A native omni-model (like GPT-4o or Moshi), operating directly on continuous audio tokens, can organically process the incoming interruption audio stream *while* stopping its output generation, enabling natural conversational overlap (e.g., handling "Wait, hold on!" without resetting the entire context).
* **Coordination Overhead:** Streaming pipelines require managing session states, WebSocket connections, VAD buffers, and cancel tokens across three distinct services (ASR, LLM, TTS). A single point of failure at any link breaks the interaction.

---

### 3. Will Future Omni Models Rely on Cascades?

**No, but production voice applications will continue to use both.**

* **Native Omni Models** remain the standard for high-level conversational AI because processing audio, vision, and text in a single shared latent space provides lower latency and rich emotional understanding.
* **Streaming Cascades** remain the choice for enterprise deployments. They allow developers to swap in the latest frontier text model (e.g., upgrading an LLM without retraining an audio model), log exact text transcripts for compliance/debugging, and enforce strict, deterministic tool-calling rules.

===

Using **Moshi** as a client-side conversational front-end alongside a local symbolic or tool-agent backbone is a viable hybrid design pattern.

Kyutai designed Moshi with lightweight variants (e.g., MLX for Apple Silicon) specifically so it can run locally on consumer hardware.

Here is how that hybrid setup works in practice:

---

### 1. The Architecture: Split Responsibilities

Instead of relying on Moshi for complex multi-step reasoning, tool execution, or long-term state management, you divide the workload:

```
                  ┌────────────────────────────────────────────────────────┐
                  │                 CLIENT / LOCAL DEVICE                  │
                  │                                                        │
┌──────────┐  Audio   ┌────────────────────────┐  Text Streams  ┌──────────┤
│          ├─────────►│         MOSHI          ├───────────────►│          │
│   User   │  Stream  │  (Low-Latency Front)   │ (Inner Monologue)│ Local    │
│          │◄─────────┤  Models voice dynamics │◄───────────────┤ Agent    │
└──────────┘  Audio   └────────────────────────┘ Audio Interrupt│ Controller
              Stream                                Control     │          │
                                                                └──────────┤
                                                                           │
                                                                           ▼
                                                                  [UI State / Actions]

```

* **Moshi (The Low-Latency Interactivity Layer):** Handles full-duplex speech input/output, voice tone, micro-interruptions, and instantaneous conversational turn-taking.
* **Local Controller Model (The Agent & Tool Engine):** A quantized local model (like a 3B–8B LLM/SLM) or deterministic code layer that monitors Moshi’s output, controls conversation flow, invokes client APIs, and renders UI artifacts.

---

### 2. How the Two Layers Communicate

Because Moshi generates an **"Inner Monologue"** (text tokens predicted *simultaneously* alongside its speech tokens), you don't need a separate Whisper model running locally to transcribe what the user or Moshi is saying.

1. **Text Extraction:** As Moshi listens to the user and responds, its inner text stream emits plain text in real time.
2. **Agent Triggering:** The agent controller parses this stream for intent, system commands, or explicit trigger phrases.
3. **Artifact Execution:** If the user asks, *"Show me a map of my location"* or *"Generate a chart,"* Moshi responds fluidly in voice while the Local Agent parses the text stream to update the local application UI, render graphics, or launch external tools.
4. **Context Injections & Guidance:** The local controller can inject text prompts back into Moshi’s context buffer to steer what Moshi should discuss or output next.

---

### 3. Benefits of this Hybrid Approach

* **Ultra-Low Latency Voice UI:** User interactions feel instant (~200ms audio latency) because Moshi handles natural conversational back-and-forth natively without waiting for an LLM pipeline.
* **Local Privacy & Offline Functionality:** Processing the audio stream and agent logic entirely on-device eliminates cloud bandwidth usage, data leakage, and external network latency.
* **Separation of Concerns:** Speech models often struggle with strict JSON formatting, tool calling, or deterministic UI states. Delegating structured logic to a dedicated local agent keeps the system reliable without compromising voice fluidity.

---

### 4. Technical Challenges to Consider

* **Resource Contention:** Running Moshi (7B parameters, even quantized to 4-bit) alongside a secondary local agent model requires significant unified memory (NPU/RAM) on devices like Apple MacBooks or high-end mobile chipsets.
* **Latency Calibration:** If the local agent takes too long to make a decision and update Moshi's prompt context, Moshi might already be generating its next audio phrase, requiring client-side audio barge-in or context-cancellation triggers.

===

[Kyutai's Moshi engine](https://kyutai.org/codec-explainer/) exposes mechanisms to inspect its real-time text streams, but its native architecture fundamentally changes **how and why** interruptions occur compared to traditional pipelines.

### How Text Stream Extraction Works

Moshi’s backbone generates parallel autoregressive streams. Beyond raw audio tokens, it generates an **Inner Monologue** stream:

* **Output Stream Monitoring:** The WebSocket/Client API (available across PyTorch, MLX, and Rust implementations) emits text tokens as they are predicted. You can attach listeners or hooks to the streaming text output as Moshi speaks, giving you a real-time text buffer of its active output.
* **Input Stream Transcription:** Because Moshi models user input alongside its own output, its inner text decoder also provides real-time streaming speech recognition (ASR) with minimal delay.

---

### Understanding Interruptions in Moshi: Native vs. Handled

Because Moshi is a native, full-duplex model, **you do not strictly need a custom text hook to "interrupt" it.**

#### 1. Native Interruption (Out of the Box)

In a traditional cascade, you must actively issue an "Abort/Cancel" signal to kill the text-to-speech stream when user audio is detected.

Moshi processes input audio and output audio in the same step. If a user speaks over Moshi, the model's audio encoder hears the incoming audio tokens and **organically changes its output stream to silence or an interjection** (e.g., stopping mid-sentence and saying, *"Oh, go ahead!"*).

#### 2. Manual Programmatic Interruption (The Hook Pattern)

If you are using a local agent controller to drive UI elements or trigger external actions, relying solely on Moshi’s organic voice interruption might not be enough. You will want to reset state or halt background agent tasks immediately.

You can implement programmatic interruption using Moshi’s streams:

```
[User Audio Input] ──► [Moshi Core Model] ──► [Inner Monologue Text Stream Hook]
                              │                                │
                              ▼                                ▼
                     [Native Audio Output]             [Agent Controller]
                       (Organic Pause)                 (Executes Abort / 
                                                        Resets UI Context)

```

1. **Listen to User Input Stream:** Hook into the incoming user audio or Moshi's internal transcription stream.
2. **Detect Interruption Trigger:** When user speech is detected or specific keywords are parsed mid-utterance, trigger your client-side event bus.
3. **Issue State Cancellation:**
* Flush the current client playback audio buffer.
* Cancel active tool/API calls being executed by your local agent backbone.
* Send a reset or context-injection signal to Moshi’s generation state to align it with the new conversation direction.

By tapping into Moshi's streaming `Inner Monologue` tokens, your application gets immediate visibility into what is being said without waiting for turn-ending cues or sentence boundaries.

===

**YMoshi can be run inside an iOS app**, but whether you run it **locally on-device** or via a **hybrid client-server architecture** depends on hardware constraints.

---

### 1. On-Device Execution (Running Moshi directly on an iPhone)

Kyutai maintains an official **[MLX implementation (`moshi_mlx`)](https://github.com/kyutai-labs/moshi)** explicitly targeted for Apple Silicon, including macOS and iOS.

However, running it purely on-device presents significant hardware challenges:

* **Memory Footprint (RAM):** Moshi’s core model is ~7 Billion parameters. Even when aggressively quantized to **4-bit (`q4`)**, it requires **~4 GB to 4.5 GB of Unified Memory** strictly for the model weights.
* **iOS RAM Limits:** On devices with 6 GB or 8 GB of total RAM (like base iPhone models), iOS aggressively kills processes that exceed specific memory thresholds (often around 3 GB to 4 GB for a single app context). You need top-tier hardware (e.g., iPhone 15 Pro, 16 Pro, or newer with 8GB+ RAM) to run the quantized model without hitting Out-Of-Memory (OOM) crashes.
* **Thermal & Battery Throttling:** Running a 7B full-duplex autoregressive model continuously on the Apple Neural Engine/GPU will generate considerable heat and drain the battery quickly during sustained conversations.

---

### 2. The Recommended iOS Architecture: Hybrid / Thin Client

In practice, most developers targeting iOS deploy Moshi using a **Client-Server streaming bridge** rather than bundling the 7B weight files directly into the iOS `.ipa` bundle:

```
┌─────────────────────────────────────────┐
│               iOS App                   │
│                                         │
│  [AVAudioEngine] ──(PCM Audio)──┐       │
│                                 │       │
│                               WebSocket │
│                                 │       │
│  [AVAudioPlayer] ◄─(PCM Audio)──┘       │
│         │                               │
│  (Triggers UI Events)                   │
└─────────────────────────────────────────┘
                  ▲
                  │  Low-latency bidirectional stream
                  ▼
┌─────────────────────────────────────────┐
│             Server / Edge               │
│  Runs Moshi in Rust / PyTorch (CUDA/Metal)
└─────────────────────────────────────────┘

```

#### How to Build the iOS App in this Setup:

1. **Audio Streaming Engine:** Use iOS native `AVAudioEngine` to capture microphone input as PCM/AAC and stream it via **WebSockets** or **WebRTC** directly to a Moshi backend (which can run in Rust via `rustymimi` or PyTorch on an edge GPU/Mac mini).
2. **Receiving Audio & Text Hooks:** The Moshi backend streams back dual payloads: audio buffers (for immediate playback via `AVAudioPlayer` or `AVAudioEngine`) and `Inner Monologue` text JSON tokens.
3. **Swift UI Driving:** In your Swift code, parse the incoming `Inner Monologue` text stream to dynamically update the UI, display transcription, or trigger local iOS native features (like Haptics, Maps, or CoreData saves) in real time.

---

### Summary Checklist for iOS Developers

| Approach | Feasibility | Best For | Prerequisites |
| --- | --- | --- | --- |
| **On-Device (Local)** | ⚠️ Experimental | Offline apps, high-end Pro iPhones | `moshi_mlx` / CoreML, 4-bit quantization, 8GB+ RAM device |
| **Hybrid (Server Streaming)** | Production Ready | Responsive, low-latency mobile apps | iOS `AVAudioEngine`, WebSockets/WebRTC, hosted Rust/PyTorch Moshi instance |

===

The OpenAI WebSockets API encodes raw PCM/G.711 audio into Base64 text strings and embeds them directly inside JSON payloads (e.g., session.input_audio.append or response.audio.delta). This creates the exact "traffic jam" or Head-of-Line (HoL) Blocking problem you referenced:

**`gpt-live-1` (and OpenAI's broader Realtime API family) natively supports WebRTC**. In fact, OpenAI explicitly recommends WebRTC over WebSockets for client-side applications like web browsers and mobile apps.

### How WebRTC Works with `gpt-live-1`

When using WebRTC, the protocol architecture shifts away from base64 JSON packets to direct, dedicated transport channels:

1. **SRTP Media Tracks (Audio):** User microphone input and the model's generated speech travel as raw, unencoded binary audio on low-latency UDP media tracks. This completely avoids the Base64 JSON overhead and eliminates Head-of-Line (HoL) blocking on the audio path.
2. **`oai-events` DataChannel (Text & Control):** Rather than putting text on the same rail as audio bytes, WebRTC opens a parallel **SCTP DataChannel** named `oai-events`. Text messages, system instructions, native ASR transcript fragments, and backend tool/delegation signals are sent back and forth as JSON messages on this data channel.

### WebRTC vs. WebSocket Guidance for `gpt-live-1`

OpenAI's official transport guidance divides usage by client architecture:

| Transport | Recommended Use Case | Why |
| --- | --- | --- |
| **WebRTC** | **Browsers & Mobile Apps** | Operates over UDP with media track isolation. Handles packet loss natively and avoids audio delay caused by TCP retransmissions. |
| **WebSocket** | **Server-to-Server / Middle-Tier** | Ideal when audio is already streaming through a backend server (e.g., Python/Node.js) or environments without native WebRTC support. |
| **SIP / Telephony** | **Phone Agents** | Directly bridges live phone calls into the voice model. |

### How Connections Are Negotiated

Because you shouldn't put a secret OpenAI API key on a public client (like a web browser), WebRTC uses an **ephemeral session workflow**:

```
┌────────────────┐           ┌────────────────┐           ┌────────────────┐
│ Browser / App  │           │ Application    │           │ OpenAI API     │
│ (WebRTC Client)│           │ Server         │           │ (gpt-live-1)   │
└───────┬────────┘           └───────┬────────┘           └───────┬────────┘
        │                            │                            │
        │ 1. Request Session         │                            │
        ├───────────────────────────►│                            │
        │                            │ 2. POST /v1/live/sessions  │
        │                            │    (Uses Secret API Key)   │
        │                            ├───────────────────────────►│
        │                            │                            │
        │                            │ 3. Returns Ephemeral Token │
        │                            │◄───────────────────────────┤
        │ 4. Receives Token / SDP    │                            │
        │◄───────────────────────────┤                            │
        │                                                         │
        │ 5. WebRTC PeerConnection SDP Exchange (Media & Data)    │
        ◄────────────────────────────────────────────────────────►

```

This allows client-side applications (web browsers, iOS, or Android) to stream full-duplex speech and text over WebRTC directly to OpenAI without exposing API credentials or suffering the latency issues of TCP-based WebSockets.

===
is it just me or are kyutai voices sound waterlogged, muffled softly?
===

It is **definitely not just you.** Many listeners describe Moshi's raw output audio as sounding slightly "muffled," "waterlogged," or as if the speaker is talking through a soft filter or underwater.

This distinctive audio quality stems directly from the architectural trade-offs Kyutai made to achieve real-time latency.

---

### 1. Ultra-Low Bitrate Compression (`Mimi` Codec)

Moshi uses a custom neural audio codec called **Mimi**. To make full-duplex speech stream in real time with sub-200ms latency on low-end hardware, Mimi compresses audio down to an extremely small bitrate—just **~1.1 kbps** at 12.5Hz.

For context, standard MP3 audio typically runs at 128 to 320 kbps. When a neural codec compresses audio down to 1.1 kbps, high-frequency details (like crisp "s", "t", and "f" consonant sounds) get smoothed over or lost. This loss of high frequencies creates that classic "muffled" or "underwater" sound.

### 2. Residual Vector Quantization (RVQ) Artifacts

Mimi breaks continuous audio down using discrete math layers called **Residual Vector Quantization (RVQ)**.

If an audio codec doesn't use enough quantization layers—or uses aggressive 4-bit/8-bit quantization on lower hardware—the reconstructed audio introduces phase smearing and acoustic phase noise. The human ear perceives this as a slight "phasing," "bubbling," or "waterlogged" artifact riding underneath the voice.

### 3. Upsampled & Synthetic Training Data

Kyutai trained Moshi's audio component on thousands of hours of conversational speech. A portion of this training audio (such as the classic Fisher phone dataset) was originally recorded at **8kHz phone-call quality** and artificially upsampled to **24kHz**.

Because neural models adopt the acoustic properties of their training environment, Moshi naturally inherited some of the muffled, bandpass-filtered characteristics of vintage telephone recordings.

---

### Summary

The soft, muffled sound is the acoustic "price tag" paid for **instantaneous conversational speed**. Pipelines like GPT-4o or traditional TTS systems sound crisper because they run heavy high-bitrate vocoders over cloud GPUs, whereas Kyutai prioritized lightweight, end-to-end efficiency that can run locally on an Apple Mac.

For a deep dive into how Kyutai balances codec levels against audio clarity, you can check out [Kyutai's Codec Explainer](https://kyutai.org/codec-explainer/), which breaks down the trade-offs of the Mimi neural audio codec.

This video demonstrates the technical details and trade-offs of the Mimi neural audio codec in Moshi.

===
couldn't we train a model to fill in the difference between a live speech and recorded speech? waterlogged sound has a strong whiff of recorded sound reminescent of audio recorded from the past like stuffed with socks. just sharpening the knives to bring its live edges back, so to speak.
===

Yes, absolutely. What you are describing is a well-established subfield of AI signal processing called **Audio Super-Resolution (ASR)** or **Speech Bandwidth Extension (BWE)**.

The concept works just like video/image upscaling (like DLSS or Apple’s spatial audio upmixing): a lightweight, post-processing model takes the "stuffed-in-socks" audio output from a native model like Moshi and halluncinates the missing high-frequency details in real time.

---

### How to "Sharpen the Knives"

To fix Moshi's muffled sound, you would run its streaming output through a dedicated **neural vocoder / enhancement model**:

```
[Moshi Native Core] ──► [1.1 kbps Muffled Stream] ──► [Bandwidth Extension Model] ──► [24kHz / 48kHz Crisp Audio]
 (Sub-200ms Latency)                                     (Neural Vocoder / Upscaler)            (High-Frequency Polish)

```

1. **Bandwidth Extension (BWE):** Models like HiFi-GAN or neural audio upscalers are trained paired datasets: low-bitrate, heavily compressed audio vs. uncompressed studio-master recordings. The network learns to predict the missing upper harmonics above 4 kHz—reconstructing crisp $s$, $t$, and $f$ consonant sounds, airiness, and transient snap.
2. **Phase Restoration:** Neural vocoders synthesize realistic phase alignment, eliminating the "bubbling" underwater effect caused by vector quantization (RVQ).

---

### Why Kyutai Didn't Do This Out of the Box

If it’s technically feasible, why wasn't a post-processing filter included directly in Moshi?

* **Latency Overhead:** Even a fast feed-forward neural upscaler adds a few extra milliseconds of processing latency. Kyutai prioritised making Moshi sub-200ms to preserve immediate conversational turn-taking.
* **Device Compute Constraints:** Moshi was optimized to run locally on consumer devices like M-series MacBooks or high-end iPads. Running the 7B conversational backbone *plus* a second real-time high-fidelity vocoder on the GPU pushes unified memory bandwidth and thermal limits much harder.
* **Separation of Concerns:** Kyutai focused on solving full-duplex conversational reasoning. Polishing the acoustic output is something developers can add to their client-side pipeline depending on whether their target device has the extra compute headroom.

---

### The Practical Solution for Developers

If you build an app on top of Moshi, you can use a hybrid client-side pipeline:

* On **iOS / low-power mobile**, run raw Moshi to save battery and keep latency minimal.
* On **macOS / desktop**, attach a lightweight post-processing audio unit or streaming neural vocoder to "un-stuff the socks" and restore the crisp, live edge before sending the audio buffer to the speakers.

===
But couldn't the speech audio patterns latent in Moshi's TTS model be fine-tuned to give generated voice that 'live' edge?
===

Yes, you **can** fine-tune Moshi to improve its vocal dynamics, but fine-tuning the 7B Transformer model alone won't completely eliminate the "stuffed-in-socks" sound.

Understanding why requires looking at how Moshi handles audio generation:

---

### 1. The Bottleneck: Fine-Tuning the LLM vs. Retraining the Codec

Moshi's audio output pipeline consists of two distinct components:

1. **The Transformer (Moshi / Helium):** Predicts the token sequence (what to say, the pitch, tone, pace, and vocal emotion).
2. **The Neural Audio Codec (Mimi):** Translates those predicted acoustic tokens into actual time-domain audio waveforms.

If you fine-tune Moshi's Transformer backbone using [Kyutai's official `moshi-finetune` framework](https://github.com/kyutai-labs/moshi-finetune) on crisp, studio-master speech recordings, you **will** improve the vocal delivery. The model learns better pronunciation, more energetic inflection, and fewer telephone-style mumbles.

However, the output tokens generated by the Transformer still have to pass through **Mimi** to turn into playable audio.

---

### 2. Why Mimi Limits the "Live Edge"

Mimi compresses 24 kHz audio down to a **1.1 kbps bitrate** at 12.5 Hz.

* **Physical Information Loss:** At 1.1 kbps, high-frequency acoustic details (specifically the air, crispness, and sibilants above 4 kHz) are heavily downsampled before the model ever sees them.
* **Reconstruction Limit:** Even if the Transformer predicts the "perfect" acoustic token for a sharp $S$ sound, Mimi's decoder lacks the bandwidth to reconstruct that sharp, high-frequency transient without introducing slight quantization artifacts or smearing.

Fine-tuning the Transformer is like handing a world-class singer a cheap walkie-talkie—they might sing with incredible technique, but the hardware still muffled the signal.

---

### 3. How to Actually Achieve the "Live Edge"

To bring out those crisp, live edges, you have to address both layers of the pipeline:

#### Option A: Fine-Tune Moshi + Retrain/Fine-Tune Mimi

To get native crispness, you would need to:

1. Retrain or fine-tune the **Mimi neural codec** on pristine, uncompressed 24kHz/48kHz audio datasets to raise its codebook quality and phase accuracy.
2. Fine-tune Moshi's main Transformer on the new Mimi codebook tokens using [moshi-finetune](https://github.com/kyutai-labs/moshi-finetune) so it understands how to emit the higher-fidelity acoustic tokens.

#### Option B: Fine-Tune Moshi + Add a Streaming Vocoder (The Practical Route)

Instead of retraining the whole codec, developers pair Moshi with a lightweight real-time post-processor:

* Fine-tune Moshi on clean studio datasets so its tone, pace, and speech cadence sound natural and energetic.
* Pass Mimi's raw 1.1 kbps audio output through a **streaming bandwidth extension (BWE) model** or neural vocoder (like a lightweight HiFi-GAN). The vocoder acts as a real-time "excite/sharpening" filter, reconstructing the missing upper frequencies to make the voice pop.

