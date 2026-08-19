# Attribution

Structural/design inspiration and private prototype visual references:

- sanidhyy/duolingo-clone
- https://github.com/sanidhyy/duolingo-clone
- MIT License

The native SwiftUI app references the clone repository's public SVG character/mascot artwork at a pinned commit for this personal prototype. No React/Next.js source files are included.

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
