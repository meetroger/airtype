# Dictation improvements

These controls are in Settings → AI. Existing settings and vocabulary are preserved.

- **Local Correction Pairs:** enter `misheard => correct`, one pair per line. Matching is exact and case sensitive; Latin identifiers require word boundaries. Longest match wins, and replacements never chain. Each side is limited to 80 characters. This stage works without AI or a network connection. Canonical vocabulary remains an AI hint; at most eight terms matched by spelling or normalized transliteration are recalled.
- **Review before inserting:** edit the final transcript in the expanded floating panel. To learn a correction, enter the original word and its edited replacement, then click Remember correction. Undo learning restores the preceding rules if they have not since been edited. Insert reactivates the previous application and validates the original field and selection. Save only retains text in History without pasting. Learning is explicit; external editor edits are not monitored.
- **Output style:** Automatic chooses a scene from the original app and field. A manual style takes precedence over per-app rules, which take precedence over automatic detection. Example override: `com.apple.mail => Email`. Valid values are Chat, Email, Search, and Coding / Prompt. Styles affect AI enhancement; translation keeps its separate translation policy.
- **Local live drafts:** off by default. With MLX Local selected, a serial task decodes a snapshot of the latest 20 seconds every four seconds after the preceding decode completes. These are recent-speech previews, not a complete live transcript. Temporary snapshots are removed after decoding. Stop/cancel invalidates pending preview updates. Final transcription always uses the full recording. An in-flight native decode can still delay the final decode until it returns.
- **Nearby cursor context:** off by default, with a separate default-off switch for cloud sharing. Accessibility requests a range of at most 400 UTF-16 units around the original cursor; it never requests the whole field or a screenshot. Unsupported/secure fields and known password managers yield no context. Context is session-only, excluded from history and logs, and included as a separate untrusted JSON field for spelling disambiguation. Missing context never blocks dictation. No accuracy gain is assumed for a particular model.

Automatic delivery is bound to the captured app, field, and available selection. A changed target preserves the result in History instead of redirecting it. History says “Paste sent” because posting Cmd+V does not prove that the editor accepted the text; delivery is never automatically retried.

## Validation

Run `scripts/check-personalization.sh` for correction boundary, non-chaining, recall, scene precedence, and context sanitation checks. Build the Airtype scheme in Xcode (the Metal compiler component is required by MLX).

Desktop acceptance checks still require microphone and Accessibility permissions:

1. Dictate into TextEdit; switch to another app before completion. Confirm no paste there and copy the result from History.
2. Change the selected range during processing; confirm automatic delivery is refused. Start from a password field; confirm recording is refused.
3. Enable review, edit a word, remember it, and undo. Confirm the next dictation uses only the retained rule. Test Insert and Save only separately.
4. Enable local drafts and speak for over 20 seconds. Confirm only recent speech appears during recording and the final output includes the full recording. Cancel during a draft decode and start another recording; confirm no stale update appears.
5. Use a loopback AI endpoint with context on; inspect its request for the bounded referenceContext field. With a cloud endpoint and cloud sharing off, confirm that field is absent. Repeat after cancelling and on a short recording.

Design references: Arion's input ownership, edit-learning, and contextual rewriting decisions, reviewed from its public repository. This implementation retains Airtype's SwiftUI/MLX architecture.
