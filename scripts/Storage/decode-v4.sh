#!/bin/bash
# Decodifica o script v4.1 corrigido (memory fix + parser fix)
# Execute: bash decode-v4.sh
cd "$(dirname "$0")"
base64 -D -i v4_encoded.b64 -o Remove-ExpiredImmutableBlobs.ps1
echo "✓ Decodificado: Remove-ExpiredImmutableBlobs.ps1"
echo "  Versão: 4.1.0 (streaming fix + parser fix)"
ls -la Remove-ExpiredImmutableBlobs.ps1
