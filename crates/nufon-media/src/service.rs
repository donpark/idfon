use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use iroh_live::{
    media::{codec::AudioCodec, format::AudioPreset, publish::LocalBroadcast, AudioBackend},
    Live,
};
use nufon_protocol::{MediaKind, MediaSession};
use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum MediaServiceError {
    #[error("media session not found")]
    NotFound,
    #[error("media session is already stopped")]
    AlreadyStopped,
    #[error("media backend unavailable")]
    MediaUnavailable,
    #[error("media resource is already started")]
    AlreadyStarted,
    #[error("media resource is not started")]
    NotStarted,
}

#[derive(Clone)]
pub struct MediaSessionHandle {
    session: MediaSession,
    state: Arc<Mutex<SessionState>>,
    publisher: Arc<Mutex<Option<LivePublisher>>>,
    subscriber: Arc<Mutex<Option<LiveSubscriber>>>,
    recording: Arc<Mutex<Option<LocalResource>>>,
    playback: Arc<Mutex<Option<LocalResource>>>,
}

struct LivePublisher {
    live: Live,
    _broadcast: LocalBroadcast,
}

struct LiveSubscriber {
    live: Live,
    _subscription: iroh_live::Subscription,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LocalResource {
    Recording,
    Playback,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SessionState {
    Active,
    Stopped,
}

impl MediaSessionHandle {
    pub fn session(&self) -> &MediaSession {
        &self.session
    }

    pub fn is_active(&self) -> bool {
        *self.state.lock().expect("media session poisoned") == SessionState::Active
    }

    pub fn start_recording(&self) -> Result<(), MediaServiceError> {
        if !self.is_active() {
            return Err(MediaServiceError::AlreadyStopped);
        }
        let mut recording = self.recording.lock().expect("recording poisoned");
        if recording.is_some() {
            return Err(MediaServiceError::AlreadyStarted);
        }
        *recording = Some(LocalResource::Recording);
        Ok(())
    }

    pub fn stop_recording(&self) -> Result<(), MediaServiceError> {
        let mut recording = self.recording.lock().expect("recording poisoned");
        if recording.take().is_none() {
            return Err(MediaServiceError::NotStarted);
        }
        Ok(())
    }

    pub fn start_playback(&self) -> Result<(), MediaServiceError> {
        if !self.is_active() {
            return Err(MediaServiceError::AlreadyStopped);
        }
        let mut playback = self.playback.lock().expect("playback poisoned");
        if playback.is_some() {
            return Err(MediaServiceError::AlreadyStarted);
        }
        *playback = Some(LocalResource::Playback);
        Ok(())
    }

    pub fn stop_playback(&self) -> Result<(), MediaServiceError> {
        let mut playback = self.playback.lock().expect("playback poisoned");
        if playback.take().is_none() {
            return Err(MediaServiceError::NotStarted);
        }
        Ok(())
    }

    pub async fn start_publisher(&self) -> Result<String, MediaServiceError> {
        if self.session.kind != MediaKind::LiveAudio || !self.is_active() {
            return Err(MediaServiceError::AlreadyStopped);
        }
        let input = AudioBackend::default()
            .default_input()
            .await
            .map_err(|_| MediaServiceError::MediaUnavailable)?;
        let live = Live::from_env()
            .await
            .map_err(|_| MediaServiceError::MediaUnavailable)?
            .with_router()
            .spawn();
        let broadcast = LocalBroadcast::new();
        broadcast
            .audio()
            .set(input, AudioCodec::Opus, [AudioPreset::Hq])
            .map_err(|_| MediaServiceError::MediaUnavailable)?;
        let name = format!("nufon-session-{}", self.session.session_id);
        live.publish(&name, &broadcast)
            .await
            .map_err(|_| MediaServiceError::MediaUnavailable)?;
        let ticket = iroh_live::ticket::LiveTicket::new(live.endpoint().addr(), &name).serialize();
        *self.publisher.lock().expect("publisher poisoned") = Some(LivePublisher {
            live,
            _broadcast: broadcast,
        });
        Ok(ticket)
    }

    pub async fn stop_publisher(&self) -> Result<(), MediaServiceError> {
        let publisher = self.publisher.lock().expect("publisher poisoned").take();
        if let Some(publisher) = publisher {
            publisher.live.shutdown().await;
        }
        Ok(())
    }

    pub async fn start_subscriber(&self, ticket: &str) -> Result<(), MediaServiceError> {
        if self.session.kind != MediaKind::LiveAudio || !self.is_active() {
            return Err(MediaServiceError::AlreadyStopped);
        }
        let ticket = iroh_live::ticket::LiveTicket::deserialize(ticket)
            .map_err(|_| MediaServiceError::MediaUnavailable)?;
        let live = Live::from_env()
            .await
            .map_err(|_| MediaServiceError::MediaUnavailable)?
            .spawn();
        let subscription = live
            .subscribe(ticket.endpoint, &ticket.broadcast_name)
            .await
            .map_err(|_| MediaServiceError::MediaUnavailable)?;
        *self.subscriber.lock().expect("subscriber poisoned") = Some(LiveSubscriber {
            live,
            _subscription: subscription,
        });
        Ok(())
    }

    pub async fn stop_subscriber(&self) -> Result<(), MediaServiceError> {
        let subscriber = self.subscriber.lock().expect("subscriber poisoned").take();
        if let Some(subscriber) = subscriber {
            drop(subscriber._subscription);
            subscriber.live.shutdown().await;
        }
        Ok(())
    }

    pub fn stop(&self) -> Result<(), MediaServiceError> {
        let mut state = self.state.lock().expect("media session poisoned");
        if *state == SessionState::Stopped {
            return Err(MediaServiceError::AlreadyStopped);
        }
        *state = SessionState::Stopped;
        let _ = self.recording.lock().expect("recording poisoned").take();
        let _ = self.playback.lock().expect("playback poisoned").take();
        Ok(())
    }
}

/// Owns logical media sessions. Concrete capture/publish resources are attached
/// to these handles as the daemon media backend is migrated.
#[derive(Clone, Default)]
pub struct MediaService {
    sessions: Arc<Mutex<HashMap<String, MediaSessionHandle>>>,
}

impl MediaService {
    pub fn start(
        &self,
        session_id: impl Into<String>,
        identity: impl Into<String>,
        peer: impl Into<String>,
        kind: MediaKind,
        capability: nufon_protocol::Capability,
    ) -> MediaSessionHandle {
        let session = MediaSession {
            session_id: session_id.into(),
            identity: identity.into(),
            peer: peer.into(),
            conversation: None,
            kind,
            capability,
            active: true,
            created_at: "0".into(),
        };
        let handle = MediaSessionHandle {
            session,
            state: Arc::new(Mutex::new(SessionState::Active)),
            publisher: Arc::new(Mutex::new(None)),
            subscriber: Arc::new(Mutex::new(None)),
            recording: Arc::new(Mutex::new(None)),
            playback: Arc::new(Mutex::new(None)),
        };
        self.sessions
            .lock()
            .expect("media service poisoned")
            .insert(handle.session.session_id.clone(), handle.clone());
        handle
    }

    pub fn get(&self, session_id: &str) -> Result<MediaSessionHandle, MediaServiceError> {
        self.sessions
            .lock()
            .expect("media service poisoned")
            .get(session_id)
            .cloned()
            .ok_or(MediaServiceError::NotFound)
    }

    pub fn stop(&self, session_id: &str) -> Result<(), MediaServiceError> {
        self.get(session_id)?.stop()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handles_have_explicit_lifecycle() {
        let service = MediaService::default();
        let handle = service.start(
            "session-1",
            "default",
            "alice",
            MediaKind::LiveAudio,
            nufon_protocol::Capability::LiveAudioSubscribe,
        );
        assert!(handle.is_active());
        service.stop("session-1").unwrap();
        assert!(!handle.is_active());
        assert_eq!(
            service.stop("session-1"),
            Err(MediaServiceError::AlreadyStopped)
        );
    }

    #[test]
    fn local_recording_and_playback_resources_are_explicit() {
        let service = MediaService::default();
        let handle = service.start(
            "session-2",
            "default",
            "alice",
            MediaKind::Recording,
            nufon_protocol::Capability::RecordingRetain,
        );
        handle.start_recording().unwrap();
        assert_eq!(
            handle.start_recording(),
            Err(MediaServiceError::AlreadyStarted)
        );
        handle.stop_recording().unwrap();
        handle.start_playback().unwrap();
        handle.stop().unwrap();
        assert!(!handle.is_active());
        assert_eq!(handle.stop_playback(), Err(MediaServiceError::NotStarted));
    }
}
