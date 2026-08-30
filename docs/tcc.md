# Permissions TCC par mode

`mlxtranslate` a deux modes, qui n'exigent pas les mêmes droits système.

## Mode offline (`transcrire`, `aligner`, `parlants`, `traduire`, `finale`, `nettoyer`)

Aucune permission TCC n'est nécessaire : le CLI lit un fichier média et écrit
dans `~/.mlxtranslate`. Le premier lancement télécharge `mlx.metallib` dans le
cache, les suivants le réutilisent.

## Mode live (`live`)

Le mode live capture l'audio d'une application via le Screen Capture Kit, ce
qui exige **le droit d'accès à l'audio système** (ou au moniteur audio) accordé
à l'app qui lance le CLI.

- **Accord TCC sur le nœud** : l'accord vit dans la base TCC du nœud (Terminal,
  iTerm, ou le DSH node). Si le chemin du binaire du nœud change, l'accord est
  perdu et doit être **réaccordé** (système > Préférences > Confidentialité >
  Audio (ou Moniteur audio)).
- **Symptôme** : `live` échoue avec un code de sortie **7** (TCC/capture) ou
  l'erreur `tccDenied` / `noDisplay`.
- **Réaccord** : relancez le CLI depuis le même nœud ; macOS affiche la boîte
  de dialogue, cochez « Authoriser ».

## Codes de sortie (scripts)

`0` succès · `2` média · `3` transcrire · `4` aligner · `5` parlants · `6` traduire · `7` TCC/capture.
