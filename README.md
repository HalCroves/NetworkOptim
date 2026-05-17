# CS2 Network Optimizer + WireGuard VPN

Optimiseur réseau pour CS2 (et autres jeux) sous Windows, conçu pour une connexion 4G/tethering instable.  
Comprend un tunnel WireGuard vers un VPS Ionos (Paris) pour stabiliser le routage vers les serveurs Valve.

![Screenshot of a comment on a GitHub issue showing an image, added in the Markdown, of an Octocat smiling and raising a tentacle.](https://media.discordapp.net/attachments/1500120485290315877/1505465053485465670/image.png?ex=6a0ab916&is=6a096796&hm=1f7f9b580119494cdedba145c78ee02ff09e875967676cf83acbaf5be06ed6cc&)

---

## Sommaire

- [Ce que ça fait](#ce-que-ça-fait)
- [Fichiers du projet](#fichiers-du-projet)
- [Prérequis](#prérequis)
- [Installation WireGuard (VPS + Windows)](#installation-wireguard-vps--windows)
- [Anti-bufferbloat VPS (fq_codel + BBR)](#anti-bufferbloat-vps-fq_codel--bbr)
- [Configuration CS2 (autoexec.cfg)](#configuration-cs2-autoexeccfg)
- [Tethering iPhone USB](#tethering-iphone-usb)
- [Utilisation](#utilisation)
- [Vérifier que CS2 passe par le tunnel](#vérifier-que-cs2-passe-par-le-tunnel)
- [Configuration WireGuard actuelle](#configuration-wireguard-actuelle)
- [Désinstallation complète du tunnel](#désinstallation-complète-du-tunnel)
- [Dépannage](#dépannage)

---

## Ce que ça fait

### Tier 1 — Optimisations Windows (CS2-HighPriority.ps1)

Exécuté automatiquement au lancement du jeu via `CS2-Launcher.ps1`.

| Étape | Action |
|-------|--------|
| **[1/8] Kill statique** | Supprime les processus connus consommateurs réseau (OneDrive, Xbox, Teams, iCloud, SteelSeries GG…) |
| **[2/8] Kill dynamique** | Détecte les processus avec ≥ 3 connexions TCP actives et les tue, les ajoute à `process-blacklist.json` |
| **[3/8] Services** | Arrête/désactive BITS, Windows Update, WSearch, DiagTrack, Delivery Optimization, Xbox services, Apple Bonjour… |
| **[4/8] TCP stack** | `AutoTuningLevel=Normal`, Nagle désactivé (`TcpAckFrequency=1`, `TCPNoDelay=1`), ECN activé, Timestamps désactivés |
| **[5/8] Registre système** | `SystemResponsiveness=0` (MMCSS, CPU max pour le jeu), `NetworkThrottlingIndex=0xFFFFFFFF` (pas de throttle réseau) |
| **[5/8] NIC** | Interrupt Moderation désactivé, Flow Control désactivé, Power Management désactivé sur la carte réseau active |
| **[5/8] Exclusions Defender** | Dossier Steam + `steam.exe`, `steamwebhelper.exe`, `cs2.exe` exclus du scan temps réel |
| **[6/8] MTU auto** | Dichotomie binaire pour trouver le MTU optimal (1200–1452), appliqué à l'interface physique |
| **[7/8] QoS DSCP 46** | Expedited Forwarding sur `cs2.exe` + `wireguard.exe`, background throttlé à 1 Mbps (libère l'uplink 4G) |
| **[8/8] Lancement** | Lance CS2 via Steam URI, attend le démarrage, applique priorité High + affinité CPU (exclut core 0/IRQ) |

**Surveillance continue** : tant que CS2 est ouvert, le script re-kill les processus qui reviennent (toutes les 20s), mesure la latence (ping 1.1.1.1 + VPS WireGuard), et loggue les spikes > 150ms **sur le VPS uniquement** dans `latency-spikes.log`. Un spike sur 1.1.1.1 sans spike VPS = la 4G est instable mais CS2 n'est pas impacté (le tunnel absorbe).

**Restauration automatique** : à la fermeture de CS2, tous les paramètres modifiés (DNS, AutoTuning, NIC, QoS, services) sont restaurés depuis `wifi-gaming-backup.json`.

### Tier 2 — Tunnel WireGuard (split tunnel)

Tunnel VPN entre le PC Windows et un VPS Ionos à Paris.  
**Split tunnel** : seul le trafic vers les serveurs Valve est routé via le VPS. Le reste (Discord, navigateur, etc.) passe directement par la 4G.

**Pourquoi ?**  
La 4G via tethering iPhone emprunte des routeurs partagés, surchargés aux heures de pointe → latence variable, jitter. Le VPS Ionos Paris dispose d'une connexion datacenter directe vers les serveurs Valve, plus stable et prévisible.

```
Sans tunnel :  PC → 4G → routeurs opérateur (variables) → Valve
Avec tunnel :  PC → 4G → VPS Ionos (stable, fq_codel+BBR) → Valve
```

Le tronçon instable (4G → VPS) est court. La partie VPS → Valve est datacenter-to-datacenter.

**Ranges Valve routés via le tunnel :**
```
155.133.224.0/19  — bloc principal Valve (inclut tous les /24 Valve de 155.133.x.x)
162.254.192.0/21  — relays EU (serveurs de matchmaking européens)
185.25.182.0/23   — infrastructure EU Valve
192.69.96.0/22    — Valve US/CDN
208.64.200.0/22   — serveurs de jeu Valve
208.78.164.0/22   — infra Valve additionnelle
205.196.6.0/24    — Valve
146.66.152.0/24   — Valve US
146.66.155.0/24   — Valve US
209.197.3.0/24    — Valve
```
*Source : BGP AS32590 (Valve Corporation), mis à jour le 17/05/2026.*

Le service WireGuard (`WireGuardTunnel$CS2-WG`) démarre **automatiquement** au boot Windows.

### Tier 3 — Anti-bufferbloat VPS (fq_codel + BBR)

Même avec le tunnel actif, les pics de latence en jeu (typiquement +30–40 ms pendant les rounds) sont causés par du **bufferbloat** : les bursts UDP de CS2 saturent la file d'attente du lien 4G et des interfaces du VPS, créant un retard de queuing.

| Composant | Configuration | Effet |
|-----------|--------------|-------|
| **fq_codel sur `ens6`** | `tc qdisc replace dev ens6 root fq_codel` | Élimine l'accumulation de paquets sur l'interface physique du VPS |
| **fq_codel sur `wg0`** | `tc qdisc replace dev wg0 root fq_codel` | Idem côté tunnel WireGuard (trafic CS2 décapsulé) |
| **BBR congestion control** | `net.ipv4.tcp_congestion_control=bbr` | Algorithme Google adaptatif, bien plus efficace que Cubic sur 4G variable |
| **Default qdisc** | `net.core.default_qdisc=fq_codel` | Toute nouvelle interface hérite de fq_codel automatiquement |
| **Service `tc-fq-codel`** | systemd unit enabled | fq_codel réappliqué automatiquement après chaque reboot |
| **Buffers UDP** | `rmem_max/wmem_max = 26214400` | WireGuard est UDP pur — buffers par défaut Debian trop petits sous charge |

Installation → voir [Anti-bufferbloat VPS (fq_codel + BBR)](#anti-bufferbloat-vps-fq_codel--bbr).

### Tier 4 — Vérifications pré-lancement (CS2-Launcher.ps1)

Avant chaque lancement, le launcher vérifie automatiquement :
- **Tunnel WireGuard actif** : adapateur détecté + ping 10.66.66.1 réussi
- **Tethering iPhone USB actif** : adaptateur "Apple Mobile Device Ethernet" détecté et `Up`

Si l'une des deux conditions échoue → popup d'avertissement avec option de continuer quand même.

---

## Fichiers du projet

```
NetworkOptim/
├── CS2-HighPriority.ps1       # Optimiseur principal (703 lignes)
├── CS2-Launcher.ps1           # Lanceur UI — dot-source CS2-HighPriority.ps1 dans un Runspace
├── CS2-HighPriority.bat       # Raccourci .bat pour lancer en admin
├── WG-Client-Setup.ps1        # Installation WireGuard côté Windows (à ne lancer qu'une fois)
├── wg-server-setup.sh         # Setup WireGuard côté VPS Debian (à ne lancer qu'une fois)
├── wg-add-peer.sh             # Ajouter le client Windows comme peer sur le VPS
├── Apply-NetworkOptim.ps1     # Application manuelle des optimisations réseau
├── Restore-NetworkOptim.ps1   # Restauration manuelle
├── Monitor-CS2Ping.ps1        # Monitoring latence CS2 en temps réel
├── Fix-iPhoneUSB.ps1          # Fix drivers RNDIS iPhone (tethering USB)
├── Clean-GhostDevices.ps1     # Nettoyage des adaptateurs réseau fantômes
├── process-blacklist.json     # DB persistante des processus à tuer (auto-générée)
├── wifi-gaming-backup.json    # Backup des paramètres avant optimisation (auto-généré)
└── latency-spikes.log         # Log des spikes réseau > 150ms (auto-généré)
```

---

## Prérequis

- **Windows 10/11** avec PowerShell 5.1+
- **Droits administrateur** (tous les scripts s'auto-élèvent)
- **WireGuard for Windows** 1.1+ (installé automatiquement par `WG-Client-Setup.ps1`)
- **VPS Debian 12** avec accès SSH root (pour le côté serveur)
- **winget** recommandé (Windows Package Manager, inclus dans Windows 11)

### Firewall Ionos (ou tout autre hébergeur)

Ajouter une règle entrante **UDP port 51820** dans le panel de gestion réseau du VPS.  
Sans cette règle, les paquets WireGuard sont bloqués avant d'atteindre le serveur.

---

## Installation WireGuard (VPS + Windows)

### Étape 1 — Configurer le VPS (une seule fois)

Se connecter en SSH sur le VPS Debian, puis :

```bash
# Copier wg-server-setup.sh sur le VPS
scp wg-server-setup.sh root@<IP_VPS>:~

# Se connecter et l'exécuter
ssh root@<IP_VPS>
chmod +x wg-server-setup.sh
./wg-server-setup.sh
```

Le script :
- Installe `wireguard-tools`
- Génère une paire de clés serveur
- Crée `/etc/wireguard/wg0.conf` avec NAT et IP forwarding
- Active `wg-quick@wg0` au démarrage
- **Affiche la clé publique serveur** → à noter, elle sera demandée côté Windows

Structure de `/etc/wireguard/wg0.conf` créée :
```ini
[Interface]
Address    = 10.66.66.1/24
ListenPort = 51820
PrivateKey = <clé privée serveur>
PostUp     = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ens6 -j MASQUERADE
PostDown   = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ens6 -j MASQUERADE
```

### Étape 2 — Configurer le client Windows (une seule fois)

Dans un terminal **PowerShell administrateur** :

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\WG-Client-Setup.ps1
```

Le script :
1. Installe WireGuard for Windows via `winget` (ou téléchargement direct en fallback)
2. Génère une paire de clés client
3. **Affiche la clé publique client** → à copier pour l'étape 3
4. Demande l'IP du VPS et la clé publique serveur
5. Crée `C:\ProgramData\WireGuard\CS2-WG.conf` (split tunnel Valve)
6. Installe et démarre le service Windows `WireGuardTunnel$CS2-WG`

> ⚠️ **Ne pas relancer ce script** si le tunnel est déjà configuré : il régénèrerait de nouvelles clés qui ne correspondraient plus au VPS.

### Étape 3 — Ajouter le client comme peer sur le VPS

```bash
# Sur le VPS
chmod +x wg-add-peer.sh
./wg-add-peer.sh <CLÉ_PUBLIQUE_CLIENT>
```

La clé publique client est celle affichée à l'étape 2.

Le script ajoute idempotent-ement le peer dans `wg0.conf` et recharge WireGuard.

### Étape 4 — Vérifier le tunnel

Sur le VPS :
```bash
wg show
# Doit afficher le peer avec "latest handshake: X seconds ago"
```

Sur Windows (terminal admin) :
```powershell
& 'C:\Program Files\WireGuard\wg.exe' show
# Doit afficher "latest handshake" et "transfer: X received, Y sent"

ping 10.66.66.1
# Doit répondre en ~50ms
```

---

## Anti-bufferbloat VPS (fq_codel + BBR)

À appliquer **une fois** sur le VPS après l'installation WireGuard.

```bash
# 1. Appliquer fq_codel immédiatement
tc qdisc replace dev ens6 root fq_codel
tc qdisc replace dev wg0  root fq_codel

# Vérifier (doit afficher "fq_codel" pour chaque interface)
tc qdisc show dev ens6
tc qdisc show dev wg0

# 2. Activer BBR et définir fq_codel comme qdisc par défaut
echo "net.core.default_qdisc = fq_codel" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control = bbr"  >> /etc/sysctl.conf
sysctl -p
sysctl net.ipv4.tcp_congestion_control   # doit répondre "bbr"

# 3. Persister fq_codel au démarrage via un service systemd
cat > /etc/systemd/system/tc-fq-codel.service << 'EOF'
[Unit]
Description=fq_codel qdisc on ens6 + wg0
After=network-online.target wg-quick@wg0.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/tc qdisc replace dev ens6 root fq_codel
ExecStart=/sbin/tc qdisc replace dev wg0  root fq_codel
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tc-fq-codel.service
systemctl status tc-fq-codel.service --no-pager
```

### Buffers UDP pour WireGuard (une fois)

```bash
cat << 'EOF' | sudo tee /etc/sysctl.d/99-wireguard-udp.conf
net.core.rmem_default = 26214400
net.core.wmem_default = 26214400
net.core.rmem_max     = 26214400
net.core.wmem_max     = 26214400
net.core.netdev_max_backlog = 5000
net.core.optmem_max   = 65536
EOF
sudo sysctl --system
# Vérifier :
sysctl net.core.rmem_max   # doit afficher 26214400
```

Sortie attendue du status :
```
● tc-fq-codel.service - fq_codel qdisc on ens6 + wg0
     Active: active (exited) since ...
    Process: ExecStart=/sbin/tc qdisc replace dev ens6 root fq_codel (code=exited, status=0/SUCCESS)
    Process: ExecStart=/sbin/tc qdisc replace dev wg0  root fq_codel (code=exited, status=0/SUCCESS)
```

---

## Configuration CS2 (autoexec.cfg)

Fichier : `<Steam>\steamapps\common\Counter-Strike Global Offensive\game\csgo\cfg\autoexec.cfg`

### Paramètres réseau clés

| CVar | Valeur | Pourquoi |
|------|--------|----------|
| `rate` | `524288` | ~4 Mbps — calibré pour 5-10 Mbps d'upload. À 131072 (1 Mbps) CS2 buffère ses données en interne → micro-jitter artificiel |
| `cl_interp_ratio` | `1` | 15.6 ms d'interpolation sur 64-tick (ratio 2 = 31 ms, trop visible) |
| `cl_interp` | `0` | Calculé automatiquement depuis `cl_interp_ratio` |
| `mm_dedicated_search_maxping` | `120` | Limite la recherche de serveurs à 120 ms max |

> ⚠️ `cl_cmdrate`, `cl_updaterate`, `net_maxroutable` et `net_queued_packet_thread` sont des CVars **CS:GO supprimées dans CS2** (architecture sub-tick). Ne pas les inclure dans l'autoexec.

### Adapter `rate` à ta connexion

Formule approximative : `rate = upload_octets_par_seconde × 0.5`  
Laisser 50 % pour l'overhead WireGuard (encapsulation UDP) + autres trafics système.

| Upload 4G stable | `rate` recommandé |
|-----------------|-------------------|
| ~2 Mbps         | `131072`           |
| ~4 Mbps         | `262144`           |
| ~8 Mbps         | `524288` ✓         |
| ≥ 15 Mbps       | `786432` (défaut CS2) |

---

## Tethering iPhone USB

Connexion internet via câble USB plutôt que WiFi hotspot : plus stable, pas d'interférence radio, ~5-10 ms de moins sur le lien local.

### Prérequis

- **iTunes** installé (fournit le driver `Apple Mobile Device Ethernet`)
- **Câble ANKER data** branché sur un **port USB 3.0 (bleu)** — les ports USB 2.0 peuvent ne pas fournir assez de signal pour le tethering
- **Partage de connexion** activé sur l'iPhone : Réglages → Partage de connexion → toggle ON

### Mise en place (une seule fois)

**1. Brancher et faire confiance**  
Brancher le câble (port USB 3.0), accepter "Faire confiance à cet ordinateur" sur l'iPhone + saisir le code.

**2. Renommer l'adaptateur** pour cohérence avec les scripts :
```powershell
Rename-NetAdapter -Name "Ethernet 2" -NewName "iPhone USB"
```
> Le nom "Ethernet 2" peut varier — vérifier avec `Get-NetAdapter` si besoin.

**3. Vérifier la métrique** (iPhone USB doit être inférieur à Wi-Fi) :
```powershell
Get-NetIPInterface -AddressFamily IPv4 | Sort-Object InterfaceMetric | Format-Table InterfaceAlias, InterfaceMetric, ConnectionState -AutoSize
```
Sortie attendue : `iPhone USB` = 25, `Wi-Fi` = 35. Corriger si besoin :
```powershell
Set-NetIPInterface -InterfaceAlias "iPhone USB" -InterfaceMetric 5
```

**4. Désactiver la gestion d'alimentation NIC** (évite que Windows coupe l'adaptateur en jeu) :
```powershell
# En admin
$netClass = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"
Get-ChildItem $netClass -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^\d{4}$' } |
    ForEach-Object {
        $desc = (Get-ItemProperty $_.PSPath -Name DriverDesc -EA SilentlyContinue).DriverDesc
        if ($desc -like "*Apple Mobile Device*") {
            Set-ItemProperty $_.PSPath -Name PnPCapabilities -Value 24 -Type DWord
            Write-Host "OK : $desc"
        }
    }
```
> `PnPCapabilities = 24` interdit à Windows d'éteindre l'adaptateur réseau pour économiser de l'énergie. Sans ça, la connexion USB peut se couper brutalement pendant une partie.

**5. Désactiver USB Selective Suspend** (mécanisme complémentaire au niveau du port USB) :
```powershell
powercfg /query SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226
# Index actuel AC et DC doivent être 0x00000000
```
Si `0x00000001`, forcer la désactivation :
```powershell
powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
powercfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
powercfg /s SCHEME_CURRENT
```
> USB Selective Suspend est un mécanisme Windows qui coupe l'alimentation du port USB en cas d'inactivité. L'étape 4 protège le driver réseau, l'étape 5 protège le port physique — les deux sont nécessaires.

### Vérifier que la connexion USB est active

```powershell
Get-NetIPAddress -InterfaceAlias "iPhone USB" -AddressFamily IPv4
# Doit afficher IPAddress : 172.20.10.x
```

Si `Disconnected` : vérifier que **Partage de connexion est ON** sur l'iPhone (une barre bleue "Partage de connexion : 1 connexion" doit apparaître en haut de l'écran iPhone).

### Notes

- **USB 2.0 peut ne pas fonctionner** avec certains câbles ANKER — toujours utiliser le port USB 3.0 (bleu)
- iTunes peut interférer avec le tethering (il tente une synchro au branchement). Si la connexion USB ne s'établit pas : iTunes → Édition → Préférences → Appareils → cocher "Empêcher la synchronisation automatique"
- WireGuard fonctionne par-dessus la connexion USB sans aucune modification

---

## Utilisation

### Lancement normal

Double-clic sur `CS2-Launcher.ps1` (ou le raccourci bureau).  
Le launcher s'auto-élève en admin, exécute les optimisations et lance CS2.

WireGuard est déjà actif en background — aucune action nécessaire.

### Lancement manuel via .bat

```
CS2-HighPriority.bat
```

### Vérifier l'état du tunnel WireGuard

```powershell
# Statut du service
Get-Service 'WireGuardTunnel$CS2-WG'

# Détails du tunnel (admin requis)
& 'C:\Program Files\WireGuard\wg.exe' show

# Test de connectivité
ping 10.66.66.1
```

### Démarrer/arrêter/redémarrer le tunnel manuellement

```powershell
# Démarrer (admin)
Start-Service 'WireGuardTunnel$CS2-WG'

# Arrêter (admin)
Stop-Service 'WireGuardTunnel$CS2-WG'

# Redémarrer (ex: après modification de CS2-WG.conf)
Restart-Service 'WireGuardTunnel$CS2-WG'
```

> Via l'UI WireGuard : cliquer sur **CS2-WG** dans la liste à gauche → bouton **Désactiver** → puis **Activer**.

---

## Vérifier que CS2 passe par le tunnel

### 1. Vérifier l'état du tunnel (wg show)

Dans un terminal **PowerShell administrateur** :

```powershell
& 'C:\Program Files\WireGuard\wg.exe' show
```

Sortie attendue quand le tunnel fonctionne :
```
interface: CS2-WG
  public key: NGKfIv...
  listening port: 60511

peer: Fdya9D...
  endpoint: <IP_VPS>:51820
  allowed ips: 10.66.66.0/24, 155.133.224.0/19, ...
  latest handshake: 23 seconds ago        <-- doit être présent
  transfer: 534.76 KiB received, 209.88 KiB sent  <-- doit augmenter en jeu
  persistent keepalive: every 25 seconds
```

- **`latest handshake`** présent → tunnel établi
- **`transfer` qui augmente** pendant une partie → trafic CS2 bien routé via le VPS
- **Pas de `latest handshake`** → tunnel mort, voir [Dépannage](#dépannage)

### 2. Vérifier les routes Valve dans la table de routage

```powershell
route print | Select-String '155\.133|185\.25|192\.69|208\.64|205\.196|209\.197'
```

Chaque range Valve doit apparaître avec `On-link` via `10.66.66.2` (l'interface WireGuard).  
Si ces lignes sont absentes, le service WireGuard est arrêté.

### 3. Vérifier en direct pendant une partie

Ouvrir deux terminaux admin côte à côte :

```powershell
# Terminal 1 — surveiller le transfert (toutes les 5s)
while ($true) {
    & 'C:\Program Files\WireGuard\wg.exe' show | Select-String 'transfer|handshake'
    Start-Sleep 5
}

# Terminal 2 — ping vers le VPS (latence tunnel)
ping -t 10.66.66.1
```

Si le compteur `transfer` augmente pendant la partie → CS2 passe bien par le tunnel.

---

## Configuration WireGuard actuelle

**Client Windows** (`C:\ProgramData\WireGuard\CS2-WG.conf`) :
```ini
[Interface]
PrivateKey = <clé privée client>
Address    = 10.66.66.2/32
DNS        = 1.1.1.1
MTU        = 1420

[Peer]
PublicKey         = <clé publique serveur>
Endpoint          = <IP_VPS>:51820
AllowedIPs        = 10.66.66.0/24, 155.133.224.0/19, 162.254.192.0/21, 185.25.182.0/23, 192.69.96.0/22, 208.64.200.0/22, 208.78.164.0/22, 205.196.6.0/24, 146.66.152.0/24, 146.66.155.0/24, 209.197.3.0/24
PersistentKeepalive = 25
```
> `MTU = 1420` évite la fragmentation UDP (overhead WireGuard/IPv4 = ~60 octets sur base 1500).

**Serveur VPS** (`/etc/wireguard/wg0.conf`) :
```ini
[Interface]
Address    = 10.66.66.1/24
ListenPort = 51820
PrivateKey = <clé privée serveur>
PostUp/PostDown = règles iptables NAT + FORWARD

[Peer]
# CS2-Client-Windows
PublicKey           = <clé publique client>
AllowedIPs          = 10.66.66.2/32
PersistentKeepalive = 25
```

---

## Désinstallation complète du tunnel

### Côté Windows

Dans un terminal **PowerShell administrateur** :

```powershell
# 1. Arrêter et supprimer le service WireGuard
& 'C:\Program Files\WireGuard\wireguard.exe' /uninstalltunnelservice CS2-WG

# 2. Supprimer le fichier de configuration
Remove-Item 'C:\ProgramData\WireGuard\CS2-WG.conf' -Force -ErrorAction SilentlyContinue

# 3. Désinstaller WireGuard for Windows (optionnel)
winget uninstall --id WireGuard.WireGuard
# OU via Paramètres Windows → Applications → WireGuard → Désinstaller
```

Vérifier que tout est supprimé :
```powershell
# Le service ne doit plus exister
Get-Service 'WireGuardTunnel$CS2-WG' -ErrorAction SilentlyContinue
# Aucune route Valve ne doit pointer vers 10.66.66.2
route print | Select-String '10\.66\.66'
```

### Côté VPS (optionnel)

```bash
# Arrêter le service et le désactiver au boot
systemctl stop wg-quick@wg0
systemctl disable wg-quick@wg0

# Supprimer la configuration
rm /etc/wireguard/wg0.conf

# Désinstaller WireGuard (optionnel)
apt purge wireguard wireguard-tools -y

# Nettoyer les règles iptables résiduelles (si PostDown n'a pas tourné)
iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null
iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null
iptables -t nat -D POSTROUTING -o ens6 -j MASQUERADE 2>/dev/null
```

> Si tu veux juste **supprimer le peer Windows** sans tout désinstaller (ex: rotation de clés) :
> ```bash
> # Sur le VPS — retirer uniquement le peer
> wg set wg0 peer <CLÉ_PUBLIQUE_CLIENT> remove
> # Puis mettre à jour wg0.conf manuellement ou relancer wg-add-peer.sh avec les nouvelles clés
> ```

---

## Dépannage

### Le handshake ne s'établit pas (0 B received)

1. **Vérifier le firewall du fournisseur VPS** : ajouter une règle UDP entrant port 51820 dans le panel de gestion réseau (ex: Ionos → Réseau → Pare-feu entrant).

2. **Vérifier iptables sur le VPS** :
   ```bash
   iptables -L INPUT -n -v | grep 51820
   # Si absent :
   iptables -I INPUT -p udp --dport 51820 -j ACCEPT
   ```

3. **Vérifier que les paquets arrivent sur le VPS** (pendant que le client tente des handshakes) :
   ```bash
   tcpdump -i ens6 udp port 51820 -c 5 -n
   ```
   - 0 paquets → bloqué par firewall hébergeur ou 4G
   - Paquets visibles → le VPS reçoit, vérifier les clés

4. **Si la 4G bloque le port 51820** : changer le port sur le VPS vers 443 (UDP HTTPS, rarement bloqué) :
   ```bash
   systemctl stop wg-quick@wg0
   sed -i 's/ListenPort = 51820/ListenPort = 443/' /etc/wireguard/wg0.conf
   iptables -I INPUT -p udp --dport 443 -j ACCEPT
   systemctl start wg-quick@wg0
   ```
   Puis côté Windows (admin) :
   ```powershell
   Stop-Service 'WireGuardTunnel$CS2-WG' -Force
   (Get-Content 'C:\ProgramData\WireGuard\CS2-WG.conf') -replace ':51820',':443' | Set-Content 'C:\ProgramData\WireGuard\CS2-WG.conf'
   Start-Service 'WireGuardTunnel$CS2-WG'
   ```

### Le service WireGuard ne démarre pas au boot

Le service peut démarrer avant que la carte réseau soit prête. Solution :

```powershell
# En admin — redémarrer manuellement
Start-Service 'WireGuardTunnel$CS2-WG'
```

### Clés incorrectes / peer refusé

Les clés WireGuard sont sensibles. Si les clés ne correspondent plus (ex: après une réinstallation) :

1. Sur le VPS, afficher la config active : `wg show`
2. Vérifier que la `PublicKey` du peer correspond à la clé publique du client Windows
3. Si besoin, reconfigurer avec `wg-add-peer.sh <nouvelle_clé_publique_client>`
