# Driver Devialet IP Control pour Control4 — Squelette (v0.4)

Point de départ pour un driver DriverWorks pilotant une enceinte Devialet
auto-streaming via l'API **IP Control v1** (HTTP + WebSocket).

## Architecture retenue

- **1 instance de driver = 1 enceinte.** Le pairing stéréo étant géré en interne
  par l'appareil, il n'est pas modélisé côté Control4.
- **Commandes sortantes** (play, volume, source…) → HTTP via `C4:url` sur
  `http://<ip>:80/ipcontrol/v1/...`. Pas d'authentification requise.
- **Feedback temps réel** → WebSocket sur `/ipcontrol/v1/notifications`, avec le
  modèle d'abonnement Devialet (`subscriptionManagement` / `notification`).
  Une notification est envoyée immédiatement après abonnement et à chaque
  changement (≤ 10/s par endpoint) → pas de polling.
- **Découverte** → **saisie d'IP manuelle** (propriété `Device IP Address`).
  En stéréo, pointer de préférence sur le **system leader** (le driver le
  détecte via l'API et le signale dans `Operational Status` sinon).
  mDNS/SDDP écartés pour l'instant (DriverWorks n'a pas de module mDNS natif ;
  le SDDP dépendrait d'un firmware Devialet à confirmer).

## Fichiers

| Fichier      | Rôle                                                        |
|--------------|-------------------------------------------------------------|
| `driver.xml` | Définition : proxy, propriétés, connexions, commandes.      |
| `driver.lua` | Logique : HTTP, WebSocket, abonnements, mapping proxy.       |

## Dépendances à embarquer dans le `.c4z`

Copier depuis https://github.com/snap-one/drivers-common-public sous
`drivers-common-public/` dans le `.c4z` :

- `module/websocket.lua` (client WebSocket officiel)
- `module/metrics.lua`
- `global/handlers.lua`
- `global/timer.lua`
- une lib JSON (ex. `global/json.lua`)

## Construire le `.c4z`

Un `.c4z` est une archive ZIP renommée :

```bash
cd devialet_driver
zip -r ../Devialet_IP_Control.c4z . -x "*.md"
```

Puis charger dans ComposerPro, ou valider en ligne de commande avec le
**Driver Validator** du SDK (compatibilité LuaJIT).

## Checklist avant soumission (Product Partner)

Points marqués `-- TODO CERTIF` dans le code, à traiter :

- [x] MSP câblé (transport PLAY/PAUSE/STOP/SKIP + UPDATE_MEDIA_INFO + ProgressChanged
      + DashboardChanged), UI XML Now Playing/Dashboard (d'après MSP By Numbers).
- [ ] MSP navigation/browse des services (List + DATA_RECEIVED) et file d'attente (queue).
- [x] Mapping métadonnées + progression confirmé (metadata.*, coverArtUrl, duration ms, playingState, muteState, availableOperations, playback/position ms).
- [ ] Mapper volume/mute/play/pause vers le proxy et le **slider de volume OS3**.
- [x] Topologie stéréo validée : 1 system = 2 devices (FrontLeft/FrontRight).
- [x] Résolution du system leader + routage de toutes les commandes vers lui.
- [x] Découverte par IP manuelle (mDNS/SDDP écartés).
- [x] Infrastructure de debug (Debug Mode / Level / Subsystems) + auto-off
- [x] Proprietes de statut (Operational Status / Internal State)
- [ ] Reconnexion WebSocket robuste (redémarrage / changement d'IP de l'enceinte).
- [ ] Icônes aux normes (Icon Templates).
- [ ] Aucune API dépréciée (pas de `io.popen`).
- [ ] Passer le Driver Validator (LuaJIT) et tester la mémoire (Table Logger).

## Références

- SDK DriverWorks : https://github.com/snap-one/docs-driverworks
- Libs communes : https://github.com/snap-one/drivers-common-public
- Doc API : *Devialet IP Control – Revision 2, April 2026*
