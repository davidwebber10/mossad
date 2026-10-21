#!/usr/bin/env bash
# Copy the AssemblyAI and Anthropic keys from Doppler into Mossad's Keychain items.
set -euo pipefail
doppler run --project dispatch --config prd -- /Applications/Mossad.app/Contents/MacOS/Mossad --import-keys
