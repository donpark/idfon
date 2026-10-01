//! Room membership for the voice 1:1 gate (P2, epic #17).
//!
//! Voice is **1:1 only**. `conversation` alone cannot decide this: a threaded
//! 1:1 also sets it (`docs/chatrooms.md`), so the holder decides by
//! **membership** — a conversation with two or more distinct external senders
//! is a room. The holder sees every inbound envelope before Eve, so it can
//! track this without the channel.
//!
//! ponytail: membership is distinct *senders seen*, not the daemon's full
//! member list (unavailable here); a room whose second member has never posted
//! is treated as a thread. Tighten if a room-member signal reaches the holder.

use std::{
    collections::{HashMap, HashSet},
    sync::{Mutex, OnceLock},
};

/// External senders observed per conversation.
#[derive(Default)]
pub struct RoomRegistry {
    members: Mutex<HashMap<String, HashSet<String>>>,
}

impl RoomRegistry {
    /// Record `sender` in `conversation`; returns whether it is now a room
    /// (two or more distinct senders).
    pub fn observe(&self, conversation: &str, sender: &str) -> bool {
        if conversation.is_empty() {
            return false;
        }
        let mut members = self.members.lock().expect("room registry poisoned");
        let set = members.entry(conversation.to_string()).or_default();
        set.insert(sender.to_string());
        set.len() >= 2
    }

    /// Whether this conversation is a room (>= 2 distinct senders).
    pub fn is_room(&self, conversation: Option<&str>) -> bool {
        let Some(conversation) = conversation.filter(|id| !id.is_empty()) else {
            return false;
        };
        self.members
            .lock()
            .expect("room registry poisoned")
            .get(conversation)
            .is_some_and(|members| members.len() >= 2)
    }
}

/// The process-wide registry fed by [`crate::handle_message`].
pub fn registry() -> &'static RoomRegistry {
    static REGISTRY: OnceLock<RoomRegistry> = OnceLock::new();
    REGISTRY.get_or_init(RoomRegistry::default)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn threaded_1to1_is_not_a_room_but_a_second_sender_makes_one() {
        let registry = RoomRegistry::default();
        assert!(!registry.is_room(None));
        assert!(!registry.is_room(Some("")));

        // One external sender in a threaded 1:1: still not a room.
        assert!(!registry.observe("thread-1", "peer-a"));
        assert!(!registry.is_room(Some("thread-1")));

        // A second distinct sender makes it a room.
        assert!(registry.observe("thread-1", "peer-b"));
        assert!(registry.is_room(Some("thread-1")));

        // A different conversation is unaffected.
        assert!(!registry.is_room(Some("thread-2")));
    }

    #[test]
    fn a_repeat_sender_does_not_make_a_room() {
        let registry = RoomRegistry::default();
        assert!(!registry.observe("conv", "peer-a"));
        assert!(!registry.observe("conv", "peer-a"));
        assert!(!registry.is_room(Some("conv")));
    }
}
