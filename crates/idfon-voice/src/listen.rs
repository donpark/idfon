//! Listen-side orchestration: caller audio → partial/final turn events.
//!
//! Phase P2 (epic #17). The engine seam (P1) gives streaming STT and an
//! endpointer; this module owns the turn semantics on top:
//!
//! - **Partials are replaceable** (F2): each [`TranscriptEvent::Partial`]
//!   replaces the previous one for the turn; they never enter agent context.
//! - **Finals are delivered once**: a turn produces at most one
//!   [`TranscriptEvent::Final`]; after it, further events for that turn are
//!   dropped until [`ListenSession::reset`].
//! - **One authoritative endpointer per topology** (F3): under
//!   [`EndpointAuthority::Client`] the on-device endpointer decides end-of-turn
//!   and the service endpointer only feeds barge-in; under
//!   [`EndpointAuthority::Service`] the service semantic VAD finalizes the turn.
//!
//! This module is provider-neutral and offline-testable; P3/P4 wire it to the
//! channel.

use anyhow::Result;

use crate::{AudioFormat, EndpointEvent, Endpointer, SttSession, TranscriptEvent, VoiceEngine};

/// Which endpointer is authoritative for end-of-turn on this topology (F3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EndpointAuthority {
    /// The client's on-device endpointer decides; the service endpointer is
    /// advisory only (barge-in). The service finalizes on hangup/flush.
    Client,
    /// The service's semantic VAD decides; on `SpeechEnded` the session
    /// finalizes the turn.
    Service,
}

/// Result of feeding one audio frame.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ListenOutput {
    pub transcripts: Vec<TranscriptEvent>,
    /// Endpoint transition observed this frame, if any. Always surfaced (even
    /// for a non-authoritative endpointer) so the caller can drive barge-in.
    pub endpoint: Option<EndpointEvent>,
}

/// One listening turn stream: STT + endpointer + final-once bookkeeping.
pub struct ListenSession {
    stt: Box<dyn SttSession>,
    endpointer: Box<dyn Endpointer>,
    authority: EndpointAuthority,
    final_delivered: bool,
}

impl ListenSession {
    pub fn new(
        engine: &dyn VoiceEngine,
        format: AudioFormat,
        authority: EndpointAuthority,
    ) -> Result<Self> {
        Ok(Self {
            stt: engine.stt(format)?,
            endpointer: engine.endpointer(format)?,
            authority,
            final_delivered: false,
        })
    }

    pub fn authority(&self) -> EndpointAuthority {
        self.authority
    }

    /// Feed caller PCM. Returns replaceable partials and, at most once per
    /// turn, the final transcript.
    pub fn push(&mut self, pcm: &[i16]) -> Result<ListenOutput> {
        let mut output = ListenOutput::default();

        let endpoint = self.endpointer.push(pcm)?;
        output.endpoint = endpoint;

        // Authoritative service endpointing finalizes the turn.
        if self.authority == EndpointAuthority::Service
            && endpoint == Some(EndpointEvent::SpeechEnded)
            && !self.final_delivered
        {
            if let Some(text) = self.stt.flush()? {
                output.transcripts.push(TranscriptEvent::Final(text));
            }
            self.final_delivered = true;
        }

        for event in self.stt.push(pcm)? {
            match event {
                // Replaceable partial: pass through unless the turn is closed.
                TranscriptEvent::Partial(text) => {
                    if !self.final_delivered {
                        output.transcripts.push(TranscriptEvent::Partial(text));
                    }
                }
                // Agent-actionable final: deliver once, then close the turn.
                TranscriptEvent::Final(text) => {
                    if !self.final_delivered {
                        output.transcripts.push(TranscriptEvent::Final(text));
                        self.final_delivered = true;
                    }
                }
            }
        }
        Ok(output)
    }

    /// Flush at hangup. Returns a trailing final if the turn had speech that
    /// the provider had not yet finalized.
    pub fn finish(&mut self) -> Result<Option<TranscriptEvent>> {
        if self.final_delivered {
            return Ok(None);
        }
        self.final_delivered = true;
        Ok(self.stt.finish()?.map(TranscriptEvent::Final))
    }

    /// Start a new turn: reopen finals and reset the endpointer. The STT stream
    /// itself is continuous and is not recreated.
    pub fn reset(&mut self) {
        self.final_delivered = false;
        self.endpointer.reset();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::stub::StubVoiceEngine;

    /// A test double returning scripted STT events per `push`, and scripted
    /// `flush` (end of utterance) / `finish` (end of call) values.
    struct ScriptedStt {
        events: Vec<Vec<TranscriptEvent>>,
        flush: Option<String>,
        finish: Option<String>,
        call: usize,
    }

    impl SttSession for ScriptedStt {
        fn push(&mut self, _pcm: &[i16]) -> Result<Vec<TranscriptEvent>> {
            let events = self.events.get(self.call).cloned().unwrap_or_default();
            self.call += 1;
            Ok(events)
        }

        fn flush(&mut self) -> Result<Option<String>> {
            Ok(self.flush.take())
        }

        fn finish(&mut self) -> Result<Option<String>> {
            Ok(self.finish.take())
        }
    }

    fn scripted(events: Vec<Vec<TranscriptEvent>>) -> ScriptedStt {
        ScriptedStt {
            events,
            flush: None,
            finish: None,
            call: 0,
        }
    }

    fn session_with(stt: ScriptedStt, authority: EndpointAuthority) -> ListenSession {
        let engine = StubVoiceEngine::new();
        ListenSession {
            stt: Box::new(stt),
            endpointer: engine.endpointer(AudioFormat::PCM_24K_MONO).unwrap(),
            authority,
            final_delivered: false,
        }
    }

    #[test]
    fn partials_are_replaceable_and_a_final_is_delivered_once() {
        let mut session = session_with(
            scripted(vec![
                vec![TranscriptEvent::Partial("two".into())],
                vec![TranscriptEvent::Partial("two plus".into())],
                vec![TranscriptEvent::Final("two plus two is four".into())],
                // A late duplicate of the same turn must be dropped.
                vec![TranscriptEvent::Final("two plus two is four".into())],
                vec![TranscriptEvent::Partial("late".into())],
            ]),
            EndpointAuthority::Client,
        );

        let first = session.push(&[0; 480]).unwrap();
        assert_eq!(
            first.transcripts,
            vec![TranscriptEvent::Partial("two".into())]
        );
        let second = session.push(&[0; 480]).unwrap();
        assert_eq!(
            second.transcripts,
            vec![TranscriptEvent::Partial("two plus".into())]
        );
        let third = session.push(&[0; 480]).unwrap();
        assert_eq!(
            third.transcripts,
            vec![TranscriptEvent::Final("two plus two is four".into())]
        );
        // Final already delivered: later finals/partials for the turn are gone.
        assert!(session.push(&[0; 480]).unwrap().transcripts.is_empty());
        assert!(session.push(&[0; 480]).unwrap().transcripts.is_empty());

        // A new turn reopens the stream.
        session.reset();
        let next = session.push(&[0; 480]).unwrap();
        assert_eq!(next.transcripts, Vec::new());
    }

    #[test]
    fn service_endpointer_finalizes_but_client_endpointer_does_not() {
        // Service authority: loud frame starts speech, quiet tail ends it and
        // flushes the buffered STT text into a final.
        let mut stt = scripted(vec![]);
        stt.flush = Some("flush transcript".into());
        stt.finish = Some("hangup transcript".into());
        let mut service = session_with(stt, EndpointAuthority::Service);
        assert_eq!(
            service.push(&[2_000; 480]).unwrap().endpoint,
            Some(EndpointEvent::SpeechStarted)
        );
        service.push(&[0; 9_600]).unwrap();
        let ended = service.push(&[0; 9_600]).unwrap();
        assert_eq!(ended.endpoint, Some(EndpointEvent::SpeechEnded));
        assert_eq!(
            ended.transcripts,
            vec![TranscriptEvent::Final("flush transcript".into())]
        );
        // The turn is closed; hangup adds nothing.
        assert_eq!(service.finish().unwrap(), None);

        // Client authority: the service endpointer transition is surfaced for
        // barge-in but never finalizes; hangup flushes instead.
        let mut stt = scripted(vec![]);
        stt.flush = Some("flush transcript".into());
        stt.finish = Some("hangup transcript".into());
        let mut client = session_with(stt, EndpointAuthority::Client);
        client.push(&[2_000; 480]).unwrap();
        client.push(&[0; 9_600]).unwrap();
        let ended = client.push(&[0; 9_600]).unwrap();
        assert_eq!(ended.endpoint, Some(EndpointEvent::SpeechEnded));
        assert!(ended.transcripts.is_empty());
        assert_eq!(
            client.finish().unwrap(),
            Some(TranscriptEvent::Final("hangup transcript".into()))
        );
        // finish is final-once.
        assert_eq!(client.finish().unwrap(), None);
    }
}
