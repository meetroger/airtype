# Automatic learning after insertion

Settings → AI → **Learn corrections made after insertion** is enabled by default. It is independent of review mode and AI enhancement. Existing manually authored correction pairs take priority.

After an ordinary dictation is pasted, Airtype watches only that captured editor. Fix a word there as you normally would. Learning settles when you leave the field, clear/send its contents, start the next recording, stop editing for 15 seconds, or reach the 60-second observation limit. For example, correcting `我想看看阿里昂项目的设置` to `我想看看Arion项目的设置` teaches `阿里昂 → Arion`. A subsequent transcription applies this mapping locally before optional AI processing; relevant learned spellings also join the normal vocabulary hints.

The inactive **Learned your correction** notice offers **Undo** for 10 seconds without taking keyboard focus. **Undo last learned correction** also remains in the menu bar menu and Settings → AI after the notice closes and across app restarts. Undo reverts the entire most recently learned batch and restores any mapping it replaced. It changes future recognition corrections, not the document you edited. Individual learned entries can be removed, or all automatic entries cleared, in Settings. These actions never rewrite your manually authored correction pairs.

## Attribution and limits

- A successful system paste alone is insufficient: the tracker must observe the expected inserted text at its captured range within two seconds. Failed/uncertain delivery, history insertion, Save only, Copy & close and translation do not start automatic learning.
- Native Accessibility text areas/fields must expose selected ranges, character counts and bounded range reads. Unsupported editors simply skip learning. Password fields, protected content, secure keyboard input and known password-manager applications are excluded. The tracker never switches to a different editor.
- Up to 2,000 UTF-16 units of inserted text, with at most 128 units of surrounding context on each side, establish the baseline. Later readings stay at the same anchor, are capped at 4,096 units, and are made on a background task with per-AX-call timeouts. No full-field value or screenshot is requested. A missing, changed or oversized anchor is discarded.
- Word segmentation and a bounded diff extract up to three short replacements, each side 2–16 characters. Number/time changes, grammatical homophones, punctuation-only edits, pure additions/deletions and large rewrites do not create replacement pairs. A changed surrounding anchor or three failed reads abandons the observation. Some legitimate edits, including very short whole-utterance rewrites, are intentionally skipped.
- Readings occur roughly every 400 ms. Edits made and submitted between readings may be missed. A simple text diff cannot always distinguish a spelling correction from an intentional word substitution; review the visible learned pair and use Undo when needed.
- Extraction and storage stay on this Mac. Excerpts are session-only and are not added to logs, History or model requests. Only learned word pairs persist in the app's local preferences, with a maximum of 200 entries. The normal transcript and matching vocabulary hints still follow the configured AI provider's existing processing behavior. Turning learning off stops observation; already learned mappings remain usable until removed or undone.

## Validation

`scripts/check-personalization.sh` includes extraction, anchoring, idle/focus/clear/max settlement, baseline verification, failure abandonment, manual-rule priority, persistence and undo tests.

`sh scripts/check-edit-learning-native.sh` exercises the production paste service, AX reader, tracking loop and store against temporary native NSTextView editors, for English and Chinese corrections and disabled learning. It uses an isolated preferences suite and does not edit the user's vocabulary. A test host without Accessibility permission reports a skip without requesting new permission.

Manual acceptance: dictate into TextEdit, correct a product name, then switch to another field. Confirm the notice appears, the next dictation uses the learned spelling, and Undo removes the learned mapping. Repeat with review enabled. Verify that Save only, translation and unsupported fields do not learn; that ordinary continued typing is not stored as a correction; and that the notice does not steal focus.

## Arion reference

Reviewed [application/learning.go](https://github.com/AstraFoundry/Arion/blob/3b1acc1/packages/core/application/learning.go), [domain/learning.go](https://github.com/AstraFoundry/Arion/blob/3b1acc1/packages/core/domain/learning.go), and [bootstrap/learning.go](https://github.com/AstraFoundry/Arion/blob/3b1acc1/apps/desktop/bootstrap/learning.go). Airtype follows its baseline/settlement/word-correction approach, using Swift, Apple's local word tokenizer, a fixed insertion anchor and a separate local store with persistent batch undo.
