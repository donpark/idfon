# Idfon

Idfon is a flexible communication system, not just a traditional phone or audio/video chat app. It should support diverse, loosely coupled ways for individuals and groups to reach one another—text, asynchronous voice, live audio, broadcasting, interruption, and other capabilities—with fine-grained control over what each person or group is allowed to do and how those interactions affect the recipient’s attention.

The product model is based on independently grantable communication capabilities and local UX policies, rather than a single monolithic call state. See [Communication Model](docs/communication-model.md) for the guiding concepts, modes, permissions, and privacy requirements.

The current audio implementation and its verified status are documented in [Audio Media](docs/audio-media.md), including the Rust media layer behind the Native SDK Zig app, `iroh-live` streaming, `iroh-blobs` recordings, test coverage, and remaining production work.
