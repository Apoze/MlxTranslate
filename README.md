# MlxTranslate

Pipeline local de sous-titrage vidéo japonais, 100 % hors ligne (MLX sur
Metal). Aucun serveur HTTP : un seul exécutable, appelé en CLI.

Deux modes :
- **Offline** : transcription horodatée + traduction d'un fichier vidéo.
- **Live** : sous-titres EN temps réel de l'audio d'une application en cours.

## Mode offline (fichier vidéo)

```
vidéo ─▶ ffmpeg (16 kHz mono)
        ─▶ ASR (Voxtral Mini 3B par défaut, forçage langue fort)
        ─▶ Qwen3-ForcedAligner 0,6B (horodatage mot à mot)
        ─▶ post-traitement (cues lisibles)
        ─▶ SpeakerKit (locuteurs, auto ou forcé)
        ─▶ traduction MLX (Qwen3-8B par défaut)
        ─▶ « <nom> (JA).srt » + « <nom> (EN).srt » (préfixes [Locuteur])
```

Commandes :

```
mlxtranslate transcrire <média>            # ASR : texte par fenêtre + chunks.json
mlxtranslate aligner <média>               # horodatage, écrit « (JA).srt »
mlxtranslate parlants <média>              # diarisation, RTTM + compte de locuteurs
mlxtranslate traduire <média>              # traduction, écrit « (EN).srt »
mlxtranslate finale <média>                # chaîne complète
mlxtranslate nettoyer                       # vide runs/ + live-*.srt (garde modèles + glossaire)
mlxtranslate aider                          # aide (aussi : --help)
```

Options :

```
--asr voxtral3b|voxtral|voxtral4b|qwen3asr   backend ASR (défaut : voxtral3b)
       voxtral3b = 3B forçage langue fort (offline, python)
       voxtral   = 4B Realtime sidecar (direct)
       voxtral4b = 4B Realtime natif Swift
       qwen3asr  = Qwen3-ASR 0,6B (test)
--nb N                             nombre de locuteurs forcé (défaut : auto)
--modele qwen3-8b|qwen25-7b|qwen3-14b|gemma-12b|gemma-4b
                                   modèle de traduction (défaut : qwen3-8b)
--noms 0=Hirow,1=Klin              noms des locuteurs (indice = temps de parole décroissant)
--glossaire <chemin>                glossaire (défaut : ~/.mlxtranslate/glossaire.txt)
--sans-parlants                     finale sans diarisation (pas de noms de locuteurs)
```

## Mode live (temps réel, JA → EN)

Sous-titres anglais en direct de l'audio d'une application (ex. une visio,
un stream). Capture l'audio de l'app via ScreenCaptureKit, segmente par
pauses (endpointing), puis, pour chaque énoncé :

1. **JA** — Voxtral Mini 4B Realtime (sidecar), une session par énoncé.
2. **EN preview** (instantanée, sub-seconde) — traduction sur appareil d'Apple
   (Speech + Translation), affichée synchronément et remplacée en fin d'énoncé.
3. **EN final** (haute qualité) — traducteur MLX local (Qwen3-8B par défaut),
   en streaming ; il remplace la preview et est écrit au SRT.

Nécessite macOS 26.4+ et l'autorisation « Enregistrement de l'écran » pour le
terminal (System Settings → Confidentialité et sécurité → Enregistrement de
l'écran).

```
mlxtranslate live --list                          # lister les applications capturables
mlxtranslate live --app <bundleID|nom> [options]
```

Options live :

```
--sans-preview        pas de preview (traduction finale seule)
--sans-traduction     JA seul (pas de traduction EN finale)
--modele <id>         modèle EN final (défaut : qwen3-8b)
--glossaire <chemin>  glossaire de la traduction EN
--delay 960|1200|2400   latence Voxtral (défaut : 960 ms)
--sortie <fichier>    SRT live (défaut : ~/.mlxtranslate/live-<horodatage>.srt)
--max N               arrêt automatique après N secondes
```

L'endpointing découpe sur une pause (silence 300 ms), avec coupure forcée à
12 s par énoncé ; la session de capture est réinitialisée toutes les 12 min.

## Origine des runtimes

Les runtimes de `Sources/MlxTranslate/Runtime` sont issus du dépôt
**whisperASR** (commit `3a76d8f`, même auteur) :

- `HighQualityForcedAlignerRuntime` — Qwen3-ForcedAligner 0,6B-4bit via
  mlx-audio-swift (fenêtres 20 s, horodatage caractère par caractère,
  rejeu/repli de contenu).
- `HighQualitySpeakerKitRuntime` — SpeakerKit (WhisperKit 1,1.0,
  Pyannote v4 community-1 CoreML), politique de nombre de locuteurs
  automatique ou forcée.
- `LocalMLXTranslator` — traduction locale mlx-swift-lm (Gemma Translate
  12/4 B, Qwen2.5-7B, Qwen3-8B/14B), prompt gelé, contrôle de cohérence.
  Sert aussi le mode live (`translateLive`, un énoncé à la fois).
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
  live-<horodatage>.srt  SRT du mode live (par défaut)
```

Les SRT offline sont écrits **côte à côte de la vidéo** :
`<nom> (JA).srt` et `<nom> (EN).srt`.

## Codes de sortie (scripts)

`0` succès · `2` média · `3` transcrire · `4` aligner · `5` parlants · `6` traduire · `7` TCC/capture (live).

## Dépannage

- **TCC (live)** — le mode live exige l'accord « Enregistrement de l'écran » sur
  le **nœud** qui lance le CLI (Terminal / DSH). Si le chemin du binaire change,
  réaccordez. Voir `docs/tcc.md`.
- **Sidecar Voxtral (live)** — le sidecar Python se télécharge à premier run
  dans `~/.mlxtranslate/sidecar`. Un échec de téléchargement laisse le mode live
  en erreur ; relancez après connexion réseau.
- **metallib manquant** — `aligner`/`traduire`/`finale` ont besoin de
  `mlx.metallib` : lancez d'abord `transcrire` (le télécharge), ou `nettoyer`
  puis re-téléchargez.
- **Memory (live)** — le mode live est stable : pic de ~190 MB au chargement du
  modèle, puis ~80-90 MB ; pas de fuite sur 10 min.

## Construction

```
swift build          # produit .build/debug/mlxtranslate
swift run mlxtranslate aider
```

MacBook avec Apple Silicon, macOS 15+ (offline) / macOS 26.4+ (live),
toolchain Swift 6.3.
