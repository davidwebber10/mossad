#!/usr/bin/env bash
# Copy the AssemblyAI and Anthropic keys from Doppler into Mossad's Keychain items.
# Mossad reads ASSEMBLYAI_API_KEY (or ASSEMBLYAI) and ANTHROPIC_API_KEY (or ANTHROPIC_API_KEY_<NAME>).
# Set MOSSAD_DOPPLER_PROJECT and MOSSAD_DOPPLER_CONFIG to use your own Doppler project.
set -euo pipefail
doppler run --project "${MOSSAD_DOPPLER_PROJECT:-dispatch}" --config "${MOSSAD_DOPPLER_CONFIG:-prd}" \
  -- /Applications/Mossad.app/Contents/MacOS/Mossad --import-keys
