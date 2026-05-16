#!/bin/bash
# ============================================================
#  WireGuard Server Setup — Debian 11/12 (Ionos VPS, Paris)
#  Lancer en root : bash wg-server-setup.sh
# ============================================================
set -e

echo "=== [1/5] Installation WireGuard ==="
apt-get update -qq
apt-get install -y wireguard iptables iproute2

echo ""
echo "=== [2/5] Generation des cles serveur ==="
install -d -m 700 /etc/wireguard
umask 077
wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
SRV_PRIV=$(cat /etc/wireguard/server_private.key)
SRV_PUB=$(cat /etc/wireguard/server_public.key)
echo "Cles generees OK."

echo ""
echo "=== [3/5] Detection interface reseau principale ==="
IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
if [ -z "$IFACE" ]; then
    echo "ERREUR : impossible de detecter l'interface reseau."
    echo "Lance : ip route show default"
    exit 1
fi
echo "Interface principale : $IFACE"

echo ""
echo "=== [4/5] Creation /etc/wireguard/wg0.conf ==="
cat > /etc/wireguard/wg0.conf << WGEOF
[Interface]
Address = 10.66.66.1/24
ListenPort = 51820
PrivateKey = ${SRV_PRIV}

# NAT : tout le trafic sortant des clients est masquerade derriere l'IP publique du VPS
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; \
           iptables -A FORWARD -o wg0 -j ACCEPT; \
           iptables -t nat -A POSTROUTING -o ${IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; \
           iptables -D FORWARD -o wg0 -j ACCEPT; \
           iptables -t nat -D POSTROUTING -o ${IFACE} -j MASQUERADE

# ---- Ajouter les peers ci-dessous avec wg-add-peer.sh ----

WGEOF
chmod 600 /etc/wireguard/wg0.conf
echo "wg0.conf cree."

echo ""
echo "=== [5/5] Activation systeme ==="

# IP forwarding
grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1 > /dev/null
echo "IP forwarding : ON"

# Ouvrir le port 51820/UDP si UFW est actif
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 51820/udp > /dev/null
    echo "UFW : port 51820/udp ouvert"
fi

# Ouvrir avec iptables-legacy si disponible (VPS Ionos utilisent parfois nftables)
if command -v iptables &>/dev/null; then
    iptables -I INPUT -p udp --dport 51820 -j ACCEPT 2>/dev/null || true
fi

# Demarrer WireGuard
systemctl enable --now wg-quick@wg0
sleep 1
WG_STATUS=$(systemctl is-active wg-quick@wg0)
echo "Service wg-quick@wg0 : $WG_STATUS"

echo ""
echo "============================================================"
echo "  SERVEUR WIREGUARD PRET"
echo "============================================================"
echo ""
echo "  Cle publique SERVEUR (a coller dans WG-Client-Setup.ps1) :"
echo ""
echo "  $SRV_PUB"
echo ""
echo "  Etape suivante :"
echo "  1. Lance WG-Client-Setup.ps1 sur Windows"
echo "  2. Copie la cle publique CLIENT affichee par le script"
echo "  3. Sur ce VPS : bash wg-add-peer.sh <CLE_PUBLIQUE_CLIENT>"
echo ""
echo "  Interface WireGuard active :"
wg show wg0 2>/dev/null || echo "  (aucun peer pour l'instant)"
