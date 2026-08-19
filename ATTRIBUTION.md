# Attribution

Structural/design inspiration:

- sanidhyy/duolingo-clone
- https://github.com/sanidhyy/duolingo-clone
- MIT License

The native SwiftUI app no longer uses the clone repository's static lesson character/mascot SVGs at runtime. No React/Next.js source files are included.

Temporary private-prototype character reference:

- hewad-mubariz/duolingo-clone
- https://github.com/hewad-mubariz/duolingo-clone
- No repository license declared as of 2026-08-19

For this personal prototype only, LingoNative loads the repository's `duo.riv`, `girl.riv`, and `man.riv` character files remotely from a pinned commit. These are temporary prototype assets and must be replaced before any public distribution, release, or commercial use of LingoNative. The Rive web runtime is used only to render those files inside the existing native `WKWebView` bridge.

Drag-and-drop sentence interaction reference:

- RafaelGoulartB/duolingo-drag-and-drop
- https://github.com/RafaelGoulartB/duolingo-drag-and-drop
- MIT License

The SwiftUI implementation is native code inspired by the interaction model: a word bank, sentence area, return-to-bank behaviour, reordering and spring-like movement.

Spaced-retention research reference:

- duolingo/halflife-regression
- https://github.com/duolingo/halflife-regression
- MIT License
- B. Settles and B. Meeder (2016), “A Trainable Spaced Repetition Model for Language Learning,” ACL 2016.

LingoNative uses the public HLR recall equation `p = 2^(-t/h)` and the public 15-minute/274-day half-life bounds. It does not bundle Duolingo's production model or pretrained regression weights; phrase half-lives are adapted locally from this user's own answer history.
