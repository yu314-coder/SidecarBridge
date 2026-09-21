# Connection security fixes — September 13, 2026

Local fixes following the connection audit. No upload, review submission, build-number change, Git push, installed-app replacement, or real Keychain reset was performed.

## Findings addressed

- **F1 / live-session revocation:** Forget All invalidates a thread-safe authorization generation before stopping both transports. It stops capture and clipboard monitoring, cancels queued/active transfers, clears connection state and releases pointer buttons. LAN candidates, delayed commands/file callbacks, nearby session callbacks and queued input reject old generations. Pending LAN authentication cannot restore an old session after revocation. Previously sent network data cannot be recalled.
- **F2 / forced repair:** Invalid unauthenticated proofs no longer set a five-minute repair flag. A correct saved credential remains eligible. The current short-lived code remains an explicitly verified repair alternative.
- **F3 / global lockout:** A valid saved-credential proof is checked before the code-guess limiter. Unknown/invalid proofs still face five-per-device and twenty-global failures per minute. Failed-identity entries are pruned and only inserted for accepted rate-budget attempts, bounding retained entries.
- **F4 / failed credential removal:** Keychain enumeration/deletion errors are returned rather than ignored. Forget All persists a fresh credential-account generation before removing old keys, so old undeleted accounts are not consulted on ordinary relaunch. If persistence or deletion reports failure, the listener stays stopped and the UI retains an explicit cleanup warning and retry action. The in-memory regression simulates deletion failure and relaunch; actual OS Keychain errors were not induced. As with other local settings, malicious modification/removal of the app's persisted state is outside this test's guarantees.

## Additional hardening

- LAN handshake/authentication frames are capped at 4096 bytes, including checking the declared length before buffering the body; authenticated video retains its existing larger cap.
- LAN accepts only one initial hello and one outstanding authentication verification per candidate. Already-authenticated candidates cannot re-run pairing.
- Nearby invitations require a bounded context and a fully valid identity. Pre-authentication messages have a small cap; stale MCSession callbacks cannot act on a replacement session.
- No coordinate mapping, cursor alignment, video-quality policy, cryptographic primitive, security protocol version, or existing valid credential was changed during this fix.

## Verification

- macOS build and **140 tests passed**, including six new regression tests against the production pairing logic with injected in-memory credential storage and defaults.
- Regression coverage: valid reconnect after a bad proof; valid reconnect through global guess lockout while code guessing remains blocked; failed deletion plus relaunch; queued-generation invalidation; Keychain status interpretation; oversized pre-authentication header rejection.
- iOS device-target build succeeded using Xcode 26.5. It verifies shared-source compatibility, not physical-device behavior.
- `git diff --check` passed.
- Logs/results: `/Volumes/D/build/SidecarBridge-security-audit-20260913/fixed-final-tests.log`, `fixed-final-tests.xcresult`, and `fixed-ipad.log`.

Before distribution, test Forget All during live LAN and nearby streaming/input/file transfer on physical devices, verify no old-session callbacks recover access, then scan a fresh code and confirm normal reconnection. End-to-end physical revocation was not exercised here.

## Separate architectural recommendations

The audit's broader recommendations are not claimed completed: a reviewed PAKE/high-entropy QR protocol upgrade, consolidation of legacy Keychain migration, and removal/encryption of the explicitly separate VNC option require further work. The companion stream retains its existing authenticated encryption; legacy VNC must not be represented as equally protected. These fixes address the four reported state-management findings without silently changing the wire protocol or forgetting existing valid users.
