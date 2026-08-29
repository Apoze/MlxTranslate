# MlxTranslate

Pipeline local de sous-titrage vidéo japonais, 100 % hors ligne (MLX sur
Metal). Aucun serveur HTTP : un seul exécutable, appelé en CLI.

```
vidéo ─▶ ffmpeg (16 kHz mono)
        ─▶ ASR (Voxtral 4B Realtime par défaut)
        ─▶ Qwen3-ForcedAligner 0,6B (horodatage mot à mot)
        ─▶ post-traitement (cues lisibles)
        ─▶ SpeakerKit (locuteurs, auto ou forcé)
        ─▶ traduction MLX (Qwen2.5-7B par défaut)
        ─▶ « <nom> (JA).srt » + « <nom> (EN).srt » (préfixes [Locuteur])
```

## Commandes

```
mlxtranslate transcrire <média>            # ASR : texte par fenêtre + chunks.json
mlxtranslate aligner <média>               # horodatage, écrit « (JA).srt »
mlxtranslate parlants <média>              # diarisation, RTTM + compte de locuteurs
mlxtranslate traduire <média>              # traduction, écrit « (EN).srt »
mlxtranslate finale <média>                # chaîne complète
mlxtranslate aider
```

Options :

```
--asr voxtral|voxtral4b|qwen3asr   backend ASR (défaut : voxtral, sidecar audité)
--nb N                             nombre de locuteurs forcé (défaut : auto)
--modele qwen25-7b|qwen3-8b|qwen3-14b|gemma-12b|gemma-4b
--noms 0=Hirow,1=Klin              noms des locuteurs (indice = temps de parole décroissant)
--glossaire <chemin>                glossaire (défaut : ~/.mlxtranslate/glossaire.txt)
```

## Origine des runtimes

Les quatre runtimes de `Sources/MlxTranslate/Runtime` sont issus du dépôt
**whisperASR** (commit `3a76d8f`, même auteur) :

- `HighQualityForcedAlignerRuntime` — Qwen3-ForcedAligner 0,6B-4bit via
  mlx-audio-swift (fenêtres 20 s, horodatage caractère par caractère,
  rejeu/repli de contenu).
- `HighQualitySpeakerKitRuntime` — SpeakerKit (WhisperKit 1,1.0,
  Pyannote v4 community-1 CoreML), politique de nombre de locuteurs
  automatique ou forcée.
- `LocalMLXTranslator` — traduction locale mlx-swift-lm (Gemma Translate
  12/4 B, Qwen2.5-7B, Qwen3-8B/14B), prompt gelé, contrôle de cohérence.
- `VoxtralHelperRuntime` — Voxtral Mini 4B Realtime via sidecar Python
  géré par uv (artefact épinglé par SHA-256, protocole WebSocket).

Dépendances pinnées comme dans whisperASR : mlx-swift 0.31.6,
mlx-swift-lm 3.31.4, mlx-audio-swift 0.1.3, WhisperKit 1.1.0,
swift-huggingface 0.9.0, swift-transformers 1.3.3.

## Arborescence d'exécution

```
~/.mlxtranslate/
  runs/<horodatage>/     audio.wav, chunks.json, parlants.rttm
  speakerkit/            modèles SpeakerKit (téléchargés au besoin)
  sidecar/               runtime Python Voxtral (uv, venv, modèles)
  glossaire.txt          glossaire de traduction
```

Les SRT sont écrits **côte à côte de la vidéo** :
`<nom> (JA).srt` et `<nom> (EN).srt`.

## Construction

```
swift build          # produit .build/debug/mlxtranslate
swift run mlxtranslate aider
```

MacBook avec Apple Silicon, macOS 15+, toolchain Swift 6.3.
