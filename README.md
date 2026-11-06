# Silence audio quand le quantum PipeWire passe sous la période ALSA (SST + ES8316)

## Résumé

Sur cette machine (Thomson NEO14, carte `bytcht-es8316`), le son disparaît **pour toutes
les applications** dès que le quantum du graphe PipeWire descend sous la période ALSA du
périphérique (1008 frames). Ce n'est pas un problème de codec, ni de Chromium, ni du site :
`paplay` est muet lui aussi dans ces conditions.

Le seuil mesuré est net :

| quantum forcé | période ALSA | `hw_ptr` sur 2 s | état | son |
|---|---|---|---|---|
| 512  | 1008 | ~0 (remise à zéro) | XRUN | muet |
| 960  | 1008 | +1008 frames (1 seule période puis blocage) | RUNNING | muet |
| 1008 | 1008 | 0 | RUNNING | muet |
| 1024 | 1008 | +96 768 frames (≈48 000 fps) | RUNNING | **audible** |

À quantum 512, `appl_ptr` monte à 1024 (deux commits de 512 frames) puis plus rien, et
`hw_ptr` reste figé : le firmware SST ne consomme plus le buffer. PipeWire, lui, voit un
signal plein niveau dans le moniteur du sink — d'où la barre de volume qui bouge sans
aucun son au haut-parleur.

## Pourquoi 1008 ?

- `spa/plugins/alsa/alsa-pcm.h` : `DEFAULT_PERIOD = 1024`, `DEFAULT_RATE = 48000`.
- `alsa-pcm.c`, `alsa_set_hw_params()` :
  `default_period = flp2(2 * 1024 - 1) = 1024`, puis
  `snd_pcm_hw_params_set_period_size_near(..., 1024, ...)`.
- Le driver `snd_soc_sst_atom_hifi2_platform` impose une période multiple de 48 frames
  (`snd_pcm_hw_constraint_step(PERIOD_SIZE, 48)` dans
  `sound/soc/intel/atom/sst-mfld-platform-pcm.c`).
- 1024 arrondi au multiple de 48 le plus proche → **1008**.

Ensuite, rien n'empêche le quantum du graphe de descendre à 512 (un client qui demande
une latence plus faible), alors que la période ALSA reste à 1008 négociée à l'ouverture.
Le sink écrit alors ~512 frames par cycle dans un tampon dont le pointeur matériel
n'avance que par périodes entières : il se bloque.

## Reproduction

```bash
# 1. vérifier la période ALSA
cat /proc/asound/card1/pcm0p/sub0/hw_params | grep -E 'period_size|buffer_size'
#   period_size: 1008
#   buffer_size: 34272

# 2. forcer un quantum sous la période
pw-metadata -n settings 0 clock.force-quantum 512

# 3. jouer n'importe quoi (aucun son)
paplay /usr/share/sounds/.../tone.wav

# 4. observer le pointeur matériel figé
cat /proc/asound/card1/pcm0p/sub0/status

# 5. revenir à 1024 : le son revient
pw-metadata -n settings 0 clock.force-quantum 1024
```

Test automatisé utilisé pour le tableau ci-dessus :
`/tmp/opencode/hwptr_test.sh` (échantillonne `hw_ptr` dans `/proc/asound`).

## Contournement appliqué (permanent)

`~/.config/pipewire/pipewire.conf.d/99-min-quantum.conf` :

```ini
context.properties = {
    default.clock.quantum     = 1024
    default.clock.min-quantum = 1024
}
```

Puis `systemctl --user restart pipewire wireplumber pipewire-pulse`.

Effet de bord : latence minimale ~10 ms → ~21 ms.

## Pistes pour un vrai correctif

1. **PipeWire** : quand le nœud ALSA est le driver du graphe, ne pas laisser
   `clock.target_duration` descendre sous la période négociée (`state->period_frames`),
   ou renéogocier `period_size` quand le quantum diminue. C'est le comportement qui
   serait correct pour tout périphérique dont le pointeur matériel avance par périodes
   (`SNDRV_PCM_INFO_BLOCK_TRANSFER`).
2. **Noyau** : `sst_media_prepare()` fait
   `substream->runtime->hw.info = SNDRV_PCM_INFO_BLOCK_TRANSFER;` (affectation, pas
   `|=`) : il écrase tous les autres bits de `hw.info`. À vérifier séparément.
3. **Driver SST** : comprendre pourquoi `hw_ptr` n'avance pas quand les commits sont
   plus petits que la période (le firmware semble exiger des fragments entiers).

Ce dépôt ne contient volontairement pas de patch PipeWire : un correctif non compilé ni
testé serait rejeté. Il documente le diagnostic, fournit un reproducer et le
contournement, pour servir de base à une issue upstream.

## Fichiers

- `hwptr-quantum-test.sh` — reproducer autonome (aucune écoute nécessaire : il lit
  `hw_ptr` et affiche le débit réel du DSP).
- `upstream-report.md` — rapport prêt à coller dans une issue GitLab PipeWire.
- `99-min-quantum.conf` — le contournement.

```bash
./hwptr-quantum-test.sh 512 1024
# quantum=512   hw_ptr figé   → muet
# quantum=1024  ~48000 fps    → audible
```
