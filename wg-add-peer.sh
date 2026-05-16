#!/bin/bash
# ============================================================
#  Ajouter le client Windows comme peer WireGuard
#  Usage : bash wg-add-peer.sh <CLE_PUBLIQUE_CLIENT>
#  Exemple : bash wg-add-peer.sh xNm4A3...==
# ============================================================

CLIENT_PUB="${1}"
CLIENT_IP="10.66.66.2/32"

if [ -z "$CLIENT_PUB" ]; then
    echo "Usage: $0 <CLE_PUBLIQUE_CLIENT>"
    echo "La cle publique est affichee par WG-Client-Setup.ps1 sur Windows."
    exit 1
fi

# Valider le format de la cle (base64, 44 chars)
if ! echo "$CLIENT_PUB" | grep -qE '^[A-Za-z0-9+/]{43}=$'; then
    echo "AVERTISSEMENT : la cle ne ressemble pas a une cle WireGuard valide (base64, 44 chars)."
    echo "Continue quand meme ? (Ctrl+C pour annuler, Entree pour continuer)"
    read -r
fi

echo "Ajout du peer :"
echo "  Cle publique : $CLIENT_PUB"
echo "  IP tunnel    : $CLIENT_IP"

# Injecter dans l'instance WireGuard en cours (sans redemarrage)
wg set wg0 peer "$CLIENT_PUB" allowed-ips "$CLIENT_IP" persistent-keepalive 25

# Persister dans wg0.conf pour survivre aux redemarrages
cat >> /etc/wireguard/wg0.conf << EOF

[Peer]
# CS2-Client-Windows
PublicKey = ${CLIENT_PUB}
AllowedIPs = ${CLIENT_IP}
PersistentKeepalive = 25
EOF

echo ""
echo "Peer ajoute et persiste dans wg0.conf."
echo ""
echo "Etat WireGuard :"
wg show wg0
