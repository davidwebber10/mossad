# Mossad

Mossad is a personal macOS menu bar app. It records Zoom, Google Meet, and Microsoft Teams calls
automatically, transcribes them after the call, identifies speakers by voice, and writes a Markdown
note for each meeting to `~/Mossad/Meetings`.

## Recording consent: read this first

Mossad records calls automatically and does not announce itself to the other people on the call.
You are responsible for using it lawfully.

- **Consent laws differ.** Some US states and many countries require the consent of **every**
  person on a call before it is recorded (for example California, Florida, Illinois, Maryland,
  Massachusetts, Pennsylvania, and Washington, and much of the EU under the GDPR). Other places
  require only one party's consent. On a call, the strictest law of any participant's location can apply.
- **Tell people.** Tell the other participants that you record and transcribe the call, or get
  their consent, before you rely on Mossad. A line in your calendar invitations or a statement at
  the start of the call is a simple way to do this.
- **Employer and customer rules.** Your company's policies and your contracts with customers or
  partners can forbid recording, even where the law permits it.
- **Voice data.** Mossad stores voice fingerprints (voice embeddings) of the people it hears.
  Some laws treat voiceprints as biometric data with extra rules (for example the Illinois
  Biometric Information Privacy Act). Delete a person's voice in **Voices** if you do not have
  a right to keep it.
- **Third-party services.** Audio is sent to AssemblyAI for transcription, and transcripts are
  sent to Anthropic for summaries.
- **Skip a call.** Use **Skip this call** in the menu to stop a recording and delete it.

This notice is not legal advice. If you are not sure, ask a lawyer.

## Build

```sh
scripts/build.sh          # builds, installs to /Applications, and opens Mossad
scripts/import-keys.sh    # imports the AssemblyAI and Anthropic keys from Doppler into the Keychain
```

Tests: `cd Packages/MossadCore && swift test`.

Then open **Settings** from the menu bar icon and turn every permission row green.
