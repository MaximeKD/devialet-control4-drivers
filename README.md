# Driver Devialet IP Control pour Control4 — Squelette

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
- **Découverte** → mDNS `_devialet-http._tcp` (TXT : `manufacturer=Devialet`,
  `ipControlVersion=1`, `path=/ipcontrol/v1`, `port`, `serialNumber`, `model`).
  À terme, exposer en **SDDP** pour l'auto-découverte côté intégrateur.

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

- [ ] Remplacer le proxy `media_service` par la déclaration exacte du **Media
      Service Proxy** (dossier `media_service_proxy` du SDK) et implémenter ses
      commandes (navigation de sources, sélection de service, métadonnées, coverArt).
- [ ] Mapper volume/mute/play/pause vers le proxy et le **slider de volume OS3**.
- [ ] Valider les chemins `.../current/...` sur le matériel : vérifier si le
      stéréo apparaît comme **1 device** ou **1 system à 2 devices**.
- [ ] Reconnexion WebSocket robuste (redémarrage / changement d'IP de l'enceinte).
- [ ] Icônes aux normes (Icon Templates).
- [ ] Aucune API dépréciée (pas de `io.popen`).
- [ ] Passer le Driver Validator (LuaJIT) et tester la mémoire (Table Logger).

## Références

- SDK DriverWorks : https://github.com/snap-one/docs-driverworks
- Libs communes : https://github.com/snap-one/drivers-common-public
- Doc API : *Devialet IP Control – Revision 2, April 2026*
