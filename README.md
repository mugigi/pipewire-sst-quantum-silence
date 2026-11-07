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

## Test décisif : le driver noyau est innocent

En écrivant **directement dans `hw:1`** via ALSA mmap, sans PipeWire, avec la même
période (1008) et le même buffer (34272) :

| pré-remplissage avant `snd_pcm_start` | commit | débit matériel | xrun |
|---|---|---|---|
| tampon plein (34272) | 512 | 48 055 fps | 0 |
| tampon plein (34272) | 1008 | 48 001 fps | 0 |
| tampon plein (34272) | 1024 | 48 000 fps | 0 |
| 512 frames | 512 | 0 fps (figé à 2016) | XRUN |

En balayant le pré-remplissage à commit constant de 512 frames :

| pré-remplissage | résultat |
|---|---|
| 512, 1008, 1512 frames | XRUN, `hw_ptr` figé |
| **2016 frames et plus** | ~48 000 fps, 0 xrun |

Conclusion : le couple driver SST + firmware **accepte parfaitement des commits de
512 frames**. Le blocage n'est pas une limite matérielle.

Il vient du **démarrage** : le firmware exige **au moins deux périodes (2016 frames)**
en file avant de démarrer. En dessous, il part en underrun et ne se rétablit pas. Or
PipeWire amorce `threshold` frames puis écrit un premier buffer de `threshold` frames :
à quantum ≤ 1008 il n'y a donc jamais plus de 2016 frames au démarrage (et parfois
moins), d'où le blocage. Dès que `2 × quantum > 2016` (quantum > 1008, donc ≥ 1024 en
pratique), tout fonctionne.

Le correctif est donc côté **PipeWire** (marge de démarrage / `headroom`), pas dans le
driver noyau.

## Correctif proposé et validé

Le périphérique expose `SNDRV_PCM_INFO_BLOCK_TRANSFER` (`snd_pcm_hw_params_is_block_transfer()
== 1`), c'est-à-dire qu'il ne consomme les données que par blocs entiers d'une période.
C'est exactement la classe de matériel concernée.

Le patch `0001-alsa-pcm-keep-two-periods-queued-for-block-transfer.patch` :

1. mémorise `is_block_transfer` à l'ouverture des hw params ;
2. dans `recalc_headroom()`, pour un playback block-transfer dont le quantum n'excède pas
   la période, impose `headroom = 2 × période − quantum`, soit **2 périodes en file** ;
3. rappelle `recalc_headroom()` quand le quantum change, pour que la marge suive.

Résultat mesuré sur la machine (PipeWire 1.6.10 compilé avec le patch, `paplay`, 10 s) :

| quantum | période | état | débit matériel | xrun |
|---|---|---|---|---|
| 128  | 1008 | RUNNING | 48 182 fps | 0 |
| 512  | 1008 | RUNNING | 48 182 fps | 0 |
| 1008 | 1008 | RUNNING | 48 081 fps | 0 |
| 1024 | 1008 | RUNNING | 48 384 fps | 0 |
| 2048 | 1008 | RUNNING | 48 384 fps | 0 |

Coût : ~2 périodes de latence supplémentaire (42 ms à 48 kHz) **uniquement** pour les
périphériques block-transfer et **uniquement** quand le quantum ≤ période. Les autres
périphériques et les quantums supérieurs ne changent pas.

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

Test automatisé utilisé pour le tableau ci-dessus : `hwptr-quantum-test.sh`
(échantillonne `hw_ptr` dans `/proc/asound`).

## Appliquer et compiler le patch

```bash
tar xf pipewire-1.6.10.tar.gz
cd pipewire-1.6.10
patch -p1 < ../0001-alsa-pcm-keep-two-periods-queued-for-block-transfer.patch
meson setup build -Dauto_features=disabled -Dsession-managers=[] \
      -Dspa-plugins=enabled -Dalsa=enabled -Dudev=enabled \
      -Dtests=disabled -Dexamples=disabled -Ddocs=disabled -Dman=disabled
ninja -C build spa/plugins/alsa/libspa-alsa.so
```

Puis tester le plugin dans une instance PipeWire isolée (services utilisateur
arrêtés/restaurés automatiquement) :

```bash
./test-isolated.sh build/spa/plugins/alsa 128 512 1008 1024
```

## Contournement historique (optionnel)

`~/.config/pipewire/pipewire.conf.d/99-min-quantum.conf` :

```ini
context.properties = {
    default.clock.quantum     = 1024
    default.clock.min-quantum = 1024
}
```

Puis `systemctl --user restart pipewire wireplumber pipewire-pulse`.

Effet de bord : latence minimale ~10 ms → ~21 ms.

## Pistes upstream

Le correctif ci-dessus est implémenté, compilé et testé. Pour l'upstream, deux points
méritent discussion :

1. **PipeWire** : la condition `is_block_transfer && quantum <= période` est générique
   (elle ne nomme aucune carte) et correspond à la sémantique ALSA de
   `SNDRV_PCM_INFO_BLOCK_TRANSFER`. C'est la piste retenue.
2. **Noyau** (mineur, séparé) : `sst_media_prepare()` fait
   `substream->runtime->hw.info = SNDRV_PCM_INFO_BLOCK_TRANSFER;` (affectation, pas
   `|=`), ce qui écrase les autres bits de `hw.info`. Sans lien démontré avec ce bug,
   mais à signaler séparément.

## Fichiers

- `0001-alsa-pcm-keep-two-periods-queued-for-block-transfer.patch` — le correctif
  PipeWire (`patch -p1` dans une source 1.6.10).
- `hwptr-quantum-test.sh` — reproducer autonome (aucune écoute nécessaire : il lit
  `hw_ptr` et affiche le débit réel du DSP).
- `alsa_direct.py` — reproducer direct-ALSA qui a exonéré le driver noyau.
- `test-isolated.sh` — banc de test isolé (instance PipeWire privée + mesure `hw_ptr`).
- `upstream-report.md` — rapport prêt à coller dans une issue GitLab PipeWire.
- `99-min-quantum.conf` — le contournement historique (plus nécessaire avec le patch).

```bash
./hwptr-quantum-test.sh 512 1024
# quantum=512   hw_ptr figé   → muet
# quantum=1024  ~48000 fps    → audible
```
